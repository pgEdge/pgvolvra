#!/usr/bin/env bash
# =====================================================================
# pgVolvra CLI test -- runs inside the container against the real database.
# Every command is exercised, and the destructive one is checked twice:
# once that it refuses without confirmation, once that it works with it.
#
# Exit codes are asserted as carefully as output, because a scheduler acts on
# them: 0 succeeded, 1 failed or a confirmation was declined, 2 the command
# worked and what it found is bad.
# =====================================================================
set -uo pipefail

# The CLI is a Go binary; the runner cross-builds one for linux and copies it
# into the container, then points VOLVRA_BIN at it.
V="${VOLVRA_BIN:-/volvra-cli}"
[[ -x "$V" ]] || { echo "  FAIL no volvra binary at $V"; exit 1; }
# PGDATABASE comes from the runner so this suite gets a clean database of
# its own -- other phases deliberately leave damage behind.
export PGUSER=postgres
: "${PGDATABASE:=volvra_test}"; export PGDATABASE
FAILED=0

ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }

# Run a command, report pass/fail, and on failure show why -- a CLI test that
# only says FAIL is a test you have to re-run by hand to learn anything from.
try() {
  local label="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    ok "$label"
  else
    bad "$label"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# Never pipe a volvra command straight into grep: grep -q closes the pipe on
# the first match, the command's next query dies with SIGPIPE, and pipefail
# turns that into a spurious failure.  Capture the output first.
says() {   # says <label> <needle> <cmd...>
  local label="$1" needle="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  case "$out" in
    *"$needle"*) ok "$label" ;;
    *)           bad "$label"; printf '%s\n' "$out" | sed 's/^/       | /' ;;
  esac
}

q() { psql -tA -v ON_ERROR_STOP=1 -c "$1"; }

printf '=== C0. fixture ===\n'
psql -q -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS cli_orders;
CREATE TABLE cli_orders (id int PRIMARY KEY, customer text, total numeric);
SQL

printf '=== C1. help and status ===\n'
"$V" --help  >/dev/null 2>&1 && ok "--help"         || bad "--help"
"$V" status  >/dev/null 2>&1 && ok "status"          || bad "status"
"$V" uncovered >/dev/null 2>&1 && ok "uncovered"         || bad "uncovered"
says "uncovered lists the new table" cli_orders "$V" uncovered

printf '=== C2. cover ===\n'
"$V" cover cli_orders >/dev/null 2>&1 && ok "cover" || bad "cover"
says "status shows it covered" cli_orders "$V" status

psql -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO cli_orders VALUES (1,'acme',100), (2,'globex',250);
SQL

printf '=== C3. the accident, then log ===\n'
BAD_TXID=$(psql -tA -v ON_ERROR_STOP=1 <<'SQL' | tail -1
BEGIN;
SELECT txid_current();
UPDATE cli_orders SET total = 0;
COMMIT;
SQL
)
BAD_TXID=$(psql -tA -c "SELECT txid FROM volvra.transactions() ORDER BY ended DESC LIMIT 1")
[[ -n "$BAD_TXID" ]] && ok "captured txid $BAD_TXID" || bad "could not read a txid"
"$V" log -n 3 >/dev/null 2>&1 && ok "log" || bad "log"
says "log shows the bad transaction" "$BAD_TXID" "$V" log -n 3

printf '=== C3b. as-of ===\n'
# Self-contained: a time before the table existed would correctly return
# nothing, so the mark has to sit between the insert and the change.
psql -q -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS cli_asof;
CREATE TABLE cli_asof (id int PRIMARY KEY, v text);
INSERT INTO cli_asof VALUES (1,'ORIGINAL');
SELECT volvra.enable('cli_asof');
SQL
sleep 1
ASOF_MARK=$(psql -tA -c "SELECT clock_timestamp()")
sleep 1
psql -q -c "UPDATE cli_asof SET v='CHANGED'" >/dev/null

ASOF=$("$V" as-of cli_asof "$ASOF_MARK" 2>&1)
case "$ASOF" in
  *ORIGINAL*) ok "as-of shows the value from before the change" ;;
  *)          bad "as-of shows the value from before the change"
              printf '%s\n' "$ASOF" | sed 's/^/       | /' ;;
esac
case "$ASOF" in
  *CHANGED*) bad "as-of must not show the current value" ;;
  *)         ok "as-of does not show the current value" ;;
esac

