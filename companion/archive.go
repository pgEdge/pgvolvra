package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// The archive is the durability promise, so it has to be readable without
// Postgres, without this binary, and without any index: newline-delimited JSON
// in numbered segments, described by a manifest.
//
// Segments are chained by SHA-256 the same way volvra.seal() chains the
// in-database history. Losing or editing a segment is therefore detectable,
// and a gap that the companion *recorded* is distinguishable from one it did
// not -- which is the same principle retention and erasure follow.

const archiveFormat = 1

type Change struct {
	LSN      string          `json:"lsn"`
	XID      uint32          `json:"xid,omitempty"`
	CommitTS time.Time       `json:"commit_ts"`
	Table    string          `json:"table,omitempty"`
	Op       string          `json:"op,omitempty"` // I/U/D/T
	PK       json.RawMessage `json:"pk,omitempty"`
	Old      json.RawMessage `json:"old,omitempty"`
	New      json.RawMessage `json:"new,omitempty"`

	// Gap records carry no row data. They exist so that missing history is
	// explained rather than silent.
	Gap     bool   `json:"gap,omitempty"`
	FromLSN string `json:"from_lsn,omitempty"`
	ToLSN   string `json:"to_lsn,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

type Segment struct {
	Seq      int    `json:"seq"`
	File     string `json:"file"`
	StartLSN string `json:"start_lsn"`
	EndLSN   string `json:"end_lsn"`
	Changes  int64  `json:"changes"`
	Bytes    int64  `json:"bytes"`
	SHA256   string `json:"sha256"`
	Prev     string `json:"prev,omitempty"` // previous segment's chain
	Chain    string `json:"chain"`          // sha256(prev || sha256)
	SealedAt string `json:"sealed_at"`

	// Upload state. These are additive and optional on purpose: archiveFormat
	// stays at 1, because OpenArchive refuses any manifest whose format is not
	// exactly what this build writes, so bumping it would strand every archive
	// written by an earlier release. A reader that does not know these fields
	// ignores them and still reads the archive correctly.
	UploadedAt string `json:"uploaded_at,omitempty"`
	RemoteKey  string `json:"remote_key,omitempty"`
	RemoteETag string `json:"remote_etag,omitempty"`
}

// Uploaded reports whether this segment is known to be in object storage.
func (s Segment) Uploaded() bool { return s.UploadedAt != "" }

type Manifest struct {
	Archive     string    `json:"archive"`
	Format      int       `json:"format"`
	Slot        string    `json:"slot"`
	Publication string    `json:"publication,omitempty"`
	CreatedAt   string    `json:"created_at"`
	Segments    []Segment `json:"segments"`
}

type Archive struct {
	dir      string
	man      Manifest
	cur      *os.File
	curSeq   int
	curStart string
	curEnd   string
	curCount int64
	curBytes int64
	hasher   hash.Hash
	maxBytes int64

	lastPushErr error

	// Manifest uploads are rate limited. The manifest holds one entry per
	// segment and is complete every time it is written, so uploading it after
	// every rotation makes archive traffic grow with the SQUARE of the segment
	// count: the Nth rotation would upload N entries. At 12 MB segments that
	// overtakes the segment data itself well before a terabyte of history.
	//
	// Uploading on a time bound instead makes the cost depend on how long the
	// companion runs rather than on how many segments it wrote.
	lastManifestAt time.Time
	// The highest segment sequence the manifest IN THE BUCKET covers. The slot
	// must not advance past it; see ResumeLSN.
	manifestSeq int

	// remote is nil unless object storage was configured, and every method
	// below is a no-op in that case. The local archive is unchanged either
	// way: the bucket is a destination, never a dependency of the write path.
	remote *Remote
}

// UseRemote attaches object storage. Once attached, a segment is not
// considered durable until it is in the bucket -- see ResumeLSN.
func (a *Archive) UseRemote(r *Remote) { a.remote = r }

// How often the manifest may be uploaded. The cost of waiting is that the
// replication slot lags by at most this long, so Postgres keeps a little more
// write-ahead log; the cost of not waiting is quadratic upload traffic.
const manifestInterval = 30 * time.Second

func OpenArchive(dir, slot, publication string, maxBytes int64) (*Archive, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	a := &Archive{dir: dir, maxBytes: maxBytes}

	mp := filepath.Join(dir, "manifest.json")
	b, err := os.ReadFile(mp)
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &a.man); err != nil {
			return nil, fmt.Errorf("manifest is unreadable, refusing to append: %w", err)
		}
		if a.man.Format != archiveFormat {
			return nil, fmt.Errorf("archive format %d, this build writes %d",
				a.man.Format, archiveFormat)
		}
		if a.man.Slot != slot {
			return nil, fmt.Errorf("archive belongs to slot %q, not %q -- refusing to mix",
				a.man.Slot, slot)
		}
	case os.IsNotExist(err):
		a.man = Manifest{
			Archive:     "volvra",
			Format:      archiveFormat,
			Slot:        slot,
			Publication: publication,
			CreatedAt:   time.Now().UTC().Format(time.RFC3339Nano),
		}
		if err := a.writeManifest(); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	return a, nil
}

// ResumeLSN is the last LSN durably in the archive, and therefore the only
// point it is safe to tell Postgres it may discard WAL up to.
//
// With object storage configured, "durable" means in the bucket. Advancing the
// slot past a segment that exists only on local disk would mean that losing
// the host loses both the segment and the WAL that could have replaced it --
// which is the exact failure this feature exists to prevent. So an upload that
// has not happened yet holds the slot, and WAL accumulates until it does. The
// --lag-max valve remains the escape hatch when a bucket is unreachable for
// long enough that retaining WAL becomes the bigger risk.
func (a *Archive) ResumeLSN() string {
	segs := a.man.Segments
	if a.remote != nil {
		last := ""
		for _, s := range segs {
			// Durable means two things: the segment is in the bucket, AND the
			// manifest in the bucket names it. A segment uploaded but not yet
			// referenced by the uploaded manifest is unreachable to anyone
			// reading the bucket, so acknowledging it would release WAL for
			// history that cannot be found again.
			if !s.Uploaded() || s.Seq > a.manifestSeq {
				break
			}
			last = s.EndLSN
		}
		return last
	}
	if n := len(segs); n > 0 {
		return segs[n-1].EndLSN
	}
	return ""
}

// PendingUploads counts segments recorded locally but not yet in the bucket.
func (a *Archive) PendingUploads() int {
	if a.remote == nil {
		return 0
	}
	n := 0
	for _, s := range a.man.Segments {
		if !s.Uploaded() {
			n++
		}
	}
	return n
}

func (a *Archive) writeManifest() error {
	b, err := json.MarshalIndent(a.man, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(a.dir, ".manifest.json.tmp")
	if err := os.WriteFile(tmp, append(b, '\n'), 0o640); err != nil {
		return err
	}
	// Rename is the atomic step: a torn manifest would make the whole archive
	// unreadable, which is worse than losing the last segment.
	if err := os.Rename(tmp, filepath.Join(a.dir, "manifest.json")); err != nil {
		return err
	}
	d, err := os.Open(a.dir)
	if err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func (a *Archive) open() error {
	a.curSeq = len(a.man.Segments) + 1
	name := fmt.Sprintf("%010d.ndjson", a.curSeq)
	f, err := os.OpenFile(filepath.Join(a.dir, name),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o640)
	if err != nil {
		return err
	}
	a.cur, a.curCount, a.curBytes = f, 0, 0
	a.curStart, a.curEnd = "", ""
	a.hasher = sha256.New()
	return nil
}

func (a *Archive) Append(c Change) error {
	if a.cur == nil {
		if err := a.open(); err != nil {
			return err
		}
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if _, err := a.cur.Write(b); err != nil {
		return err
	}
	a.hasher.Write(b)
	a.curBytes += int64(len(b))
	a.curCount++
	if a.curStart == "" {
		a.curStart = c.LSN
	}
	a.curEnd = c.LSN

	if a.curBytes >= a.maxBytes {
		return a.Rotate()
	}
	return nil
}

// Rotate closes the current segment and only then records it in the manifest.
// Nothing is acknowledged to Postgres before this returns.
func (a *Archive) Rotate() error {
	if a.cur == nil || a.curCount == 0 {
		return nil
	}
	if err := a.cur.Sync(); err != nil {
		return err
	}
	name := a.cur.Name()
	if err := a.cur.Close(); err != nil {
		return err
	}
	a.cur = nil

	sum := hex.EncodeToString(a.hasher.Sum(nil))
	prev := ""
	if n := len(a.man.Segments); n > 0 {
		prev = a.man.Segments[n-1].Chain
	}
	chain := sha256.Sum256([]byte(prev + "|" + sum))

	a.man.Segments = append(a.man.Segments, Segment{
		Seq:      a.curSeq,
		File:     filepath.Base(name),
		StartLSN: a.curStart,
		EndLSN:   a.curEnd,
		Changes:  a.curCount,
		Bytes:    a.curBytes,
		SHA256:   sum,
		Prev:     prev,
		Chain:    hex.EncodeToString(chain[:]),
		SealedAt: time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err := a.writeManifest(); err != nil {
		return err
	}

	// Upload immediately, but do not let a bucket problem fail the rotation.
	// The segment is already fsynced and recorded locally; the only thing an
	// upload failure costs is that the slot will not advance past it, which is
	// exactly the intended behaviour and is reported by the caller.
	if a.remote != nil {
		if err := a.PushRemote(context.Background()); err != nil {
			a.lastPushErr = err
		} else {
			a.lastPushErr = nil
		}
	}
	return nil
}

// LastPushError is the most recent upload failure, for the caller to log. It
// is deliberately not returned from Rotate: archiving locally succeeded.
func (a *Archive) LastPushError() error { return a.lastPushErr }

// PushRemote uploads every segment the manifest records but the bucket does
// not yet hold, then uploads the manifest.
//
// Order is the whole correctness argument. Segments go first, each verified
// against the hash the manifest already chained; the manifest goes last, so it
// can never name an object that is not in the bucket. An archive read from the
// bucket alone is therefore always internally consistent, which is the state
// it will be read in if the host is gone.
//
// Re-running this is safe and is how a crash mid-upload recovers: a segment
// whose upload did not complete simply has no uploaded_at, so it is uploaded
// again. Object storage PUT is idempotent for our purposes, since the bytes
// are identical and the hash is checked either way.
//
// An error here is not fatal to archiving. The local archive is already
// durable, and refusing to continue would turn a bucket outage into a stopped
// companion. What a failure does do is hold ResumeLSN back, so the slot does
// not advance past anything the bucket has not confirmed.
func (a *Archive) PushRemote(ctx context.Context) error {
	return a.pushRemote(ctx, false)
}

// FlushRemote pushes everything and the manifest with it, ignoring the rate
// limit. Used at shutdown, where there is no later call to catch up.
func (a *Archive) FlushRemote(ctx context.Context) error {
	return a.pushRemote(ctx, true)
}

func (a *Archive) pushRemote(ctx context.Context, force bool) error {
	if a.remote == nil {
		return nil
	}
	changed := false
	for i := range a.man.Segments {
		seg := &a.man.Segments[i]
		if seg.Uploaded() {
			continue
		}
		local := filepath.Join(a.dir, seg.File)
		etag, err := a.remote.PutSegment(ctx, local, seg.File, seg.SHA256)
		if err != nil {
			// Stop at the first failure rather than skipping ahead: segments
			// are a chain, and uploading a later one while an earlier one is
			// missing would make the bucket's copy unreadable from the gap
			// onwards for no benefit.
			if changed {
				_ = a.writeManifest()
			}
			return err
		}
		seg.UploadedAt = time.Now().UTC().Format(time.RFC3339Nano)
		seg.RemoteKey = seg.File
		seg.RemoteETag = etag
		changed = true
	}
	if changed {
		if err := a.writeManifest(); err != nil {
			return err
		}
	}

	// The highest sequence the manifest WOULD cover if uploaded now.
	ready := 0
	for _, seg := range a.man.Segments {
		if !seg.Uploaded() {
			break
		}
		ready = seg.Seq
	}
	if ready == a.manifestSeq {
		return nil // the bucket's manifest is already current
	}
	if !force && time.Since(a.lastManifestAt) < manifestInterval {
		// Deliberately behind. ResumeLSN holds the slot at manifestSeq, so
		// the delay costs retained WAL and never costs correctness.
		return nil
	}
	if err := a.remote.PutManifest(ctx, filepath.Join(a.dir, "manifest.json")); err != nil {
		return err
	}
	a.manifestSeq = ready
	a.lastManifestAt = time.Now()
	return nil
}

func (a *Archive) Stats() (segments int, changes int64) {
	for _, s := range a.man.Segments {
		changes += s.Changes
	}
	return len(a.man.Segments), changes
}

// Close rotates the open segment and then flushes everything to the bucket,
// manifest included. This is the one place the manifest rate limit is ignored:
// there is no later call to catch up, and a manifest left behind would strand
// segments that are already uploaded.
func (a *Archive) Close() error {
	if err := a.Rotate(); err != nil {
		return err
	}
	return a.FlushRemote(context.Background())
}

// ReadManifest is used by verify and restore, which must work with no database
// and no running companion.
func ReadManifest(dir string) (*Manifest, error) {
	b, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	sort.Slice(m.Segments, func(i, j int) bool { return m.Segments[i].Seq < m.Segments[j].Seq })
	return &m, nil
}
