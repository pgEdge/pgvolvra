// volvra -- undo for Postgres.
//
// The engine is the SQL in sql/volvra.sql; this exists so that reverting a
// mistake is one command with one confirmation, rather than nine function
// calls and a guessed timestamp.
//
// This replaces an earlier bash wrapper over psql. The reasons for the change
// are the reasons anyone would want a binary here: it needs no psql on the
// PATH, so it runs in a container that has nothing else in it; it sends every
// user-supplied value as a bind parameter rather than through a hand-written
// quoting function, in a tool whose whole job is running UPDATE and DELETE
// against production; and it exits with codes a scheduler can act on.
//
// Connection comes from the standard PG* environment variables, or --dsn.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

const usage = `volvra -- undo for Postgres

  volvra status                       what is covered, and is it still capturing
  volvra uncovered [SCHEMA]           tables with no undo (default: public)
  volvra cover TABLE | --schema S     start covering changes
  volvra uncover TABLE | --schema S   stop covering (history is kept)

  volvra mark NAME [--note TEXT]      name a moment you may want back
  volvra marks                        marks, and what undoing to each costs
  volvra unmark NAME                  remove a mark (never the history)

  volvra log [-n N] [--since WHEN]    recent transactions, newest first
  volvra history TABLE PK_JSON        every version of one row
  volvra as-of TABLE WHEN             the table as it was, read-only

  volvra preview SELECTOR...          show the compensating SQL, change nothing
  volvra undo SELECTOR...             show it, ask once, then apply

  volvra preview-replay SELECTOR...   show what reapplying would do
  volvra replay SELECTOR...           reapply changes forward, after a restore

  volvra preflight                    is this install production-shaped?
  volvra maintain                     partitions + retention + seal, in one call
  volvra seal                         make the history so far provable
  volvra verify                       re-check every seal against the history
  volvra forget TABLE PK_JSON         erase one subject's history (asks first)

  volvra version                      what this binary is

SELECTOR (combine freely; at least one is required)
  --table TABLE          limit to a table          --txid N        one transaction
  --since WHEN           changes after WHEN        --until WHEN    changes up to WHEN
  --actor NAME           app-declared actor        --user NAME     database role
  --where SQL            predicate over old_row / new_row / pk
  --to NAME              everything since the mark NAME

OPTIONS
  --dsn DSN              libpq connection string (else PG* env vars)
  --yes                  skip the confirmation prompt
  --max-rows N           raise the blast-radius cap for this call
  --skip-conflicts       revert what still matches; leave changed rows alone
  -h, --help

EXIT CODES
  0  the command succeeded
  1  the command failed, or a confirmation was declined
  2  the command worked and what it found is bad -- preflight found something
     critical, or verify found history that does not match its seal

EXAMPLES
  volvra log -n 5
  volvra verify
  volvra preflight
  volvra forget people '{"id":1}' --reason 'GDPR art.17'

SCHEDULING
  volvra maintain      # run this hourly or daily; it is the only scheduled job
  volvra mark before-deploy --note 'release 042'
  volvra undo --to before-deploy                 # put it back how it was
  volvra undo --txid 848291                      # undo that migration
  volvra undo --table orders --since '10 min ago'
  volvra replay --table orders --since '10 min ago'   # after a restore
  volvra preview --actor svc:pricing --since today
  volvra undo --table orders --since '1 hour ago' \
              --where "old_row->>'customer' = 'acme'"
`

// version is set at build time by extension/build.sh and the Makefile:
//
//	go build -ldflags "-X main.version=$(git describe --tags --always)"
var version = "dev"

func main() {
	os.Exit(run())
}

func run() int {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Print(usage)
		return exitOK
	}

	dsn, yes := "", false

	// Global options may appear before the subcommand...
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--dsn":
			if i+1 >= len(args) {
				return fail("--dsn needs a value")
			}
			dsn = args[i+1]
			i += 2
		case "--yes", "-y":
			yes = true
			i++
		case "-h", "--help":
			fmt.Print(usage)
			return exitOK
		default:
			goto haveCmd
		}
	}
haveCmd:
	if i >= len(args) {
		fmt.Print(usage)
		return exitOK
	}
	cmd := args[i]
	rest := args[i+1:]

	// ...and after it, so `volvra undo --txid 1 --yes` works too.
	var kept []string
	for j := 0; j < len(rest); j++ {
		switch rest[j] {
		case "--dsn":
			if j+1 >= len(rest) {
				return fail("--dsn needs a value")
			}
			dsn = rest[j+1]
			j++
		case "--yes", "-y":
			yes = true
		case "-h", "--help":
			fmt.Print(usage)
			return exitOK
		default:
			kept = append(kept, rest[j])
		}
	}

	if cmd == "version" {
		fmt.Printf("volvra %s\n", version)
		return exitOK
	}

	ctx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := Connect(ctx, dsn)
	if err != nil {
		return fail("%v", err)
	}
	defer db.Close(context.Background())

	var code int
	switch cmd {
	case "status":
		code, err = cmdStatus(ctx, db, kept)
	case "uncovered":
		code, err = cmdUncovered(ctx, db, kept)
	case "cover":
		code, err = cmdCover(ctx, db, kept)
	case "uncover":
		code, err = cmdUncover(ctx, db, kept)
	case "mark":
		code, err = cmdMark(ctx, db, kept)
	case "marks":
		code, err = cmdMarks(ctx, db, kept)
	case "unmark":
		code, err = cmdUnmark(ctx, db, kept)
	case "log":
		code, err = cmdLog(ctx, db, kept)
	case "history":
		code, err = cmdHistory(ctx, db, kept)
	case "as-of":
		code, err = cmdAsOf(ctx, db, kept)
	case "preview":
		code, err = cmdPreview(ctx, db, kept)
	case "undo":
		code, err = cmdUndo(ctx, db, kept, yes)
	case "preview-replay":
		code, err = cmdPreviewReplay(ctx, db, kept)
	case "replay":
		code, err = cmdReplay(ctx, db, kept, yes)
	case "preflight":
		code, err = cmdPreflight(ctx, db, kept)
	case "maintain":
		code, err = cmdMaintain(ctx, db, kept)
	case "seal":
		code, err = cmdSeal(ctx, db, kept)
	case "verify":
		code, err = cmdVerify(ctx, db, kept)
	case "forget":
		code, err = cmdForget(ctx, db, kept, yes)
	default:
		return fail("unknown command: %s\nRun volvra --help.", cmd)
	}

	if err != nil {
		return fail("%v", err)
	}
	return code
}

func fail(format string, a ...any) int {
	fmt.Fprintf(os.Stderr, "volvra: "+format+"\n", a...)
	return exitError
}