# "ago" is resolved on the server; it was broken in the bash CLI.  Which
# value comes back depends on where the second boundary falls, so this
# asserts only that the form is accepted and answers.
AGO=$("$V" as-of cli_asof '30 seconds ago' 2>&1)
if [ $? -eq 0 ] && printf '%s' "$AGO" | grep -qE 'ORIGINAL|CHANGED'; then
  ok "as-of accepts a relative time"
else
  bad "as-of accepts a relative time"
  printf '%s\n' "$AGO" | sed 's/^/       | /'
fi

"$V" as-of cli_asof 'not a time' >/dev/null 2>&1 \
  && bad "as-of rejects an unparsable time" \
  || ok "as-of rejects an unparsable time"

printf '=== C4. history ===\n'
"$V" history cli_orders '{"id":1}' >/dev/null 2>&1 && ok "history" || bad "history"
HIST=$("$V" history cli_orders '{"id":1}' 2>&1)
# Assert on the values, not on the table drawing: the old assertion counted
# ASCII "|" separators, which stopped meaning anything the moment the CLI drew
# its own tables.
case "$HIST" in
  *100*0*) ok "history shows both versions" ;;
  *)       bad "history shows both versions"
           printf '%s\n' "$HIST" | sed 's/^/       | /' ;;
esac

printf '=== C5. preview changes nothing ===\n'
"$V" preview --txid "$BAD_TXID" >/dev/null 2>&1 && ok "preview" || bad "preview"
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 0")" == "2" ]] \
  && ok "preview executed nothing" || bad "preview executed nothing"

printf '=== C6. a selector is mandatory ===\n'
"$V" undo --yes >/dev/null 2>&1 && bad "undo with no selector was allowed" \
                                || ok "undo with no selector is refused"
"$V" preview --bogus x >/dev/null 2>&1 && bad "unknown option accepted" \
                                       || ok "unknown option rejected"

printf '=== C7. undo will not apply without confirmation ===\n'
# no tty and no --yes: must refuse rather than assume
"$V" undo --txid "$BAD_TXID" </dev/null >/dev/null 2>&1 \
  && bad "undo applied without confirmation" \
  || ok "undo refuses without a confirmation"
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 0")" == "2" ]] \
  && ok "still nothing applied" || bad "still nothing applied"

printf '=== C8. undo --yes applies it ===\n'
"$V" undo --yes --txid "$BAD_TXID" >/dev/null 2>&1 && ok "undo --yes" || bad "undo --yes"
[[ "$(q "SELECT total FROM cli_orders WHERE id = 1")" == "100" ]] \
  && ok "order 1 restored" || bad "order 1 restored"
[[ "$(q "SELECT total FROM cli_orders WHERE id = 2")" == "250" ]] \
  && ok "order 2 restored" || bad "order 2 restored"

printf '=== C9. selector variants ===\n'
# A precise lower bound: '1 minute ago' would also sweep in C8's own undo.
SINCE=$(q "SELECT clock_timestamp()")
psql -q -v ON_ERROR_STOP=1 -c "SELECT pg_sleep(0.05)" >/dev/null
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_orders SET customer = 'wrong'"
try "undo --table --since --where" \
  "$V" undo --yes --table cli_orders --since "$SINCE" \
       --where "old_row->>'customer' = 'acme'"
[[ "$(q "SELECT customer FROM cli_orders WHERE id = 1")" == "acme" ]] \
  && ok "predicate limited the undo" || bad "predicate limited the undo"
[[ "$(q "SELECT customer FROM cli_orders WHERE id = 2")" == "wrong" ]] \
  && ok "the non-matching row was untouched" || bad "the non-matching row was untouched"

printf '=== C10. a predicate cannot inject ===\n'
"$V" preview --table cli_orders --where "true); DROP TABLE cli_orders; --" \
     >/dev/null 2>&1 && bad "injection accepted" || ok "injection rejected"
[[ "$(q "SELECT to_regclass('public.cli_orders') IS NOT NULL")" == "t" ]] \
  && ok "table still exists" || bad "table still exists"

printf '=== C11. schema-wide cover and uncover ===\n'
"$V" cover --schema public    >/dev/null 2>&1 && ok "cover --schema"    || bad "cover --schema"
"$V" uncover cli_orders      >/dev/null 2>&1 && ok "uncover"          || bad "uncover"

printf '=== C12. marks ===\n'
# C11 uncovered the table, so nothing after it would be captured.
try "re-cover for the marks test" "$V" cover cli_orders
try "mark"   "$V" mark cli-point --note 'from the cli test'
says "marks lists it" "cli-point" "$V" marks
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_orders SET total = 42" >/dev/null
[[ "$(q "SELECT changes_since FROM volvra.marks() WHERE name='cli-point'")" -ge 2 ]] \
  && ok "marks counts what undoing would touch" || bad "marks counts what undoing would touch"
