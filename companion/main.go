// volvra-companion -- the durable tier.
//
// The trigger tier shares fate with the database: it makes mistakes
// recoverable, but it is not a backup. This process reads a logical
// replication slot and writes change data to storage the customer owns, so the
// history survives the database itself.
//
// Two requirements the trigger tier does not have:
//
//	wal_level = logical    on the server
//	REPLICA IDENTITY FULL  on covered tables, so the WAL carries before images
//
// Run volvra.companion_setup() first; it does the second and tells you about
// the first.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5/pgconn"
)

const usage = `volvra-companion -- durable change archive for PostgreSQL

  volvra-companion run     --dsn DSN --archive DIR [--slot NAME] [--publication NAME]
                           [--segment-bytes N] [--lag-warn N] [--lag-max N]
                           [--s3-bucket NAME --s3-endpoint HOST [--s3-prefix P]]
                           [--s3-checksum auto|server|readback]
  volvra-companion verify  --archive DIR [--s3-bucket NAME --s3-endpoint HOST]
  volvra-companion restore --archive DIR --dsn DSN [--dry-run]
  volvra-companion status  --dsn DSN

Object storage is optional and additive. Segments are still written to local
disk and fsynced there; a segment is uploaded after it rotates, and the
replication slot does not advance past a segment the bucket has not confirmed.
Credentials come from the environment or an instance role, never from a flag.

Pass --archive "" with --s3-bucket to read an archive from a bucket alone,
which is the case this tier exists for: the host that wrote it is gone.

The archive is newline-delimited JSON in numbered segments, described by a
manifest that chains their SHA-256 hashes. It is readable without this binary
and without the database -- which is the point of it.

A replication slot retains WAL until it is consumed. If this process stops, the
database keeps WAL for it. --lag-max is the ceiling at which the slot is
advanced and the skipped range recorded as a gap, because a database that will
not start is worse than a hole you know about.
`

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}

	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("VOLVRA_DSN"), "libpq connection string (or VOLVRA_DSN)")
	archive := fs.String("archive", "", "archive directory")
	slot := fs.String("slot", "volvra_companion", "logical replication slot")
	pub := fs.String("publication", "volvra_pub", "publication to stream")
	segBytes := fs.Int64("segment-bytes", 64<<20, "rotate a segment at this size")
	lagWarn := fs.Int64("lag-warn", 512<<20, "warn when the slot retains this much WAL")
	lagMax := fs.Int64("lag-max", 5<<30, "advance the slot past this, recording a gap")
	dry := fs.Bool("dry-run", false, "restore: parse and count, change nothing")
	s3Bucket := fs.String("s3-bucket", "", "upload segments to this bucket")
	s3Endpoint := fs.String("s3-endpoint", "", "S3 endpoint host[:port], no scheme")
	s3Prefix := fs.String("s3-prefix", "", "key prefix within the bucket")
	s3Region := fs.String("s3-region", "us-east-1", "bucket region")
	s3Insecure := fs.Bool("s3-insecure", false, "plain HTTP; for a local test server only")
	s3Checksum := fs.String("s3-checksum", "auto",
		"how uploads are verified: auto, server, or readback (auto picks readback "+
			"for Google Cloud Storage, which rejects trailing-header checksums)")
	_ = fs.Parse(os.Args[2:])

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	ropts := RemoteOptions{
		Endpoint: *s3Endpoint, Bucket: *s3Bucket, Prefix: *s3Prefix,
		Region: *s3Region, Insecure: *s3Insecure, Checksum: *s3Checksum,
	}

	var err error
	switch cmd {
	case "run":
		err = cmdRun(ctx, *dsn, *archive, *slot, *pub, *segBytes, *lagWarn, *lagMax, ropts)
	case "verify":
		err = cmdVerify(ctx, *archive, ropts)
	case "restore":
		err = cmdRestore(ctx, *archive, *dsn, *dry, ropts)
	case "status":
		err = cmdStatus(ctx, *dsn)
	case "help", "-h", "--help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatalf("error: %v", err)
	}
}

