package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/jackc/pgx/v5/pgconn"
)

// An archive nobody can load back is a write-only backup, which is no backup
// at all. Restore loads archived changes into volvra.change_log so that the
// ordinary undo path -- preview, conflict guard, blast-radius cap -- drives
// them, rather than inventing a second, less careful recovery path.
//
// pgoutput sends values as text, so every value is normalised back through the
// target table's own row type on the way in. That is what keeps the archived
// history byte-comparable with history the trigger tier captured, which the
// conflict guard depends on.
// normaliseSQL builds the per-table statement. The table name cannot be a
// parameter -- it is an identifier -- so it is taken from the archive and
// resolved through to_regclass, which fails closed on anything that is not a
// real table.
func normaliseSQL(table string) string {
	return fmt.Sprintf(`
WITH t AS (SELECT to_regclass(%s) AS rel)
INSERT INTO volvra.change_log
  (table_name, op, pk, old_row, new_row, actor, db_user, txid, ts)
-- The canonical name comes from the database, not from the archive: the
-- companion quotes every identifier, volvra quotes only what needs it, and a
-- table_name that does not match byte for byte is history the undo cannot see.
SELECT volvra._fqname(t.rel), $1,
       CASE WHEN $2::jsonb IS NULL THEN '{}'::jsonb ELSE $2::jsonb END,
       CASE WHEN $3::jsonb IS NULL THEN NULL
            ELSE to_jsonb(jsonb_populate_record(NULL::%s, $3::jsonb)) END,
       CASE WHEN $4::jsonb IS NULL THEN NULL
            ELSE to_jsonb(jsonb_populate_record(NULL::%s, $4::jsonb)) END,
       'archive:' || coalesce($5, 'unknown'), 'archive', coalesce($6::bigint, 0), $7::timestamptz
FROM t WHERE t.rel IS NOT NULL`,
		quoteLiteral(table), table, table)
}

func quoteLiteral(s string) string {
	out := make([]byte, 0, len(s)+2)
	out = append(out, '\'')
	for i := 0; i < len(s); i++ {
		if s[i] == '\'' {
			out = append(out, '\'')
		}
		out = append(out, s[i])
	}
	return string(append(out, '\''))
}

func RestoreArchive(ctx context.Context, src Source, dsn string, dry bool) (int64, int64, error) {
	m, err := ReadManifestFrom(ctx, src)
	if err != nil {
		return 0, 0, err
	}

	var conn *pgconn.PgConn
	if !dry {
		conn, err = pgconn.Connect(ctx, dsn)
		if err != nil {
			return 0, 0, err
		}
		defer conn.Close(ctx)
	}

	var loaded, skipped int64
	for _, seg := range m.Segments {
		f, err := src.Open(ctx, seg.File)
		if err != nil {
			return loaded, skipped, err
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 64<<20)

		for sc.Scan() {
			var c Change
			if err := json.Unmarshal(sc.Bytes(), &c); err != nil {
				skipped++
				continue
			}
			// Gaps and truncates carry no row image, so there is nothing to
			// load; they are the archive's record that something is missing.
			if c.Gap || c.Op == "" || c.Op == "T" {
				skipped++
				continue
			}
			if dry {
				loaded++
				continue
			}
			res := conn.ExecParams(ctx, normaliseSQL(c.Table), [][]byte{
				[]byte(c.Op),
				rawOrNil(c.PK),
				rawOrNil(c.Old),
				rawOrNil(c.New),
				[]byte(c.LSN),
				[]byte(fmt.Sprint(c.XID)),
				[]byte(c.CommitTS.Format("2006-01-02T15:04:05.999999Z07:00")),
			}, nil, nil, nil).Read()
			if res.Err != nil {
				f.Close()
				return loaded, skipped, fmt.Errorf("segment %d, lsn %s: %w",
					seg.Seq, c.LSN, res.Err)
			}
			loaded++
		}
		if err := sc.Err(); err != nil {
			f.Close()
			return loaded, skipped, err
		}
		f.Close()
		log.Printf("segment %d: %d change(s) loaded", seg.Seq, seg.Changes)
	}
	return loaded, skipped, nil
}

func rawOrNil(r json.RawMessage) []byte {
	if len(r) == 0 || string(r) == "null" {
		return nil
	}
	return r
}