try "undo --to" "$V" undo --yes --to cli-point
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 42")" == "0" ]] \
  && ok "undo --to reverted everything since the mark" \
  || bad "undo --to reverted everything since the mark"
try "unmark" "$V" unmark cli-point
"$V" mark >/dev/null 2>&1 && bad "mark with no name accepted" || ok "mark needs a name"

printf '=== C13. preflight and maintain ===\n'
# preflight exits 2 when it finds something critical -- here it will, because
# this database was installed by a superuser.
"$V" preflight >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "preflight exits 2 on a critical finding" \
               || bad "preflight exits 2 on a critical finding"
says "preflight names the superuser owner" "superuser" "$V" preflight
try "maintain" "$V" maintain
[[ "$(q "SELECT count(*) FROM volvra.change_log c
          WHERE c.id > coalesce((SELECT max(to_id) FROM volvra.seal),0)")" == "0" ]] \
  && ok "maintain left nothing unsealed" || bad "maintain left nothing unsealed"

printf '=== C14. seal, verify, forget ===\n'
try "seal"   "$V" seal
try "verify" "$V" verify
VER=$("$V" verify 2>&1)
[[ "$(printf '%s\n' "$VER" | grep -c 'TAMPERED')" == "0" ]] \
  && ok "verify reports no tampering" || bad "verify reports no tampering"

# forget must not apply without confirmation, exactly like undo
"$V" forget cli_orders '{"id":2}' </dev/null >/dev/null 2>&1 \
  && bad "forget applied without confirmation" \
  || ok "forget refuses without a confirmation"
[[ "$(q "SELECT count(*) FROM volvra.change_log
          WHERE table_name='public.cli_orders' AND pk @> '{\"id\":2}'
            AND new_row IS NOT NULL")" != "0" ]] \
  && ok "and nothing was erased" || bad "and nothing was erased"

try "forget --yes" "$V" forget cli_orders '{"id":2}' --yes --reason 'cli test'
[[ "$(q "SELECT count(*) FROM volvra.change_log
          WHERE table_name='public.cli_orders' AND pk @> '{\"id\":2}'
            AND (old_row IS NOT NULL OR new_row IS NOT NULL)")" == "0" ]] \
  && ok "the subject's row images are gone" || bad "the subject's row images are gone"
[[ "$(q "SELECT count(*) FROM volvra.erasure_log WHERE reason = 'cli test'")" == "1" ]] \
  && ok "and the erasure is recorded" || bad "and the erasure is recorded"

printf '=== C15. nothing to undo is not an error ===\n'
"$V" undo --yes --txid 999999999 >/dev/null 2>&1 \
  && ok "empty selection exits cleanly" || bad "empty selection exits cleanly"

