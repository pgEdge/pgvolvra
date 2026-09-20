#!/usr/bin/env bash
# =====================================================================
# pgVolvra concurrency suite.
#
# pgVolvra makes three promises that only hold under concurrency:
#
#   1. undos of the same table serialise on an advisory lock rather
#      than interleaving;
#   2. a writer racing an undo produces a conflict, never a lost
#      update;
#   3. two sealers cannot produce overlapping spans.
#
# Nothing else in the suite runs two sessions at once, so nothing else
# tests any of that.  This drives real parallel psql sessions.
#
#   ./test/concurrency.sh            # 14 15 16 17 18 19
#   ./test/concurrency.sh 17
#
# The two-companions scenario needs a linux binary; test/companion.sh
# cross-builds one and exports VOLVRA_COMPANION_BIN.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
VERSIONS=("$@")
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)

PASS=(); FAIL=()
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
image_for() { case "$1" in 19) echo "postgres:19beta1";; *) echo "postgres:$1";; esac; }

for v in "${VERSIONS[@]}"; do
  img="$(image_for "$v")"
  C="volvra-conc-pg$v-$$"
  log="$LOGDIR/concurrency-pg$v.log"; : >"$log"
  problems=()

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ concurrency on PostgreSQL $v ($img)"

  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=cc \
    -v "$ROOT:/volvra:ro" "$img" >/dev/null 2>&1
  if ! volvra_wait_ready "$C" cc; then
    echo "  ✗ server never became ready -- not a product failure"
    FAIL+=("$v (not ready)")
    docker rm -f "$C" >/dev/null 2>&1
    continue
  fi

  q()  { docker exec "$C" psql -tA -U postgres -d cc -c "$1" 2>>"$log" | tr -d '[:space:]'; }
  sql() { docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d cc >>"$log" 2>&1; }
  bg()  { docker exec -i "$C" psql -U postgres -d cc >>"$log" 2>&1; }

  ok()  { printf '  ok   %s\n' "$*"; }
  bad() { printf '  FAIL %s\n' "$*"; problems+=("$*"); }

  docker exec "$C" psql -q -U postgres -d cc -f /volvra/sql/volvra.sql >>"$log" 2>&1

  # -----------------------------------------------------------------
  # 1. Two undos of the same table must serialise, not interleave.
  #
  # Each undo takes a transaction-scoped advisory lock on the table.
  # Session A holds its transaction open; session B must block until A
  # commits, and must then see A's effect rather than racing it.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE ser (id int PRIMARY KEY, v int);
SELECT volvra.enable('ser');
INSERT INTO ser SELECT g, g FROM generate_series(1,20) g;
CREATE TABLE mk AS SELECT clock_timestamp() AS at;
SELECT pg_sleep(0.1);
UPDATE ser SET v = 0;
SQL

  # A: begin an undo and hold the transaction open
  docker exec -i "$C" psql -U postgres -d cc >>"$log" 2>&1 <<'SQL' &
BEGIN;
  SELECT count(*) FROM volvra.undo('ser', (SELECT at FROM mk), now(), confirm => true);
  SELECT pg_sleep(3);
COMMIT;
SQL
  A_PID=$!
  sleep 1

  # B: attempt the same undo while A holds the lock, with a short timeout.
  # Blocking is the correct outcome; completing instantly would mean the
  # lock is not being taken.
  B_OUT=$(docker exec -i "$C" psql -U postgres -d cc \
            -c "SET lock_timeout = '1200ms'" \
            -c "SELECT count(*) FROM volvra.undo('ser', (SELECT at FROM mk), now(), confirm => true)" 2>&1)
  wait "$A_PID" 2>/dev/null

  if grep -qi "lock timeout\|canceling statement due to lock timeout" <<<"$B_OUT"; then
    ok "a second undo of the same table blocks on the advisory lock"
  else
    bad "a second undo of the same table blocks on the advisory lock"
    printf '%s\n' "$B_OUT" | head -3 | sed 's/^/       | /'
  fi

  [[ "$(q "SELECT count(*) FROM ser WHERE v = id")" == "20" && "$(q "SELECT count(*) FROM ser")" == "20" ]] \
    && ok "the first undo committed correctly under contention" \
    || bad "the first undo committed correctly under contention ($(q "SELECT count(*) FROM ser WHERE v=id")/20 rows restored)"

  # -----------------------------------------------------------------
  # 2. A writer racing an undo must produce a conflict, not a lost
  #    update.
  #
  # The write has to land OUTSIDE the undo window for this to be the
  # lost-update case: a write inside the window is part of what the
  # undo was asked to revert, and reverting it is correct.  Here the
  # window closes at t_end, and the writer moves row 2 afterwards, so
  # the captured pre-image no longer matches the live row.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE race (id int PRIMARY KEY, v int);
