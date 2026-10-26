package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path"
	"strings"
	"sync"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Object storage for the archive.
//
// The bucket is NOT on the write path. Segments are written to local disk,
// fsynced and hashed exactly as they always were; a segment is uploaded only
// after it rotates. That keeps every durability guarantee the local archive
// already had, and it is the reason this does not go through a FUSE mount:
// s3fs and gcsfuse buffer writes and upload on close, so Sync() can return
// success while the object is not in the bucket at all. An archive whose
// manifest swears a segment exists, and a slot already advanced past it, is
// the worst failure a durability tier can have.
//
// Only the S3 API is spoken, so one client reaches any S3-compatible store.
// Amazon S3 and Google Cloud Storage are the two verified against real
// buckets; the rest are expected to work and are deliberately not claimed.
// minio-go is pure Go, so CGO_ENABLED=0 static builds and the
// eleven-distribution portability story survive untouched.

// LockState describes whether objects written to this bucket become immutable.
//
// pgVolvra never sets a retention. It reads what the bucket already enforces,
// because that is the case that actually occurs: a security team sets a
// retention policy on the bucket, and a DBA points the companion at it without
// knowing. The consequence -- that volvra.forget() cannot reach the archived
// copy -- then has to reach the person running the erasure.
//
// Creating locks was deliberately left out. The claim could not be verified:
// no S3 implementation available as a container image enforces Object Lock, so
// a retention this process set would have been untested in the one respect
// that matters. It is also irreversible for the user, and Object Lock requires
// bucket versioning, so rewriting the manifest after every rotation would mint
// an immutable version each time and hold it for the retention period. Add it
// when there is a real provider to test against.
type LockState struct {
	Enabled bool
	Mode    string // GOVERNANCE (bypassable with permission) or COMPLIANCE (not)
	Days    int
	Source  string // how the retention was discovered
}

func (l LockState) String() string {
	if !l.Enabled {
		return "none"
	}
	return fmt.Sprintf("%s for %d day(s), from %s", l.Mode, l.Days, l.Source)
}

type RemoteOptions struct {
	Endpoint  string // host:port, no scheme
	Bucket    string
	Prefix    string
	Region    string
	Insecure  bool   // plain HTTP; for a local test server, never a real provider
	Checksum  string // auto, server or readback -- see resolveChecksum
	UserAgent string
}

// How an upload is proved to have arrived intact.
//
// "server" asks S3 to compute SHA-256 and compares it against the hash the
// manifest already chained. It is the better check, because the number comes
// from the bytes the provider actually persisted, and it costs no extra
// traffic.
//
// "readback" downloads the object again and hashes it here. Slower, and on a
// provider that bills egress it doubles the cost of archiving, but it proves
// the same thing and needs nothing of the provider beyond GET.
//
// The distinction is not academic. Server-side checksums travel as a trailing
// header with aws-chunked framing (STREAMING-UNSIGNED-PAYLOAD-TRAILER), which
// is an AWS extension that Google Cloud Storage does not implement. The S3
// client refuses outright rather than degrading: asking for a checksum against
// a Google endpoint fails the upload with "Checksum cannot be used with GCS
// endpoints". Confirmed against a real GCS bucket on 2026-10-26.
const (
	checksumServer   = "server"
	checksumReadback = "readback"
)

// Endpoints known not to accept aws-chunked trailing headers.
func endpointNeedsReadback(endpoint string) bool {
	host := strings.ToLower(endpoint)
	if i := strings.IndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	return host == "storage.googleapis.com" ||
		strings.HasSuffix(host, ".storage.googleapis.com")
}

// resolveChecksum turns the flag into a mode, defaulting by endpoint so that
// the common case needs no flag at all.
func resolveChecksum(mode, endpoint string) (string, error) {
	switch strings.ToLower(mode) {
	case "", "auto":
		if endpointNeedsReadback(endpoint) {
			return checksumReadback, nil
		}
		return checksumServer, nil
	case checksumServer:
		return checksumServer, nil
	case checksumReadback:
		return checksumReadback, nil
	default:
		return "", fmt.Errorf("--s3-checksum must be auto, server or readback, got %q", mode)
	}
}

type Remote struct {
	cli      *minio.Client
	bucket   string
	prefix   string
	lock     LockState
	checksum string

	// Said once per run, not once per segment.
	sayReadback sync.Once
}

