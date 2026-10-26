# Where the Archive Is Stored

The companion writes its archive to a local directory, and can also
upload each segment to S3-compatible object storage. This document
describes how that works, what it guarantees, and the one setting that
changes what pgVolvra can promise about erasure.

## Local disk is always the write path

Object storage is additive. Segments are written to the local
directory, fsynced and hashed exactly as they are without a bucket; a
segment is uploaded only after the segment rotates. The bucket is a
destination, never a dependency of the write path, so a bucket that is
slow or unreachable cannot stall replication.

Uploaded segments are kept on local disk. Verification and restore
therefore work with no network and no credentials. The archive
directory grows without bound, so prune it on whatever schedule suits
the retention you need locally.

## Why not a mounted bucket

Pointing `--archive` at a bucket mounted with s3fs, gcsfuse or rclone
looks equivalent and is not. The companion calls `fsync` on each
segment and on the directory before the manifest chains that segment's
SHA-256. A FUSE mount buffers writes locally and uploads on close, so
`fsync` can return success while the object is not in the bucket at
all. The companion then advances the replication slot past those
changes, and the WAL that could have replaced them is released. Losing
the host in that window leaves an archive missing a segment its own
manifest vouches for.

A mount also needs `/dev/fuse`, which ECS Fargate, Cloud Run and
unprivileged Kubernetes do not provide.

## Configuring object storage

The following flags configure the bucket:

```bash
volvra-companion run \
  --dsn "$VOLVRA_DSN" \
  --archive /var/lib/volvra/archive \
  --s3-bucket my-archive \
  --s3-endpoint s3.us-east-1.amazonaws.com \
  --s3-prefix prod/orders \
  --s3-region us-east-1
```

Credentials are never passed as flags, because a flag puts them in the
process list and in shell history. The companion uses the standard
chain: environment variables, the shared credentials file, and the
instance or workload identity role. An instance role means no secret
is stored on the host at all.

The endpoint is a host, not a URL. Use `--s3-insecure` only against a
local test server; it disables TLS.

## Google Cloud Storage

GCS exposes an S3-compatible endpoint, so it needs no separate client.
Create an HMAC key for a service account and point the companion at the
interoperability endpoint:

```bash
export AWS_ACCESS_KEY_ID="$GCS_HMAC_ACCESS_ID"
export AWS_SECRET_ACCESS_KEY="$GCS_HMAC_SECRET"

volvra-companion run \
  --dsn "$VOLVRA_DSN" \
  --archive /var/lib/volvra/archive \
  --s3-bucket my-archive \
  --s3-endpoint storage.googleapis.com
```

One difference matters, and the companion handles it automatically.
A server-side checksum travels as an aws-chunked trailing header, an
AWS extension that Google Cloud Storage does not implement. Asking for
one against a Google endpoint does not degrade gracefully; the upload
fails with "Checksum cannot be used with GCS endpoints". So
`--s3-checksum` defaults to `auto`, which selects read-back
verification for `storage.googleapis.com` and server checksums
everywhere else. The companion says which it is using at startup.

Read-back verification downloads each segment after uploading it, so
archiving moves roughly twice the data. On a provider that bills egress
that is a real recurring cost, which is why it is announced rather than
silently chosen.

## What "archived" means

A segment counts as archived when the provider confirms it, not when
the upload is sent. After uploading, the companion compares the
provider's SHA-256 against the hash the manifest already chained. If
that comparison is not possible, the object is downloaded and hashed
instead. Either way a mismatch fails the upload rather than recording
it.

The ETag is deliberately not used for this. It is an MD5 only for
single-part uploads, and after a multipart upload it is not a hash of
the content at all.

### Large segments are verified by reading them back

A segment larger than about 16 MB is uploaded in parts, and S3 answers a
multipart upload with a composite checksum: a hash of the part hashes
with the part count appended, such as `n1u...Mm7o=-3`. That is not a
hash of the content and cannot be compared with the manifest's SHA-256.
S3 offers no full-object SHA-256 for multipart uploads, so there is
nothing better to request.

Segments default to 12 MB for this reason, which keeps an upload to a
single part so the server-side checksum can be used. Raising
`--segment-bytes` past roughly 16 MB brings the read-back path back.
Verification is exactly as strict either way; the difference is one
extra download per segment, which is billed. The companion says so once
per run rather than leaving it to be discovered on an invoice.

Very large archives are the one case for raising it. The manifest is
re-uploaded after every rotation and grows by one entry each time, so
more segments mean more manifest traffic. Past roughly 700 GB of total
history, larger segments cost less overall even with the extra
downloads.