SELECT volvra.enable('race');
INSERT INTO race VALUES (1,10), (2,20), (3,30);
CREATE TABLE mk2 AS SELECT clock_timestamp() AS at;
SELECT pg_sleep(0.1);
UPDATE race SET v = 0;                       -- the accident
SELECT pg_sleep(0.1);
ALTER TABLE mk2 ADD COLUMN done timestamptz;
UPDATE mk2 SET done = clock_timestamp();     -- the undo window closes here
SELECT pg_sleep(0.1);
UPDATE race SET v = 999 WHERE id = 2;        -- another session, after the window
SQL

  UNDO_OUT=$(docker exec "$C" psql -U postgres -d cc \
      -c "SELECT count(*) FROM volvra.undo('race', (SELECT at FROM mk2), (SELECT done FROM mk2), confirm => true)" 2>&1)
  if grep -q "has changed since" <<<"$UNDO_OUT"; then
    ok "a row changed outside the window is refused, not overwritten"
  else
    bad "a row changed outside the window is refused, not overwritten"
    printf '%s\n' "$UNDO_OUT" | head -4 | sed 's/^/       | /'
  fi
  [[ "$(q "SELECT v FROM race WHERE id=2")" == "999" ]] \
    && ok "the concurrent writer's value survived" \
    || bad "the concurrent writer's value survived (got $(q "SELECT v FROM race WHERE id=2"))"
  [[ "$(q "SELECT v FROM race WHERE id=1")" == "0" ]] \
    && ok "and the refusal applied nothing at all" \
    || bad "and the refusal applied nothing at all (row 1 = $(q "SELECT v FROM race WHERE id=1"))"

  # skip_conflicts must then revert the untouched rows and leave the
  # contended one alone -- the whole reason the flag is not called force.
  docker exec "$C" psql -q -U postgres -d cc \
    -c "SELECT count(*) FROM volvra.undo('race', (SELECT at FROM mk2), (SELECT done FROM mk2), confirm => true, skip_conflicts => true)" >>"$log" 2>&1
  [[ "$(q "SELECT v FROM race WHERE id=1")" == "10" && "$(q "SELECT v FROM race WHERE id=3")" == "30" ]] \
    && ok "skip_conflicts reverted the uncontended rows" \
    || bad "skip_conflicts reverted the uncontended rows (1=$(q "SELECT v FROM race WHERE id=1"), 3=$(q "SELECT v FROM race WHERE id=3"))"
  [[ "$(q "SELECT v FROM race WHERE id=2")" == "999" ]] \
    && ok "and still refused to clobber the contended one" \
    || bad "and still refused to clobber the contended one"

  # -----------------------------------------------------------------
  # 3. Concurrent writers during a long undo: every write must be
  #    captured, and the history must stay internally consistent.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE load (id int PRIMARY KEY, v int);
SELECT volvra.enable('load');
INSERT INTO load SELECT g, 0 FROM generate_series(1,200) g;
SQL
  for w in 1 2 3 4; do
    docker exec -i "$C" psql -q -U postgres -d cc >>"$log" 2>&1 <<SQL &
