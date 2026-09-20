package main

import (
	"context"
	"fmt"
	"os"
)

// Every command returns an exit code alongside its error, because some
// outcomes are neither success nor a program fault: a failing verify is a
// correct answer to a real question, and it has to be distinguishable from a
// connection error by a scheduler.
const (
	exitOK      = 0
	exitError   = 1
	exitFinding = 2 // the command worked; what it found is bad
)

func cmdStatus(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx, `
		SELECT table_name AS "table", covered,
		       truncate_covered AS "truncate covered",
		       changes, newest_change AS "last change"
		FROM volvra.status()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)

	// status() is the raw picture; health() is the interpretation.
	n, err := db.Count(ctx, `SELECT count(*) FROM volvra.health()`)
	if err != nil {
		return exitError, err
	}
	if n == 0 {
		fmt.Println("\nNo problems reported.")
		return exitOK, nil
	}
	fmt.Println()
	h, err := db.Query(ctx, `SELECT severity, problem, detail FROM volvra.health()`)
	if err != nil {
		return exitError, err
	}
	h.Write(os.Stdout)
	return exitOK, nil
}

func cmdUncovered(ctx context.Context, db *DB, args []string) (int, error) {
	schema := "public"
	if len(args) > 0 {
		schema = args[0]
	}
	t, err := db.Query(ctx, `
		SELECT table_name AS "table", reason FROM volvra.uncovered($1)`, schema)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdCover(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) == 0 {
		return exitError, fmt.Errorf("cover needs a table, or --schema SCHEMA")
	}
	if args[0] == "--schema" {
		if len(args) < 2 {
			return exitError, fmt.Errorf("--schema needs a value")
		}
		t, err := db.Query(ctx, `
			SELECT table_name AS "table", status, detail
			FROM volvra.enable_all($1)`, args[1])
		if err != nil {
			return exitError, err
		}
		t.Write(os.Stdout)
		return exitOK, nil
	}
	t, err := db.Query(ctx,
		`SELECT volvra.enable($1::regclass) AS result`, args[0])
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdUncover(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) == 0 {
		return exitError, fmt.Errorf("uncover needs a table, or --schema SCHEMA")
	}
	if args[0] == "--schema" {
		if len(args) < 2 {
			return exitError, fmt.Errorf("--schema needs a value")
		}
		t, err := db.Query(ctx, `
			SELECT table_name AS "table", status FROM volvra.disable_all($1)`, args[1])
		if err != nil {
			return exitError, err
		}
		t.Write(os.Stdout)
		return exitOK, nil
	}
	t, err := db.Query(ctx,
		`SELECT volvra.disable($1::regclass) AS result`, args[0])
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdPreflight(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx,
		`SELECT severity, finding, detail FROM volvra.preflight()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)

	crit, err := db.Count(ctx,
		`SELECT count(*) FROM volvra.preflight() WHERE severity = 'critical'`)
	if err != nil {
		return exitError, err
	}
	if crit > 0 {
		fmt.Fprintf(os.Stderr,
			"\n! %d critical finding(s). Do not run this install in production yet.\n",
			crit)
		return exitFinding, nil
	}
	fmt.Println("\nNothing critical. Warnings above are worth reading anyway.")
	return exitOK, nil
}

func cmdMaintain(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx,
		`SELECT step, detail, affected FROM volvra.maintain()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdSeal(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx, `
		SELECT seal_id, from_id, to_id, row_count AS changes,
		       left(chain_hash, 16) || '…' AS chain
		FROM volvra.seal()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)

	n, err := db.Count(ctx, `
		SELECT count(*) FROM volvra.change_log
		WHERE id > coalesce((SELECT max(to_id) FROM volvra.seal), 0)`)
	if err != nil {
		return exitError, err
	}
	if n == 0 {
		fmt.Println("\nAll history is sealed.")
	} else {
		fmt.Printf("\n%d change(s) still unsealed.\n", n)
	}
	return exitOK, nil
}

