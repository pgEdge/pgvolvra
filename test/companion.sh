#!/usr/bin/env bash
# =====================================================================
# pgVolvra phase 5 -- the durable tier, end to end.
#
# The claim being tested is the one the trigger tier cannot make: that the
# history survives the database.  So the decisive test is not "does it
# archive" but "can an undo be driven from the archive alone, after the
# in-database history is gone".
#
# The companion runs on the host against a published port, which is how it
# would really be deployed: outside the database.
#
#   ./test/companion.sh [pg-version] [host-port]
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
VER="${1:-17}"
PORT="${2:-55432}"
IMG="postgres:$VER"; [[ "$VER" == "19" ]] && IMG="postgres:19beta1"
C="volvra-companion-$$"
WORK="$(mktemp -d)"
BIN="$WORK/volvra-companion"
ARCHIVE="$WORK/archive"
FAILED=0

ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILED=1; }

cleanup() {
  [[ -n "${COMPANION_PID:-}" ]] && kill "$COMPANION_PID" 2>/dev/null
  docker rm -f "$C" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

DSN="postgres://postgres:c@127.0.0.1:$PORT/app"
q()  { docker exec -i "$C" psql -tA -v ON_ERROR_STOP=1 -U postgres -d app "$@"; }
qq() { docker exec -i "$C" psql -q -v ON_ERROR_STOP=1 -U postgres -d app "$@"; }

printf '=== D0. a server with wal_level=logical ===\n'
docker run -d --name "$C" -e POSTGRES_PASSWORD=c -e POSTGRES_DB=app \
  -p "$PORT:5432" -v "$ROOT:/volvra:ro" "$IMG" \
  -c wal_level=logical -c max_replication_slots=4 -c max_wal_senders=4 >/dev/null
volvra_wait_ready "$C" app || { echo "server never became ready -- not a product failure" >&2; exit 2; }
[[ "$(q -c 'SHOW wal_level')" == "logical" ]] && ok "wal_level=logical" || bad "wal_level=logical"

qq -f /volvra/sql/volvra.sql >/dev/null 2>&1
qq <<'SQL'
CREATE TABLE accounts (id int PRIMARY KEY, owner text NOT NULL, balance numeric NOT NULL);
SELECT volvra.enable('accounts');
INSERT INTO accounts VALUES (1,'ada',100), (2,'grace',200), (3,'hopper',300);
SQL

printf '=== D1. companion_setup prepares the database ===\n'
SETUP="$(q -c "SELECT step || '|' || object || '|' || coalesce(detail,'') FROM volvra.companion_setup('public')")"
printf '%s\n' "$SETUP" | sed 's/^/       /'
[[ "$SETUP" == *"replica identity|public.accounts|set to FULL"* ]] \
  && ok "REPLICA IDENTITY FULL set on the covered table" \
  || bad "REPLICA IDENTITY FULL set on the covered table"
[[ "$(q -c "SELECT count(*) FROM pg_publication_tables WHERE pubname='volvra_pub'")" == "1" ]] \
  && ok "publication created for covered tables" || bad "publication created"

printf '=== D2. build the companion ===\n'
( cd "$ROOT/companion" && go build -o "$BIN" . ) && ok "built" || { bad "built"; exit 1; }

printf '=== D3. archive live changes ===\n'
"$BIN" run --dsn "$DSN" --archive "$ARCHIVE" --segment-bytes 4096 \
  >"$WORK/run.log" 2>&1 &
COMPANION_PID=$!
for _ in $(seq 1 40); do
  [[ -f "$ARCHIVE/manifest.json" ]] && break; sleep 0.5
done
[[ -f "$ARCHIVE/manifest.json" ]] && ok "archive opened" || bad "archive opened"

# The manifest exists before the slot does, and a write issued in that window
# never reaches the stream. Wait for the slot, which is the real signal.
for _ in $(seq 1 60); do
  [[ "$(q -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name='volvra_companion' AND active")" == "1" ]] && break
  sleep 0.5
done

qq <<'SQL'
UPDATE accounts SET balance = 0;
DELETE FROM accounts WHERE id = 3;
INSERT INTO accounts VALUES (4,'lovelace',400);
SQL

# wait for the companion to report the changes as durable
for _ in $(seq 1 60); do
  N="$(q -c "SELECT coalesce(changes,0) FROM volvra.companion_checkpoint LIMIT 1" 2>/dev/null)"
  [[ "${N:-0}" -ge 5 ]] && break; sleep 1
done
[[ "${N:-0}" -ge 5 ]] && ok "companion archived and reported $N change(s)" \
                      || bad "companion archived changes (got ${N:-0})"

q -c "SELECT item || ' = ' || value || ' [' || status || ']' FROM volvra.companion_status()" \
  | sed 's/^/       /'

printf '=== D4. stop cleanly, then verify the archive ===\n'
kill -TERM "$COMPANION_PID" 2>/dev/null; wait "$COMPANION_PID" 2>/dev/null
unset COMPANION_PID
"$BIN" verify --archive "$ARCHIVE" >"$WORK/verify.log" 2>&1 \
  && ok "verify: archive intact" || { bad "verify: archive intact"; sed 's/^/       /' "$WORK/verify.log"; }
sed -n '1,5p' "$WORK/verify.log" | sed 's/^/       /'

printf '=== D5. the archive is readable without volvra and without Postgres ===\n'
SEG="$(ls "$ARCHIVE"/*.ndjson | head -1)"
python3 - "$SEG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ops={}
for r in rows: ops[r.get('op','gap')] = ops.get(r.get('op','gap'),0)+1
print("       plain JSON, %d record(s): %s" % (len(rows), ops))
u=[r for r in rows if r.get('op')=='U']
assert u, "no update archived"
assert u[0]['old'] and u[0]['new'], "an update must carry both images"
assert u[0]['old']['balance'] != u[0]['new']['balance'], "before image must differ"
print("       before/after images present: %s -> %s" % (u[0]['old']['balance'], u[0]['new']['balance']))
PY
[[ $? -eq 0 ]] && ok "readable as plain JSON with before and after images" \
               || bad "readable as plain JSON with before and after images"

printf '=== D6. tampering with a segment is detected, and blocks a restore ===\n'
cp "$SEG" "$WORK/seg.bak"
printf '{"lsn":"0/0","op":"U","table":"public.accounts","pk":{"id":1}}\n' >> "$SEG"
"$BIN" verify --archive "$ARCHIVE" >"$WORK/tamper.log" 2>&1 \
  && bad "verify must fail on a tampered segment" || ok "verify fails on a tampered segment"
grep -qE "TAMPERED|TRUNCATED" "$WORK/tamper.log" && ok "and names it" \
  || { bad "and names it"; sed 's/^/       /' "$WORK/tamper.log"; }
"$BIN" restore --archive "$ARCHIVE" --dsn "$DSN" >/dev/null 2>&1 \
  && bad "restore must refuse a tampered archive" || ok "restore refuses a tampered archive"
cp "$WORK/seg.bak" "$SEG"
"$BIN" verify --archive "$ARCHIVE" >/dev/null 2>&1 \
  && ok "restoring the segment restores the verdict" || bad "restoring the segment restores the verdict"

printf '=== D7. THE CLAIM: undo from the archive after the database history is gone ===\n'
# Destroy the in-database history entirely -- as losing the database would.
qq -c "SELECT sum(rows_removed) FROM volvra.purge('0 seconds'::interval)" >/dev/null
[[ "$(q -c "SELECT count(*) FROM volvra.change_log")" == "0" ]] \
  && ok "in-database history destroyed" || bad "in-database history destroyed"

# The rows are still wrong: balances zeroed, hopper deleted, lovelace inserted.
# three rows were zeroed, then id 3 was deleted, so two remain at zero
[[ "$(q -c "SELECT count(*) FROM accounts WHERE balance = 0")" == "2" ]] \
  && ok "the damage is still there" || bad "the damage is still there"

"$BIN" restore --archive "$ARCHIVE" --dsn "$DSN" >"$WORK/restore.log" 2>&1 \
  && ok "restored the archive into volvra.change_log" \
  || { bad "restored the archive"; sed 's/^/       /' "$WORK/restore.log"; }
sed -n '1,3p' "$WORK/restore.log" | sed 's/^/       /'

RESTORED="$(q -c "SELECT count(*) FROM volvra.change_log")"
[[ "${RESTORED:-0}" -ge 5 ]] && ok "history rebuilt from the archive ($RESTORED rows)" \
                             || bad "history rebuilt from the archive (got ${RESTORED:-0})"

# And now the ordinary undo path -- conflict guard, cap and all -- drives it.
qq <<'SQL'
SELECT count(*) FROM volvra.undo('accounts',
  (SELECT min(ts) - interval '1 second' FROM volvra.change_log),
  now(), confirm => true);
SQL
[[ "$(q -c "SELECT balance FROM accounts WHERE id=1")" == "100" ]] \
  && ok "balance restored from archived history" || bad "balance restored"
[[ "$(q -c "SELECT count(*) FROM accounts WHERE id=3")" == "1" ]] \
  && ok "deleted row resurrected from archived history" || bad "deleted row resurrected"
[[ "$(q -c "SELECT count(*) FROM accounts WHERE id=4")" == "0" ]] \
  && ok "wrongly inserted row removed" || bad "wrongly inserted row removed"

printf '=== D8. the slot-lag safety valve records a gap rather than filling the disk ===\n'
rm -rf "$WORK/a2"
"$BIN" run --dsn "$DSN" --archive "$WORK/a2" --slot volvra_valve \
  --lag-max 1 --lag-warn 1 >"$WORK/valve.log" 2>&1 &
VALVE_PID=$!
for _ in $(seq 1 40); do
  grep -q "SAFETY VALVE" "$WORK/valve.log" && break; sleep 0.5
done
kill -TERM "$VALVE_PID" 2>/dev/null; wait "$VALVE_PID" 2>/dev/null
grep -q "SAFETY VALVE" "$WORK/valve.log" && ok "valve fired at the ceiling" \
  || { bad "valve fired at the ceiling"; tail -5 "$WORK/valve.log" | sed 's/^/       /'; }
[[ "$(q -c "SELECT count(*) FROM volvra.companion_gap WHERE slot_name='volvra_valve'")" -ge 1 ]] \
  && ok "and recorded the gap in the database" || bad "and recorded the gap in the database"
grep -q '"gap":true' "$WORK"/a2/*.ndjson 2>/dev/null \
  && ok "and in the archive itself" || bad "and in the archive itself"
qq -c "SELECT pg_drop_replication_slot('volvra_valve')" >/dev/null 2>&1

if [[ $FAILED -eq 0 ]]; then
  printf '\n*** ALL VOLVRA COMPANION CHECKS PASSED ***\n'
else
  printf '\n!!! VOLVRA COMPANION CHECKS FAILED !!!\n'
  exit 1
fi