// NewRemote connects and establishes what the bucket will do to our objects.
//
// Credentials are never taken as flags. The standard chain covers environment
// variables, the shared credentials file, and the instance or workload
// identity roles that make "no secrets on disk" true -- which is most of the
// reason to use a native client rather than a mount.
func NewRemote(ctx context.Context, o RemoteOptions) (*Remote, error) {
	if o.Endpoint == "" {
		return nil, errors.New("--s3-endpoint is required with --s3-bucket")
	}
	if strings.Contains(o.Endpoint, "://") {
		return nil, fmt.Errorf("--s3-endpoint is a host, not a URL: %q", o.Endpoint)
	}
	checksum, err := resolveChecksum(o.Checksum, o.Endpoint)
	if err != nil {
		return nil, err
	}

	cli, err := minio.New(o.Endpoint, &minio.Options{
		Creds:  credentials.NewChainCredentials(defaultCredProviders()),
		Secure: !o.Insecure,
		Region: o.Region,
		// Required before PutObject will accept a ChecksumSHA256 request: the
		// checksum travels as a trailing header after the body, and without
		// this every upload fails with "Checksum requires Client with
		// TrailingHeaders enabled".  Left off in readback mode, because the
		// framing it enables is itself what some providers reject.
		TrailingHeaders: checksum == checksumServer,
	})
	if err != nil {
		return nil, fmt.Errorf("s3 client: %w", err)
	}
	if o.UserAgent != "" {
		cli.SetAppInfo("volvra-companion", o.UserAgent)
	}

	r := &Remote{cli: cli, bucket: o.Bucket, prefix: strings.Trim(o.Prefix, "/"),
		checksum: checksum}

	// Fail at startup rather than at the first rotation, which could be hours
	// of streaming later, with the operator long gone.
	ok, err := cli.BucketExists(ctx, o.Bucket)
	if err != nil {
		return nil, fmt.Errorf("cannot reach bucket %q: %w", o.Bucket, err)
	}
	if !ok {
		return nil, fmt.Errorf("bucket %q does not exist, or these credentials cannot see it", o.Bucket)
	}

	if err := r.resolveLock(ctx, o); err != nil {
		return nil, err
	}
	return r, nil
}

func defaultCredProviders() []credentials.Provider {
	return []credentials.Provider{
		&credentials.EnvAWS{},
		&credentials.EnvMinio{},
		&credentials.FileAWSCredentials{},
		&credentials.IAM{Endpoint: ""}, // instance / workload identity
	}
}

// resolveLock reads what the bucket will do to objects written to it.
//
// Consulted on every run, because a bucket-level retention applies to our
// uploads whether or not anyone here asked for one, and an operator who then
// runs volvra.forget() would otherwise never learn that the archived copy
// cannot honour the erasure.
func (r *Remote) resolveLock(ctx context.Context, o RemoteOptions) error {
	_, mode, validity, unit, err := r.cli.GetObjectLockConfig(ctx, o.Bucket)
	if err != nil || mode == nil || *mode == "" {
		// Not every S3 implementation answers this call, and lacking the
		// permission to read it is normal. Neither is fatal: it only means
		// this process cannot say for certain, which is reported as such.
		r.lock = LockState{}
		return nil
	}
	d := 0
	if validity != nil {
		d = int(*validity)
		if unit != nil && *unit == minio.Years {
			d *= 365
		}
	}
	r.lock = LockState{Enabled: true, Mode: string(*mode), Days: d,
		Source: "bucket policy"}
	return nil
}

func (r *Remote) Lock() LockState { return r.lock }

// Checksum reports how uploads are verified, for the startup log: on a
// provider that bills egress, readback doubles what archiving costs, so it
// should never be a silent default.
func (r *Remote) Checksum() string { return r.checksum }

func (r *Remote) key(name string) string {
	if r.prefix == "" {
		return name
	}
	return path.Join(r.prefix, name)
}

// URI is what gets reported to the database, so a human reading
// volvra.companion_checkpoint can find the archive.
func (r *Remote) URI() string {
	return "s3://" + path.Join(r.bucket, r.prefix)
}