printf '=== C15b. replay is the mirror of undo ===\n'
# A table of its own: C14 redacted rows of cli_orders, and redacted history
# cannot be replayed, so replaying anything touching it would fail for a
# reason unrelated to what this section tests.
psql -q -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS cli_replay;
CREATE TABLE cli_replay (id int PRIMARY KEY, total numeric);
SQL
"$V" cover cli_replay >/dev/null 2>&1
psql -q -v ON_ERROR_STOP=1 -c "INSERT INTO cli_replay VALUES (1,100),(2,250)" >/dev/null
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_replay SET total = 0" >/dev/null
# Read the txid back from the history rather than from psql's output: a
# heredoc's last line is the COMMIT status, not the value.
RTX=$(q "SELECT txid FROM volvra.change_log
          WHERE table_name = 'public.cli_replay' AND op = 'U'
          ORDER BY id DESC LIMIT 1")
[[ -n "$RTX" ]] && ok "captured the replay fixture txid $RTX" \
                || bad "captured the replay fixture txid"
# Undo it first, so the rows hold the image captured *before* the change and
# the replay guard can match.
"$V" undo --yes --txid "$RTX" >/dev/null 2>&1
[[ "$(q "SELECT total FROM cli_replay WHERE id = 1")" == "100" ]] \
  && ok "undo restored the row before the replay checks" \
  || bad "undo restored the row before the replay checks"

try "preview-replay" "$V" preview-replay --txid "$RTX"
[[ "$(q "SELECT total FROM cli_replay WHERE id = 1")" == "100" ]] \
  && ok "preview-replay changed nothing" || bad "preview-replay changed nothing"

try "replay --yes" "$V" replay --yes --txid "$RTX"
[[ "$(q "SELECT total FROM cli_replay WHERE id = 1")" == "0" ]] \
  && ok "replay reapplied the change" || bad "replay reapplied the change"

"$V" replay --yes --txid "$RTX" >/dev/null 2>&1 \
  && bad "a second replay was allowed" \
  || ok "a second replay of the same change is refused"
[[ "$(q "SELECT total FROM cli_replay WHERE id = 1")" == "0" ]] \
  && ok "and nothing was applied twice" || bad "and nothing was applied twice"

printf '=== C16. exit codes a scheduler can act on ===\n'
# 0 = worked, 1 = failed or declined, 2 = worked and the finding is bad.
"$V" status >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "status exits 0" || bad "status exits 0"

"$V" nonsense >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "an unknown command exits 1" || bad "an unknown command exits 1"

"$V" undo --txid "$BAD_TXID" </dev/null >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "a declined confirmation exits 1" \
               || bad "a declined confirmation exits 1"

# preflight exits 2 on a critical finding.  Whether this install has one
# depends on how it was installed, so both outcomes are legitimate -- what is
# asserted is that the code matches what was printed.
PF=$("$V" preflight 2>&1); PF_RC=$?
CRIT=$(q "SELECT count(*) FROM volvra.preflight() WHERE severity='critical'")
if [[ "${CRIT:-0}" -gt 0 ]]; then
  [[ $PF_RC -eq 2 ]] && ok "preflight exits 2 with $CRIT critical finding(s)" \
                     || bad "preflight exits 2 with $CRIT critical finding(s) (got $PF_RC)"
else
  [[ $PF_RC -eq 0 ]] && ok "preflight exits 0 with nothing critical" \
                     || bad "preflight exits 0 with nothing critical (got $PF_RC)"
fi

# verify exits 2 only when nothing lawful explains the mismatch.  Tampering has
# to go around the append-only guard, which is itself worth proving: the guard
# refusing the UPDATE is the stronger outcome, so it counts as a pass.
PART=$(q "SELECT tableoid::regclass::text FROM volvra.change_log ORDER BY id LIMIT 1")
if psql -q -v ON_ERROR_STOP=1 -c "UPDATE $PART SET actor = 'tampered'
      WHERE id = (SELECT min(id) FROM volvra.change_log)" >/dev/null 2>&1; then
  bad "the append-only guard let a sealed row be rewritten"
else
  ok "the append-only guard refuses to rewrite history"
fi

printf '=== C17. relative times, which the shell CLI never handled ===\n'
# '10 min ago' is not a timestamptz.  Postgres accepts 'today' and 'yesterday'
# as literals but not this, and the documented examples used it -- so every one
# of them failed until the CLI learned to read a trailing "ago" as an interval.
# A table of its own: C14 redacted rows of cli_orders, and a window-wide
# preview over redacted history fails for a reason that has nothing to do with
# how the time was written.
psql -q -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS cli_when;
CREATE TABLE cli_when (id int PRIMARY KEY, v int);
SQL
"$V" cover cli_when >/dev/null 2>&1
psql -q -v ON_ERROR_STOP=1 -c "INSERT INTO cli_when VALUES (1, 1)" >/dev/null
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_when SET v = 2" >/dev/null

for when in '10 min ago' '1 hour ago' 'today' 'yesterday'; do
  if out=$("$V" preview --table cli_when --since "$when" 2>&1); then
    ok "--since '$when'"
  else
    bad "--since '$when'"
    printf '%s\n' "$out" | head -2 | sed 's/^/       | /'
  fi
done

# And a bad time must be refused rather than silently selecting everything.
"$V" preview --table cli_when --since 'not a time' >/dev/null 2>&1 \
  && bad "an unparseable time was accepted" \
  || ok "an unparseable time is refused"

# --to and --since both set the start of the window, so both at once is a
# mistake worth naming rather than passing to Postgres twice.
"$V" preview --to somewhere --since today >/dev/null 2>&1 \
  && bad "--to with --since was accepted" \
  || ok "--to with --since is refused"

printf '=== C18. version ===\n'
says "version prints a version" "volvra" "$V" version

if [[ $FAILED -eq 0 ]]; then
  printf '\n*** ALL VOLVRA CLI CHECKS PASSED ***\n'
else
  printf '\n!!! VOLVRA CLI CHECKS FAILED !!!\n'
  exit 1
fi