The manifest is uploaded after the segments it names, so the copy in
the bucket never references an object that is not there. An archive
read from the bucket alone is always internally consistent.

## The replication slot waits for the bucket

With object storage configured, the slot does not advance past a
segment the bucket has not confirmed. This is the point of the
feature. Advancing sooner would mean that losing the host loses both
the segment and the WAL that could have replaced it.

A bucket outage therefore holds the slot and retains WAL. The
companion keeps archiving locally, retries the upload every few
seconds, and logs how many segments are outstanding. The `--lag-max`
ceiling still applies: if retained WAL reaches it, the slot is advanced
and the skipped range is recorded as a gap, because a database that
will not start is worse than a hole that is written down.

## Reading an archive after the host is gone

Pass an empty `--archive` to read the bucket alone, which is the
situation the durable tier exists for:

```bash
volvra-companion verify --archive "" \
  --s3-bucket my-archive --s3-endpoint s3.us-east-1.amazonaws.com

volvra-companion restore --archive "" \
  --s3-bucket my-archive --s3-endpoint s3.us-east-1.amazonaws.com \
  --dsn "$VOLVRA_DSN"
```

Verification re-hashes every segment and re-walks the chain, so it
detects an object that was altered in the bucket as readily as one
altered on disk. A restore refuses an archive that does not verify.

## When the bucket enforces object lock

S3 Object Lock makes an uploaded object immutable for a retention period.
pgVolvra does not set one, and offers no flag to. It reads the policy the
bucket already enforces and tells you what that policy costs you.

That is the case that actually arises: a security team sets a retention
policy on the bucket, a DBA points the companion at it, and nobody
connects the two until an erasure request arrives.

### It conflicts with erasure

`volvra.forget` redacts a subject's history in the database. It cannot
reach an archived object that is under retention. An erasure request
that `forget` reports as satisfied is therefore only satisfied in the
database, and under compliance mode the archived copy cannot be erased
by anybody, including the account root, until the retention expires.

pgVolvra says this rather than leaving it in a document:

- the companion reports the retention at startup, naming the mode, the
  duration and the conflict with `volvra.forget`.
- `volvra.forget` raises a warning naming the archive and the retention
  every time it runs while a retention is in force.
- `volvra.preflight` reports the condition.
- `volvra.companion_status` shows the mode and duration.

### Why pgVolvra does not set a retention

Setting one was built and then deliberately removed before release, for
three reasons:

- The claim could not be verified. No S3 implementation available as a
  container image enforces Object Lock, so a retention pgVolvra set
  would have been untested in the one respect that matters.
- A retention cannot be shortened once an object carries it, so a wrong
  value is unrecoverable for the length of the retention.
- Object Lock requires bucket versioning. The manifest is rewritten
  after every segment rotation, so each rewrite would mint a new
  immutable version and hold it for the full retention period.

If you want archived objects immutable, set a retention policy on the
bucket. pgVolvra will detect it and report it.

## Supported providers

The companion speaks the S3 API only. Amazon S3 and Google Cloud Storage
are verified against real buckets. Other S3-compatible stores, such as
Cloudflare R2, Backblaze B2, Wasabi and MinIO, use the same protocol and
are expected to work, but none has been run, so none is claimed.

The following table describes what has been verified:

| Provider | Status |
|---|---|
| Amazon S3 | Verified on a real bucket: upload, multipart upload at the default 64 MB segment size, checksum verification by both paths, verify and restore from the bucket alone. |
| Object lock on Amazon S3 | Verified on a real bucket: a bucket retention policy is detected, recorded and reported through volvra.forget and volvra.preflight, and S3 does refuse to delete an archived segment while the retention stands. pgVolvra never sets a retention. |
| S3-compatible storage generally | Verified against SeaweedFS and adobe/s3mock, covering both the server-checksum and read-back verification paths. |
| Cloudflare R2, Backblaze B2, Wasabi, MinIO | Same protocol, expected to work, not yet run. Not claimed as supported. |
| Google Cloud Storage via S3 interoperability | Verified on a real bucket with an HMAC key: uploads, read-back verification, and verify and restore from the bucket alone. Confirmed that a server-side checksum is refused there, which is why auto selects read-back. |
| Instance and workload identity roles | Designed for, not yet run. Testing uses credentials from the environment. |

## Next Steps

- The Companion Overview document explains why the durable tier exists
  and how it differs from the trigger tier.
- The Erasing Data document describes `volvra.forget` and what
  redaction does and does not remove.
- The Companion Reference document lists every flag and its default.
