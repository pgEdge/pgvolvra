package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Finding struct {
	Segment int
	Verdict string
	Detail  string
}

// Fatal separates integrity failures from notices. An UNRECORDED segment is
// the normal residue of a companion that was killed mid-segment, so it must
// not make verification fail; it still has to be reported, because the archive
// is documented as readable without this binary, and a reader walking the
// directory would otherwise trust a file nothing vouched for.
func (f Finding) Fatal() bool { return f.Verdict != "UNRECORDED" }

// VerifyArchive re-hashes every segment and re-walks the chain. It needs no
// database: an archive whose integrity depends on the system that produced it
// is not a durable copy of anything.
//
// It reads through the Source, so the same check runs against a local
// directory, against a bucket, or against both. Verifying the bucket's copy is
// the point when the host is gone, and it is also the only way to notice that
// an upload stored something different from what was sealed.
func VerifyArchive(ctx context.Context, src Source) ([]Finding, *Manifest, error) {
	m, err := ReadManifestFrom(ctx, src)
	if err != nil {
		return nil, nil, err
	}

	var out []Finding
	prevChain := ""
	prevEnd := ""

	for _, seg := range m.Segments {
		f, err := src.Open(ctx, seg.File)
		if err != nil {
			out = append(out, Finding{seg.Seq, "MISSING", err.Error()})
			prevChain = seg.Chain
			continue
		}

		h := sha256.New()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
		var lines int64
		badJSON := 0
		for sc.Scan() {
			b := append(sc.Bytes(), '\n')
			h.Write(b)
			lines++
			var c Change
			if json.Unmarshal(sc.Bytes(), &c) != nil {
				badJSON++
			}
		}
		scanErr := sc.Err()
		f.Close()
		if scanErr != nil {
			out = append(out, Finding{seg.Seq, "UNREADABLE", scanErr.Error()})
			prevChain = seg.Chain
			continue
		}

		sum := hex.EncodeToString(h.Sum(nil))
		chain := sha256.Sum256([]byte(prevChain + "|" + seg.SHA256))

		switch {
		case sum != seg.SHA256:
			out = append(out, Finding{seg.Seq, "TAMPERED",
				fmt.Sprintf("content hash %s, manifest says %s", sum[:16], seg.SHA256[:16])})
		case seg.Prev != prevChain:
			out = append(out, Finding{seg.Seq, "CHAIN BROKEN",
				"this segment does not follow the previous one -- one was removed, " +
					"reordered or inserted"})
		case hex.EncodeToString(chain[:]) != seg.Chain:
			out = append(out, Finding{seg.Seq, "MANIFEST FORGED",
				"the manifest entry itself has been altered"})
		case lines != seg.Changes:
			out = append(out, Finding{seg.Seq, "TRUNCATED",
				fmt.Sprintf("%d lines present, %d recorded", lines, seg.Changes)})
		case badJSON > 0:
			out = append(out, Finding{seg.Seq, "CORRUPT",
				fmt.Sprintf("%d line(s) are not valid change records", badJSON)})
		}

		// A break in LSN continuity between segments is only alarming if no gap
		// was recorded for it -- the companion writes one when it skips.
		if prevEnd != "" && seg.StartLSN != "" && !gapRecorded(ctx, src, m, seg.Seq) &&
			seg.StartLSN < prevEnd {
			out = append(out, Finding{seg.Seq, "OUT OF ORDER",
				fmt.Sprintf("starts at %s, previous ended at %s", seg.StartLSN, prevEnd)})
		}

		prevChain = seg.Chain
		prevEnd = seg.EndLSN
	}

	out = append(out, unrecorded(src.Dir, m)...)
	return out, m, nil
}

// unrecorded finds segment files on disk that no manifest entry covers. A
// SIGKILL leaves one, because a segment reaches the manifest only when it is
// closed; so does anyone dropping a file into the directory by hand.
func unrecorded(dir string, m *Manifest) []Finding {
	// Local disk only. A bucket contains exactly what was uploaded against a
	// manifest entry, so there is no equivalent of a half-written file left by
	// a SIGKILL, and nothing to report.
	if dir == "" {
		return nil
	}
	known := make(map[string]bool, len(m.Segments))
	for _, s := range m.Segments {
		known[s.File] = true
	}
	names, err := filepath.Glob(filepath.Join(dir, "*.ndjson"))
	if err != nil {
		return nil
	}
	var out []Finding
	for _, n := range names {
		base := filepath.Base(n)
		if known[base] {
			continue
		}
		lines := int64(0)
		if f, err := os.Open(n); err == nil {
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
			for sc.Scan() {
				lines++
			}
			f.Close()
		}
		out = append(out, Finding{-1, "UNRECORDED", fmt.Sprintf(
			"%s holds %d line(s) that no manifest entry covers -- expected if the "+
				"companion was killed mid-segment, otherwise the file was added by hand",
			base, lines)})
	}
	return out
}

func gapRecorded(ctx context.Context, src Source, m *Manifest, seq int) bool {
	for _, s := range m.Segments {
		if s.Seq != seq && s.Seq != seq-1 {
			continue
		}
		f, err := src.Open(ctx, s.File)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
		for sc.Scan() {
			var c Change
			if json.Unmarshal(sc.Bytes(), &c) == nil && c.Gap {
				f.Close()
				return true
			}
		}
		f.Close()
	}
	return false
}