func cmdVerify(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx, `
		SELECT seal_id, from_id, to_id, rows_sealed, rows_found, verdict, detail
		FROM volvra.verify()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)

	bad, err := db.Count(ctx, `
		SELECT count(*) FROM volvra.verify()
		WHERE verdict IN ('TAMPERED', 'CHAIN BROKEN', 'SEAL FORGED')`)
	if err != nil {
		return exitError, err
	}
	if bad > 0 {
		fmt.Fprintf(os.Stderr,
			"\n! %d sealed span(s) do not match the history and nothing lawful\n"+
				"  explains it. Treat this as an integrity incident.\n", bad)
		return exitFinding, nil
	}
	fmt.Println("\nEvery seal matches the history.")
	return exitOK, nil
}

func cmdMark(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) == 0 {
		return exitError, fmt.Errorf("mark needs a name")
	}
	name := args[0]
	note, replace := "", false
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--note":
			if i+1 >= len(args) {
				return exitError, fmt.Errorf("--note needs a value")
			}
			note = args[i+1]
			i++
		case "--replace":
			replace = true
		default:
			return exitError, fmt.Errorf("unknown option for mark: %s", args[i])
		}
	}
	t, err := db.Query(ctx,
		`SELECT volvra.mark($1, $2, p_replace => $3) AS marked_at`,
		name, nullable(note), replace)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdMarks(ctx context.Context, db *DB, _ []string) (int, error) {
	t, err := db.Query(ctx, `
		SELECT name, at, age, created_by,
		       changes_since AS "changes since",
		       tables_since  AS "tables", note
		FROM volvra.marks()`)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdUnmark(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) == 0 {
		return exitError, fmt.Errorf("unmark needs a name")
	}
	t, err := db.Query(ctx, `SELECT volvra.unmark($1) AS removed`, args[0])
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdLog(ctx context.Context, db *DB, args []string) (int, error) {
	n, since := "20", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-n":
			if i+1 >= len(args) {
				return exitError, fmt.Errorf("-n needs a value")
			}
			n = args[i+1]
			i++
		case "--since":
			if i+1 >= len(args) {
				return exitError, fmt.Errorf("--since needs a value")
			}
			since = args[i+1]
			i++
		default:
			return exitError, fmt.Errorf("unknown option for log: %s", args[i])
		}
	}
	t, err := db.Query(ctx, `
		SELECT txid, ended AS "when",
		       array_to_string(db_users, ',') AS "by",
		       array_to_string(tables, ', ')  AS "tables",
		       inserts AS ins, updates AS upd, deletes AS del, changes
		FROM volvra.transactions($1::timestamptz, NULL, $2::integer)`,
		nullable(since), n)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdHistory(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) != 2 {
		return exitError, fmt.Errorf(
			`history needs a table and a pk as JSON, e.g. history orders '{"id":1}'`)
	}
	t, err := db.Query(ctx, `
		SELECT change_id, ts AS "when", op, actor, db_user AS "role",
		       old_row, new_row
		FROM volvra.history($1::regclass, $2::jsonb)`, args[0], args[1])
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

// as_of returns one jsonb object per row.  Expanding those into typed columns
// needs the table's rowtype, which cannot be a bind parameter, and pasting a
// user-supplied name into SQL is exactly what this CLI exists to avoid.  The
// rows are printed as JSON instead; jsonb_populate_record is the documented
// way to get typed columns from SQL.
func cmdAsOf(ctx context.Context, db *DB, args []string) (int, error) {
	if len(args) != 2 {
		return exitError, fmt.Errorf(
			"as-of needs a table and a time, e.g. as-of orders '2026-09-16 15:39'\n" +
				`a trailing "ago" works too: as-of orders '2 hours ago'`)
	}
	t, err := db.Query(ctx,
		`SELECT r AS row FROM volvra.as_of($1::regclass, `+when("$2")+`) AS r`,
		args[0], args[1])
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

func cmdForget(ctx context.Context, db *DB, args []string, yes bool) (int, error) {
	if len(args) < 2 {
		return exitError, fmt.Errorf("forget needs a table and a pk as JSON")
	}
	tbl, pk := args[0], args[1]
	hard, reason := false, ""
	for i := 2; i < len(args); i++ {
		switch args[i] {
		case "--hard":
			hard = true
		case "--reason":
			if i+1 >= len(args) {
				return exitError, fmt.Errorf("--reason needs a value")
			}
			reason = args[i+1]
			i++
		default:
			return exitError, fmt.Errorf("unknown option for forget: %s", args[i])
		}
	}

	t, err := db.Query(ctx, `
		SELECT count(*) AS history_rows, min(ts) AS first_seen, max(ts) AS last_seen
		FROM volvra.change_log
		WHERE table_name = volvra._fqname($1::regclass)
		  AND pk @> $2::jsonb`, tbl, pk)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)

	if hard {
		fmt.Println("\nHard erasure DELETES these history rows outright.")
	} else {
		fmt.Println("\nRedaction blanks the row images and keeps the fact that a change")
		fmt.Println("happened. Use --hard when the primary key is itself personal data.")
	}
	fmt.Println("This cannot be undone.")

	ok, err := confirm("Erase this subject's history?", yes)
	if err != nil {
		return exitError, err
	}
	if !ok {
		fmt.Println("Nothing was changed.")
		return exitError, nil
	}

	// NULL, not an empty string: the ledger must distinguish "no reason given"
	// from "reason given as empty".
	out, err := db.Query(ctx, `
		SELECT mode, rows_erased, from_id, to_id
		FROM volvra.forget($1::regclass, $2::jsonb, hard => $3, reason => $4)`,
		tbl, pk, hard, nullable(reason))
	if err != nil {
		return exitError, err
	}
	out.Write(os.Stdout)
	return exitOK, nil
}