// PutSegment uploads a rotated segment and proves the bytes arrived intact.
//
// wantSHA is the hash the manifest already chained. The upload asks S3 for a
// SHA-256 checksum and compares it, so "archived" means verified rather than
// merely sent. Without that, a truncated or corrupted upload would be
// indistinguishable from a good one until a restore needed it.
func (r *Remote) PutSegment(ctx context.Context, localPath, name, wantSHA string) (string, error) {
	f, err := os.Open(localPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", err
	}

	opts := minio.PutObjectOptions{ContentType: "application/x-ndjson"}
	if r.checksum == checksumServer {
		// Ask the server to compute SHA-256 so the comparison below is against
		// what the provider actually stored. ETag cannot be used for this: it
		// is an MD5 only for single-part uploads and is not a hash of the
		// content after a multipart one.
		opts.Checksum = minio.ChecksumSHA256
	} else {
		// A bucket with Object Lock enabled REFUSES any PUT that carries no
		// checksum header: "Content-MD5 OR x-amz-checksum- HTTP header is
		// required for Put Object requests with Object Lock parameters". So
		// when no SHA-256 is being requested, send Content-MD5 instead. It is
		// a transport check only; the manifest's SHA-256 chain remains what
		// proves the archive.
		opts.SendContentMd5 = true
	}
	info, err := r.cli.PutObject(ctx, r.bucket, r.key(name), f, st.Size(), opts)
	if err != nil {
		return "", fmt.Errorf("upload %s: %w", name, err)
	}

	if err := r.confirm(ctx, name, wantSHA, info.ChecksumSHA256); err != nil {
		return "", err
	}
	return info.ETag, nil
}

// confirm compares what the provider stored against what the manifest claims.
//
// The provider's checksum is preferred because it is computed server side from
// the bytes it persisted. Two cases make it unusable, and both end in reading
// the object back and hashing it here:
//
//   - Some S3 implementations return no checksum at all.
//   - A MULTIPART upload returns a COMPOSITE checksum: a hash of the part
//     hashes with the part count appended, like "n1u...=-3". It is not a hash
//     of the content and cannot be compared with the manifest's SHA-256. S3
//     has no full-object SHA-256 for multipart uploads, so there is nothing
//     better to ask for.
//
// This matters more than it looks. Segments default to 64 MB, which is always
// a multipart upload, so on Amazon S3 the read-back path is the normal one
// rather than the exception. It verifies just as strictly and costs an extra
// download per segment, which is billed, so it is said out loud once per run
// instead of being discovered on an invoice.
func (r *Remote) confirm(ctx context.Context, name, wantSHA, gotB64 string) error {
	if gotB64 != "" && !strings.Contains(gotB64, "-") {
		raw, err := base64.StdEncoding.DecodeString(gotB64)
		if err == nil {
			if got := hex.EncodeToString(raw); got != wantSHA {
				return fmt.Errorf("upload %s: provider stored sha256 %s, manifest says %s",
					name, got, wantSHA)
			}
			return nil
		}
	}
	r.sayReadback.Do(func() {
		if gotB64 == "" {
			log.Printf("NOTICE: this provider returns no upload checksum, so each "+
				"segment is read back and hashed to verify it (%s)", r.URI())
		} else {
			log.Printf("NOTICE: segments are large enough to upload in parts, and a "+
				"multipart checksum cannot be compared with the manifest hash, so "+
				"each segment is read back and hashed to verify it. This doubles "+
				"the traffic per segment (%s)", r.URI())
		}
	})

	obj, err := r.cli.GetObject(ctx, r.bucket, r.key(name), minio.GetObjectOptions{})
	if err != nil {
		return fmt.Errorf("verify %s: %w", name, err)
	}
	defer obj.Close()
	h := sha256.New()
	if _, err := io.Copy(h, obj); err != nil {
		return fmt.Errorf("verify %s: %w", name, err)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != wantSHA {
		return fmt.Errorf("upload %s: read back sha256 %s, manifest says %s",
			name, got, wantSHA)
	}
	return nil
}

// PutManifest uploads the manifest, and is always called after the segments it
// names. A manifest that referenced an object not yet in the bucket would
// describe an archive that cannot be restored.
func (r *Remote) PutManifest(ctx context.Context, localPath string) error {
	f, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	// Always checksummed, for the Object Lock reason above: a lock-enabled
	// bucket rejects an unchecksummed PUT, and without this the manifest
	// upload fails and archiving to such a bucket cannot work at all.
	opts := minio.PutObjectOptions{
		ContentType:    "application/json",
		SendContentMd5: true,
	}
	_, err = r.cli.PutObject(ctx, r.bucket, r.key("manifest.json"), f, st.Size(), opts)
	if err != nil {
		return fmt.Errorf("upload manifest: %w", err)
	}
	return nil
}

// Get reads an object back. verify and restore use this when the local copy is
// gone, which is the case this whole feature exists for: the host died.
func (r *Remote) Get(ctx context.Context, name string) (io.ReadCloser, error) {
	obj, err := r.cli.GetObject(ctx, r.bucket, r.key(name), minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	// GetObject is lazy: it does not contact the server until the first read,
	// so a missing object would otherwise surface as a read error much later,
	// somewhere that reads like a parse failure.
	if _, err := obj.Stat(); err != nil {
		obj.Close()
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return obj, nil
}
