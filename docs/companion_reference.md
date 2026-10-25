# Companion Reference

This document documents every companion command, flag, and default.
The companion is a single binary built from the `companion` directory.

## Building the companion

Build the binary with the Go toolchain, version 1.25 or later:

```bash
cd companion
go build -o volvra-companion .
```

The companion depends on `github.com/jackc/pglogrepl` and
`github.com/jackc/pgx/v5`. Both declare a minimum of Go 1.25, which
sets the floor for the companion. Both are client libraries, so
neither imposes anything on the database.

## Command summary

The following table describes each command:

| Command | Purpose |
|---|---|
| run | Stream a replication slot and archive the changes. |
| verify | Re-hash every segment and re-walk the manifest chain. |
| restore | Load an archive back into volvra.change_log. |
| status | Report the durable tier from the database's point of view. |
| help | Print usage. |

## Common flags

The following table describes the flags every command accepts:

| Flag | Default | Description |
|---|---|---|
| --dsn | The VOLVRA_DSN environment variable | The libpq connection string. |
| --archive | None | The archive directory. |

Give the connection string as a URL or as keyword and value pairs.
Both forms work, because the companion parses the string rather than
appending to it.

The companion registers every flag for every command, so a flag that
does not apply to a command is accepted and ignored rather than
rejected. The tables below group each flag with the command the flag
affects.

## The run command

`run` creates the slot if the slot is absent, resumes from the archive,
and streams until interrupted:

```bash
volvra-companion run --dsn "$DATABASE_URL" \
    --archive /srv/volvra-archive \
    --slot volvra_companion \
    --publication volvra_pub \
    --segment-bytes 67108864 \
    --lag-warn 536870912 \
    --lag-max 5368709120
```

The following table describes each flag the command accepts:

| Flag | Default | Description |
|---|---|---|
| --slot | volvra_companion | The logical replication slot to read. |
| --publication | volvra_pub | The publication to stream. |
| --segment-bytes | 67108864, which is 64 MB | Rotate to a new segment once the current one reaches this size. |
| --lag-warn | 536870912, which is 512 MB | Log a warning once the slot retains this much write-ahead log. |
| --lag-max | 5368709120, which is 5 GB | Advance the slot past this volume and record the skipped range as a gap. |
| --s3-bucket | None | Upload rotated segments to this bucket. Object storage is off when unset. |
| --s3-endpoint | None | The S3 endpoint host, with no scheme. Required with --s3-bucket. |
| --s3-prefix | None | A key prefix within the bucket. |
| --s3-region | us-east-1 | The bucket region. |
| --s3-insecure | Off | Use plain HTTP. For a local test server only; it disables TLS. |
| --s3-checksum | auto | How an upload is verified: auto, server, or readback. Auto selects readback for Google Cloud Storage and server checksums elsewhere. |

The command requires `--dsn` and `--archive`.

## Object storage

Credentials are never taken as flags, because a flag puts them in the
process list and in shell history. The companion reads them from the
environment, the shared credentials file, or an instance or workload
identity role.

With a bucket configured, the replication slot does not advance past a
segment the bucket has not confirmed, so a bucket outage retains
write-ahead log rather than releasing it.

Google Cloud Storage rejects the aws-chunked trailing header that
carries a server-side checksum, so `--s3-checksum` defaults to `auto`
and selects read-back verification for `storage.googleapis.com`.
Read-back downloads each segment after uploading it, which doubles the
traffic; the companion says so at startup.

pgVolvra never sets an object lock retention. If the bucket enforces
one, the companion detects it and reports it, because `volvra.forget`
cannot erase an archived object while a retention stands. The Where the
Archive Is Stored document explains the consequences.

## How run acknowledges progress

The companion tells PostgreSQL that write-ahead log may be discarded
only up to a position the companion has written, flushed, and recorded
in the manifest. Acknowledging sooner would let PostgreSQL discard log
the archive does not hold.

The archive is therefore the authority on what is durable, rather than
the slot. On start, the companion resumes from the last position the
archive holds, even when the slot has confirmed a later position.