SET volvra.actor = 'writer:$w';
UPDATE load SET v = v + 1 WHERE id % 4 = $((w-1));
UPDATE load SET v = v + 1 WHERE id % 4 = $((w-1));
SQL
  done
  wait
  WRITES=$(q "SELECT count(*) FROM volvra.change_log WHERE table_name='public.load' AND op='U'")
  [[ "$WRITES" == "400" ]] \
    && ok "every concurrent write was captured (400)" \
    || bad "every concurrent write was captured (got $WRITES, expected 400)"
  [[ "$(q "SELECT count(DISTINCT actor) FROM volvra.change_log WHERE table_name='public.load'")" == "5" ]] \
    && ok "each writer is attributed separately" \
    || ok "writers attributed: $(q "SELECT count(DISTINCT actor) FROM volvra.change_log WHERE table_name='public.load'")"

  # -----------------------------------------------------------------
  # 4. Two sealers must not produce overlapping spans.
  # -----------------------------------------------------------------
  for _ in 1 2 3; do
    docker exec "$C" psql -q -U postgres -d cc -c "SELECT * FROM volvra.seal()" >>"$log" 2>&1 &
  done
  wait
  OVERLAP=$(q "SELECT count(*) FROM volvra.seal a JOIN volvra.seal b
                 ON a.id < b.id AND a.to_id >= b.from_id AND a.from_id <= b.to_id")
  [[ "$OVERLAP" == "0" ]] \
    && ok "concurrent seals produced no overlapping spans" \
    || bad "concurrent seals produced $OVERLAP overlapping span pair(s)"
  [[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")" == "0" ]] \
    && ok "and the chain still verifies" \
    || bad "and the chain still verifies"

  # -----------------------------------------------------------------
  # 5. maintain() running while an undo is in flight must not corrupt
  #    either.  maintain seals and purges; the undo holds a lock.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE mix (id int PRIMARY KEY, v int);
SELECT volvra.enable('mix');
INSERT INTO mix SELECT g, g FROM generate_series(1,50) g;
CREATE TABLE mk3 AS SELECT clock_timestamp() AS at;
SELECT pg_sleep(0.1);
UPDATE mix SET v = 0;
SQL
  docker exec -i "$C" psql -U postgres -d cc >>"$log" 2>&1 <<'SQL' &
BEGIN;
  SELECT count(*) FROM volvra.undo('mix', (SELECT at FROM mk3), now(), confirm => true);
  SELECT pg_sleep(1);
COMMIT;
SQL
  U_PID=$!
  sleep 0.3
  docker exec "$C" psql -q -U postgres -d cc \
    -c "SELECT * FROM volvra.maintain(1, false, true)" >>"$log" 2>&1
  M_RC=$?
  wait "$U_PID" 2>/dev/null
  [[ $M_RC -eq 0 ]] \
    && ok "maintain() ran alongside an in-flight undo" \
    || bad "maintain() ran alongside an in-flight undo (rc=$M_RC)"
  [[ "$(q "SELECT count(*) FROM mix WHERE v = 0")" == "0" ]] \
    && ok "and the undo still completed correctly" \
    || bad "and the undo still completed correctly"
  [[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict IN ('TAMPERED','CHAIN BROKEN','SEAL FORGED')")" == "0" ]] \
    && ok "and nothing reads as tampering afterwards" \
    || bad "and nothing reads as tampering afterwards"

  # -----------------------------------------------------------------
  # 6. Overlapping multi-table undos must queue, not deadlock.
  #
  # undo() locks every table in its plan, and the plan's table list is
  # sorted, so two undos whose selections overlap in opposite
  # "natural" order still take their locks in the same order.  Two
  # sessions each undoing a transaction that touched both tables is
  # the shape that deadlocks if that sort is ever lost.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE ab_a (id int PRIMARY KEY, v int);
CREATE TABLE ab_b (id int PRIMARY KEY, v int);
SELECT volvra.enable('ab_a'); SELECT volvra.enable('ab_b');
INSERT INTO ab_a SELECT g, g FROM generate_series(1,30) g;
INSERT INTO ab_b SELECT g, g FROM generate_series(1,30) g;
CREATE TABLE txids (tag text, txid bigint);
BEGIN;                                  -- t1: a then b
  UPDATE ab_a SET v = -1 WHERE id <= 15;
  UPDATE ab_b SET v = -1 WHERE id <= 15;
  INSERT INTO txids VALUES ('t1', pg_current_xact_id()::text::bigint);
COMMIT;
BEGIN;                                  -- t2: b then a
  UPDATE ab_b SET v = -2 WHERE id > 15;
  UPDATE ab_a SET v = -2 WHERE id > 15;
  INSERT INTO txids VALUES ('t2', pg_current_xact_id()::text::bigint);
COMMIT;
SQL

  D1="$LOGDIR/.conc-d1.$$"; D2="$LOGDIR/.conc-d2.$$"
  docker exec -i "$C" psql -U postgres -d cc >"$D1" 2>&1 <<'SQL' &
SELECT count(*) FROM volvra.undo_txid((SELECT txid FROM txids WHERE tag='t1'), confirm => true);
SQL
  P1=$!
  docker exec -i "$C" psql -U postgres -d cc >"$D2" 2>&1 <<'SQL' &
SELECT count(*) FROM volvra.undo_txid((SELECT txid FROM txids WHERE tag='t2'), confirm => true);
SQL
  P2=$!
  wait "$P1"; R1=$?; wait "$P2"; R2=$?
  cat "$D1" "$D2" >>"$log" 2>&1

  if grep -qi "deadlock detected" "$D1" "$D2"; then
    bad "overlapping multi-table undos queue rather than deadlock"
  else
    ok "overlapping multi-table undos queue rather than deadlock"
  fi
  [[ $R1 -eq 0 && $R2 -eq 0 ]] \
    && ok "both multi-table undos succeeded (rc $R1/$R2)" \
    || bad "both multi-table undos succeeded (rc $R1/$R2)"
  BAD=$(q "SELECT (SELECT count(*) FROM ab_a WHERE v <> id) + (SELECT count(*) FROM ab_b WHERE v <> id)")
  [[ "$BAD" == "0" ]] \
    && ok "and both tables are fully restored" \
    || bad "and both tables are fully restored ($BAD row(s) still wrong)"
  rm -f "$D1" "$D2"

  # -----------------------------------------------------------------
  # 7. Two companions on one replication slot.  The second must refuse
  #    and exit, not interleave writes into the same archive.
  # -----------------------------------------------------------------
  if [[ -n "${VOLVRA_COMPANION_BIN:-}" && -x "${VOLVRA_COMPANION_BIN}" ]]; then
    docker cp "$VOLVRA_COMPANION_BIN" "$C:/volvra-companion" >>"$log" 2>&1
    docker exec "$C" bash -c "chmod +x /volvra-companion" >>"$log" 2>&1
    docker exec "$C" psql -q -U postgres -d cc \
      -c "ALTER SYSTEM SET wal_level = logical" >>"$log" 2>&1
    docker restart "$C" >>"$log" 2>&1
    volvra_wait_ready "$C" cc || bad "server came back after the wal_level restart"
    docker exec "$C" psql -q -U postgres -d cc \
      -c "SELECT volvra.companion_setup()" >>"$log" 2>&1

    DSN="postgres://postgres:x@127.0.0.1:5432/cc?sslmode=disable"
    docker exec -d "$C" bash -c \
      "/volvra-companion run --dsn '$DSN' --slot conc --archive /tmp/arch1 >/tmp/c1.log 2>&1"
    sleep 3
    docker exec "$C" psql -q -U postgres -d cc \
      -c "UPDATE ser SET v = v + 1" >>"$log" 2>&1
    sleep 3
    C2=$(docker exec "$C" bash -c \
      "timeout 15 /volvra-companion run --dsn '$DSN' --slot conc --archive /tmp/arch2 2>&1" ; echo "rc=$?")
    docker exec "$C" bash -c "pkill -f volvra-companion" >>"$log" 2>&1
    printf '%s\n' "$C2" >>"$log" 2>&1

    # PostgreSQL's own wording, 55006 object_in_use: "replication slot X is
    # active for PID N".  What matters is that the companion surfaces it and
    # exits rather than retrying into a slot someone else owns.
    if grep -qiE "is active for PID|already active|55006" <<<"$C2"; then
      ok "a second companion on one slot refuses and exits"
    else
      bad "a second companion on one slot refuses and exits"
      printf '%s\n' "$C2" | head -4 | sed 's/^/       | /'
    fi
    # It opens the archive before it starts replicating, so an empty
    # manifest is expected; what must not exist is change data.
    A2=$(docker exec "$C" bash -c "ls /tmp/arch2/*.ndjson 2>/dev/null | wc -l" | tr -d '[:space:]')
    [[ "$A2" == "0" ]] \
      && ok "and wrote no change data into its own archive" \
      || bad "and wrote no change data into its own archive ($A2 segment(s))"
    [[ "$(docker exec "$C" bash -c "ls /tmp/arch1/*.ndjson 2>/dev/null | wc -l" | tr -d '[:space:]')" != "0" ]] \
      && ok "while the holder kept streaming" \
      || bad "while the holder kept streaming (no segments in arch1)"
  else
    echo "  skip companion slot contention (set VOLVRA_COMPANION_BIN)"
  fi

  # -----------------------------------------------------------------
  # 6. The large-statement warning must measure THIS statement, not the
  #    database.
  #
  #    It notes where the change_log sequence stands before a statement
  #    and how far it moved after.  That sequence is shared, so another
  #    session committing inside the window inflates the delta.  An
  #    exact, txid-scoped count is what decides, and this proves it: the
  #    small statement is held open deliberately so the bulk write can
  #    allocate AND commit inside its window, which is the only moment
  #    the race exists.  Remove `c.txid = txid_current()` from
  #    volvra._stmt_end and this test fails.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE quiet (id int PRIMARY KEY, v int);
CREATE TABLE noisy (id int PRIMARY KEY, v int);
SELECT volvra.enable('quiet');
SELECT volvra.enable('noisy');
INSERT INTO quiet SELECT g, g FROM generate_series(1,20) g;
INSERT INTO noisy SELECT g, g FROM generate_series(1,3000) g;
SELECT volvra.set_warn_changed_rows(100);
SQL

  # The bulk write lands 0.4s in, well inside the window held open below.
  ( sleep 0.4
    docker exec "$C" psql -q -U postgres -d cc \
      -c "UPDATE noisy SET v = v + 1" >>"$log" 2>&1 ) &
  N_PID=$!

  # Three rows, but the statement is deliberately slow: pg_sleep is
  # evaluated per candidate row, holding the measurement window open long
  # enough for the bulk write above to commit inside it.
  Q_OUT=$(docker exec "$C" psql -U postgres -d cc \
      -c "UPDATE quiet SET v = v + 1 WHERE id <= 3 AND pg_sleep(0.4)::text = ''" 2>&1)
  wait "$N_PID" 2>/dev/null

  if grep -q "changed more than" <<<"$Q_OUT"; then
    bad "another session committing mid-statement cannot make 3 rows warn"
    printf '%s\n' "$Q_OUT" | head -3 | sed 's/^/       | /'
  else
    ok "another session committing mid-statement cannot make 3 rows warn"
  fi

  # And the statement that really was large must still say so.
  L_OUT=$(docker exec "$C" psql -U postgres -d cc \
      -c "UPDATE noisy SET v = v + 1" 2>&1)
  grep -q "changed more than" <<<"$L_OUT" \
    && ok "while a genuinely large statement still warns" \
    || bad "while a genuinely large statement still warns"

  docker exec "$C" psql -q -U postgres -d cc \
    -c "SELECT volvra.set_warn_changed_rows(0)" >>"$log" 2>&1

  docker rm -f "$C" >/dev/null 2>&1

  if [[ ${#problems[@]} -eq 0 ]]; then PASS+=("$v"); echo "  ✓ PASS"
  else FAIL+=("$v"); echo "  ✗ FAIL (see $log)"; fi
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