// openSource resolves where the archive is read from and written to, and says
// out loud what object storage will do to the data.
//
// The announcement is not decoration. If the bucket makes objects immutable,
// then volvra.forget cannot erase the archived copy, and the person who turns
// this on is the person who needs to know that before a subject exercises a
// right to erasure. Saying it at startup, and recording it in the database, is
// how that reaches them rather than sitting in a document nobody opened.
func openSource(ctx context.Context, dir string, o RemoteOptions) (Source, error) {
	src := Source{Dir: dir}
	if o.Bucket == "" {
		if dir == "" {
			return src, fmt.Errorf("--archive is required")
		}
		return src, nil
	}
	r, err := NewRemote(ctx, o)
	if err != nil {
		return src, err
	}
	src.Remote = r

	if r.Checksum() == "readback" {
		// Worth saying out loud: this doubles the bytes moved per segment, and
		// on a provider that bills egress that is a real recurring cost rather
		// than a detail of the implementation.
		log.Printf("NOTICE: uploads are verified by reading each segment back, "+
			"which doubles the traffic per segment (%s)", r.URI())
	}

	if l := r.Lock(); l.Enabled {
		log.Printf("NOTICE: this bucket enforces object lock on %s: %s", r.URI(), l)
		log.Printf("NOTICE: objects archived here cannot be deleted or overwritten for %d day(s)",
			l.Days)
		if l.Mode == "COMPLIANCE" {
			log.Printf("WARNING: COMPLIANCE mode cannot be bypassed by anyone, including " +
				"the account root")
		}
		log.Printf("WARNING: volvra.forget() redacts history in the database; it cannot " +
			"erase an archived object while that retention stands")
	}
	return src, nil
}

func require(name, v string) error {
	if v == "" {
		return fmt.Errorf("--%s is required", name)
	}
	return nil
}

func cmdRun(ctx context.Context, dsn, dir, slot, pub string,
	segBytes, lagWarn, lagMax int64, o RemoteOptions) error {

	if err := require("dsn", dsn); err != nil {
		return err
	}
	if err := require("archive", dir); err != nil {
		return err
	}

	arch, err := OpenArchive(dir, slot, pub, segBytes)
	if err != nil {
		return err
	}
	defer arch.Close()

	src, err := openSource(ctx, dir, o)
	if err != nil {
		return err
	}
	if src.Remote != nil {
		arch.UseRemote(src.Remote)
		// Finish what a previous run started. A segment uploaded but not
		// recorded, or recorded but never uploaded, is the normal residue of a
		// crash, and the slot is being held back by it until this succeeds.
		if n := arch.PendingUploads(); n > 0 {
			log.Printf("%d segment(s) not yet in %s, uploading before streaming",
				n, src.Remote.URI())
		}
		if err := arch.PushRemote(ctx); err != nil {
			return fmt.Errorf("could not reach the bucket at startup: %w", err)
		}
	}

	st, err := NewStreamer(ctx, dsn, slot, pub, arch, nil)
	if err != nil {
		return err
	}
	defer st.Close(context.Background())

	// Resume from what the archive actually holds, never from what the slot
	// thinks: the archive is the authority on what is durable.
	start, err := st.EnsureSlot(ctx)
	if err != nil {
		return err
	}
	if l := arch.ResumeLSN(); l != "" {
		if p, perr := pglogrepl.ParseLSN(l); perr == nil && p > start {
			log.Printf("archive already holds up to %s, resuming there", p)
			start = p
		}
	}

	abs, _ := filepath.Abs(dir)
	if src.Remote != nil {
		// The database records where the archive really lives, so someone
		// reading volvra.companion_checkpoint can find it without this host.
		abs = src.Remote.URI()
	}
	st.guard = &SlotGuard{
		meta: st.meta, repl: st.repl, slot: slot,
		warnBytes: lagWarn, maxBytes: lagMax, arch: arch,
		onGap: func(from, to pglogrepl.LSN, reason, detail string) error {
			res := st.meta.ExecParams(ctx,
				"SELECT volvra.companion_record_gap($1,$2,$3,$4,$5)",
				[][]byte{[]byte(slot), []byte(from.String()), []byte(to.String()),
					[]byte(reason), []byte(detail)}, nil, nil, nil).Read()
			return res.Err
		},
	}

	report := func(l pglogrepl.LSN) {
		segs, changes := arch.Stats()
		res := st.meta.ExecParams(ctx,
			"SELECT volvra.companion_report($1,$2,$3,$4,$5)",
			[][]byte{[]byte(slot), []byte(l.String()),
				[]byte(fmt.Sprint(segs)), []byte(fmt.Sprint(changes)),
				[]byte(abs)}, nil, nil, nil).Read()
		if res.Err != nil {
			// Reporting is observability, not durability: the archive is
			// already on disk, so a database that will not take the checkpoint
			// must not stop the stream.
			log.Printf("note: could not record checkpoint: %v", res.Err)
		}
	}

	// Tell the database what object storage will do to the archive, so that
	// volvra.forget() and volvra.preflight() can say it to the person who
	// needs to hear it. Best effort: an older database has no such function,
	// and that must not stop the companion from archiving.
	if src.Remote != nil {
		if l := src.Remote.Lock(); l.Enabled {
			res := st.meta.ExecParams(ctx,
				"SELECT volvra.companion_report_immutable($1,$2,$3,$4)",
				[][]byte{[]byte(slot), []byte(l.Mode),
					[]byte(fmt.Sprint(l.Days)), []byte(l.Source)},
				nil, nil, nil).Read()
			if res.Err != nil {
				log.Printf("note: could not record the object lock state: %v", res.Err)
			}
		}
	}

	log.Printf("archiving slot %s to %s", slot, src.describe())
	err = st.Run(ctx, start, report)
	if cerr := arch.Close(); cerr != nil && err == nil {
		err = cerr
	}
	if err == nil {
		segs, changes := arch.Stats()
		log.Printf("stopped cleanly: %d segment(s), %d change(s) archived", segs, changes)
	}
	return err
}