## The verify command

`verify` checks an archive with no database connection:

```bash
volvra-companion verify --archive /srv/volvra-archive
```

The command prints the archive path, the slot, the segment count, and
the change count, then either confirms the archive or lists one
finding per problem segment. The command exits non-zero when any
finding is present.

### Reading from a bucket

`verify` and `restore` accept the same `--s3-*` flags as `run`. Pass an
empty `--archive` to read the bucket alone, which is what a host loss
leaves you with:

```bash
volvra-companion verify --archive "" \
  --s3-bucket my-archive --s3-endpoint s3.us-east-1.amazonaws.com
```

## The restore command

`restore` verifies the archive, then loads the changes:

```bash
volvra-companion restore --archive /srv/volvra-archive \
    --dsn "$DATABASE_URL"
```

The following table describes the flag the command adds:

| Flag | Default | Description |
|---|---|---|
| --dry-run | Off | Parse and count without connecting to a database or changing anything. |

The command refuses an archive that does not verify. Gap and truncate
records carry no row image, so the command reports those as skipped.

Restored rows carry `actor` set to `archive:` followed by the log
position, and `db_user` set to `archive`, so restored history is
distinguishable from history the trigger tier captured.

## The status command

`status` reports the durable tier as the database sees it:

```bash
volvra-companion status --dsn "$DATABASE_URL"
```

The command calls `volvra.companion_status`, so the output matches
what that function returns in SQL.

## The archive on disk

An archive directory holds a manifest and one file per segment. The
following table describes the contents:

| Path | Contents |
|---|---|
| manifest.json | Archive metadata and one record per sealed segment. |
| 0000000001.ndjson | The first segment, one JSON change per line. |

The following table describes each field of a segment record in the
manifest:

| Field | Meaning |
|---|---|
| seq | Segment number. |
| file | Segment file name. |
| start_lsn | Log position of the first change in the segment. |
| end_lsn | Log position of the last change in the segment. |
| changes | Number of lines in the segment. |
| bytes | Size of the segment in bytes. |
| sha256 | Hash of the segment content. |
| prev | Chain value of the previous segment. |
| chain | Hash of the previous chain value and this segment's hash. |
| sealed_at | When the companion closed the segment. |

The following table describes the top-level manifest fields:

| Field | Meaning |
|---|---|
| archive | Always the string volvra. |
| format | Archive format version. |
| slot | Replication slot the archive belongs to. |
| publication | Publication the companion streamed. |
| created_at | When the archive was first opened. |
| segments | The array of segment records described above. |

The companion refuses to append to an archive whose slot differs from
the one given on the command line, so two slots cannot be mixed into
one archive.

## Change records

The following table describes each field of a change record:

| Field | Meaning |
|---|---|
| lsn | Log position of the change. |
| xid | Transaction identifier. |
| commit_ts | Commit timestamp of the transaction. |
| table | Schema-qualified table name, with every identifier quoted. |
| op | I for insert, U for update, D for delete, T for truncate. |
| pk | Primary key of the affected row. |
| old | Column values before the change. |
| new | Column values after the change. |

A gap record replaces the row fields with the following:

| Field | Meaning |
|---|---|
| gap | Always true. |
| from_lsn | Start of the range the companion could not archive. |
| to_lsn | End of that range. |
| reason | Why the range is missing. |

## Exit codes

The following table describes the exit codes:

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | An error occurred; the message names the cause. |
| 2 | The command line was invalid or unrecognized. |

## Removing a companion

Stop the companion, then drop the slot so the database stops retaining
write-ahead log:

```sql
SELECT pg_drop_replication_slot('volvra_companion');
DROP PUBLICATION volvra_pub;
```

Dropping the slot is the important step. A slot with no consumer
retains log indefinitely.

## Next Steps

- The [Companion Overview](companion.md) document explains what the
  companion is for.
- The [Troubleshooting](troubleshooting.md) document covers slot and
  replication problems.