func cmdVerify(ctx context.Context, dir string, o RemoteOptions) error {
	src, err := openSource(ctx, dir, o)
	if err != nil {
		return err
	}
	findings, m, err := VerifyArchive(ctx, src)
	if err != nil {
		return err
	}

	var changes int64
	for _, s := range m.Segments {
		changes += s.Changes
	}
	fmt.Printf("archive  %s\n", src.describe())
	fmt.Printf("slot     %s\n", m.Slot)
	fmt.Printf("segments %d\n", len(m.Segments))
	fmt.Printf("changes  %d\n", changes)

	fatal := 0
	for _, f := range findings {
		if f.Fatal() {
			fatal++
		}
	}

	if len(findings) == 0 {
		fmt.Println("\nEvery segment matches its manifest entry, and the chain is intact.")
		return nil
	}
	fmt.Printf("\n%d finding(s):\n", len(findings))
	for _, f := range findings {
		seg := fmt.Sprintf("%d", f.Segment)
		if f.Segment < 0 {
			seg = "-"
		}
		fmt.Printf("  segment %-4s %-16s %s\n", seg, f.Verdict, f.Detail)
	}
	if fatal == 0 {
		fmt.Println("\nEvery recorded segment matches its manifest entry, and the chain " +
			"is intact. The findings above are notices, not integrity failures.")
		return nil
	}
	return fmt.Errorf("archive verification failed")
}

func cmdRestore(ctx context.Context, dir, dsn string, dry bool, o RemoteOptions) error {
	src, err := openSource(ctx, dir, o)
	if err != nil {
		return err
	}
	if !dry {
		if err := require("dsn", dsn); err != nil {
			return err
		}
	}

	// Never load an archive that does not verify: a restore is exactly the
	// moment its integrity matters.
	findings, _, err := VerifyArchive(ctx, src)
	if err != nil {
		return err
	}
	fatal := false
	for _, f := range findings {
		fmt.Fprintf(os.Stderr, "  segment %-4d %-16s %s\n", f.Segment, f.Verdict, f.Detail)
		fatal = fatal || f.Fatal()
	}
	if fatal {
		return fmt.Errorf("refusing to restore an archive that does not verify")
	}

	loaded, skipped, err := RestoreArchive(ctx, src, dsn, dry)
	if err != nil {
		return err
	}
	what := "loaded into volvra.change_log"
	if dry {
		what = "would be loaded (dry run)"
	}
	fmt.Printf("%d change(s) %s, %d skipped (gaps and truncates carry no row image)\n",
		loaded, what, skipped)
	if !dry {
		fmt.Println("\nUndo them the ordinary way, with the conflict guard and the cap:")
		fmt.Println("  SELECT * FROM volvra.preview_undo('your_table', <from>, <to>);")
	}
	return nil
}

func cmdStatus(ctx context.Context, dsn string) error {
	if err := require("dsn", dsn); err != nil {
		return err
	}
	conn, err := pgconn.Connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())

	res := conn.ExecParams(ctx,
		"SELECT item, value, status FROM volvra.companion_status()",
		nil, nil, nil, nil).Read()
	if res.Err != nil {
		return res.Err
	}
	for _, row := range res.Rows {
		fmt.Printf("%-18s %-28s %s\n", string(row[0]), string(row[1]), string(row[2]))
	}
	_ = time.Now
	return nil
}
