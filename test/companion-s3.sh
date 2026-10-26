#!/usr/bin/env bash
# =====================================================================
# pgVolvra -- the durable tier against object storage.
#
# The claim being tested is the one that matters after the host is gone:
# that the archive in the bucket is complete, verified, and enough on its
# own to drive a restore.  So the decisive assertion is not "did it
# upload" but "with the local directory deleted, does the archive still
# verify and still restore".
#
# It also tests the thing that makes the feature safe rather than merely
# convenient: the replication slot must NOT advance past a segment the
# bucket has not confirmed.  Advancing it would mean losing the host
# loses both the segment and the WAL that could have replaced it, which
# is the exact failure this tier exists to prevent.
#
# S3 server: SeaweedFS, which speaks the S3 API, enforces signed
# requests and returns a server-side SHA-256 so the upload verification
# path is exercised for real.  MinIO would have been the obvious choice
# and is no longer pullable from Docker Hub or quay.io.
#
# Pass --s3mock to run against adobe/s3mock instead.  It returns no
# server checksum, which is how the re-GET fallback in Remote.confirm
# gets covered; both paths are real and both ship.
#
#   ./test/companion-s3.sh [pg-version] [host-port] [--s3mock]
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

S3MOCK=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --s3mock) S3MOCK=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
VER="${ARGS[0]:-17}"
PORT="${ARGS[1]:-55433}"
IMG="postgres:$VER"; [[ "$VER" == "19" ]] && IMG="postgres:19beta1"

C="volvra-s3-pg-$$"
S3C="volvra-s3-store-$$"
S3PORT=$((PORT + 1000))
WORK="$(mktemp -d)"
BIN="$WORK/volvra-companion"
ARCHIVE="$WORK/archive"
BUCKET="volvra"
AK="volvratestkey"
SK="volvratestsecret"
FAILED=0

ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILED=1; }

cleanup() {
  [[ -n "${COMPANION_PID:-}" ]] && kill -KILL "$COMPANION_PID" 2>/dev/null
  docker rm -f "$C" "$S3C" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

DSN="postgres://postgres:c@127.0.0.1:$PORT/app"
q()  { docker exec -i "$C" psql -tA -v ON_ERROR_STOP=1 -U postgres -d app "$@"; }
qq() { docker exec -i "$C" psql -q -v ON_ERROR_STOP=1 -U postgres -d app "$@"; }

# Credentials reach the companion the way they would in production: through
# the environment, never a flag.  A flag would put them in the process list
# and in shell history.
cm() { env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" "$BIN" "$@"; }

# Background runs must NOT go through the function.  Backgrounding a shell
# function forks a subshell, so $! is the subshell and a TERM sent to it leaves
# the companion running: it goes on holding the replication slot and rewriting
# the manifest underneath whatever the test does next.  That cost an afternoon.
# Running env directly makes $! the process that becomes the companion.
cmbg() { env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" "$BIN" "$@"; }

# Run the companion until its log matches a pattern, then stop it.
#
# An upload failure used to be fatal at startup, so these checks could just run
# the companion in the foreground and wait for it to die. It now reports and
# retries, which is the point of the change, so waiting for an exit hangs
# forever. Wait for the message instead.
run_until() {
  local pattern="$1" logfile="$2" secs="$3" slot="$4"; shift 4
  cmbg "$@" >"$logfile" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 $((secs * 2))); do
    grep -qiE "$pattern" "$logfile" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  stop_companion "$pid" "$slot"
}

# Stop a companion and wait until it has really gone, slot included.
stop_companion() {
  local pid="$1" slot="${2:-volvra_companion}"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # The slot stays active for a moment after the walsender exits, and a run
  # started inside that window dies with "slot is active for PID n".
  for _ in $(seq 1 40); do
    [[ "$(q -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name='$slot' AND active")" == "0" ]] && break
    sleep 0.5
  done
}

S3FLAGS=(--s3-bucket "$BUCKET" --s3-endpoint "127.0.0.1:$S3PORT" --s3-insecure)

printf '=== S0. an S3-compatible store ===\n'
if [[ $S3MOCK -eq 1 ]]; then
  docker run -d --name "$S3C" -p "$S3PORT:9090" --memory 512m \
    -e JAVA_OPTS="-Xmx256m" adobe/s3mock:latest >/dev/null 2>&1
  STORE="adobe/s3mock (no server checksum: exercises the re-GET fallback)"
else
  # The identity has to exist before SeaweedFS will accept a signed request.
  # It is written inside the container rather than mounted, because the
  # scratch directory is not a Docker Desktop shared path.
  # Memory-capped deliberately. "weed server" starts a master, a volume
  # server, a filer, the S3 gateway and the Iceberg and Lance catalog servers,
  # and a full run of this suite exhausted the host's memory twice before the
  # cap was added. Do NOT also cap -volume.max: one volume is not enough for
  # the second bucket S14 needs, and the failure surfaces as an opaque
  # "internal error" on upload rather than anything that names the cause.
  docker run -d --name "$S3C" -p "$S3PORT:8333" --memory 768m --entrypoint sh \
    chrislusf/seaweedfs:latest -c "
printf '%s' '{\"identities\":[{\"name\":\"volvra\",\"credentials\":[{\"accessKey\":\"$AK\",\"secretKey\":\"$SK\"}],\"actions\":[\"Admin\",\"Read\",\"Write\",\"List\",\"Tagging\"]}]}' > /tmp/s3.json
mkdir -p /tmp/data
exec weed server -s3 -s3.port=8333 -s3.config=/tmp/s3.json -dir=/tmp/data \
  -master.volumeSizeLimitMB=128 -volume.preStopSeconds=0" >/dev/null 2>&1
  STORE="SeaweedFS (server-side SHA-256)"
fi

for _ in $(seq 1 90); do
  curl -s -m 2 "http://127.0.0.1:$S3PORT/" >/dev/null 2>&1 && break
  sleep 1
done
sleep 4
if curl -s -m 5 "http://127.0.0.1:$S3PORT/" >/dev/null 2>&1; then
  ok "object store up: $STORE"
else
  echo "  S3 store never became ready -- not a product failure" >&2
  exit 2
fi

printf '=== S1. a server with wal_level=logical ===\n'
docker run -d --name "$C" -e POSTGRES_PASSWORD=c -e POSTGRES_DB=app \
  -p "$PORT:5432" -v "$ROOT:/volvra:ro" "$IMG" \
  -c wal_level=logical -c max_replication_slots=4 -c max_wal_senders=4 >/dev/null
volvra_wait_ready "$C" app || { echo "server never became ready -- not a product failure" >&2; exit 2; }
ok "postgres $VER up"

qq -f /volvra/sql/volvra.sql >/dev/null 2>&1
qq <<'SQL'
CREATE TABLE accounts (id int PRIMARY KEY, owner text NOT NULL, balance numeric NOT NULL);
SELECT volvra.enable('accounts');
INSERT INTO accounts VALUES (1,'ada',100), (2,'grace',200), (3,'hopper',300);
SELECT volvra.companion_setup('public');
SQL
ok "database prepared"

printf '=== S2. build the companion ===\n'
( cd "$ROOT/companion" && go build -o "$BIN" . ) && ok "built" || { bad "built"; exit 1; }
( cd "$ROOT/companion" && go test ./... >/dev/null 2>&1 ) \
  && ok "go unit tests pass" || bad "go unit tests"

printf '=== S3. the bucket must exist before the companion will start ===\n'
cm run --dsn "$DSN" --archive "$ARCHIVE" "${S3FLAGS[@]}" >"$WORK/nobucket.log" 2>&1
if grep -qi "does not exist\|cannot reach bucket" "$WORK/nobucket.log"; then
  ok "refuses a missing bucket at startup, not at the first rotation"
else
  bad "refuses a missing bucket at startup"
  sed 's/^/       /' "$WORK/nobucket.log" | head -5
fi

python3 - "$S3PORT" "$BUCKET" "$AK" "$SK" <<'PY'
import sys, urllib.request, hashlib, hmac, datetime
# Create the bucket with a plain signed PUT, so the suite does not depend on
# any S3 client being installed on the host.
port, bucket, ak, sk = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
host = f"127.0.0.1:{port}"
t = datetime.datetime.now(datetime.timezone.utc)
amzdate = t.strftime('%Y%m%dT%H%M%SZ'); datestamp = t.strftime('%Y%m%d')
region, service = 'us-east-1', 's3'
payload_hash = hashlib.sha256(b'').hexdigest()
canonical = (f"PUT\n/{bucket}\n\nhost:{host}\nx-amz-content-sha256:{payload_hash}\n"
             f"x-amz-date:{amzdate}\n\nhost;x-amz-content-sha256;x-amz-date\n{payload_hash}")
scope = f"{datestamp}/{region}/{service}/aws4_request"
sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
k = sign(sign(sign(sign(('AWS4'+sk).encode(), datestamp), region), service), 'aws4_request')
sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
auth = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
        f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}")
req = urllib.request.Request(f"http://{host}/{bucket}", method='PUT',
                             headers={'Authorization': auth, 'x-amz-date': amzdate,
                                      'x-amz-content-sha256': payload_hash})
try:
    urllib.request.urlopen(req, timeout=10)
    print("       bucket created")
except Exception as e:
    print("       bucket create:", e)
PY

printf '=== S4. archive live changes to the bucket ===\n'
cmbg run --dsn "$DSN" --archive "$ARCHIVE" "${S3FLAGS[@]}" --segment-bytes 2048 \
  >"$WORK/run.log" 2>&1 &
COMPANION_PID=$!
for _ in $(seq 1 40); do [[ -f "$ARCHIVE/manifest.json" ]] && break; sleep 0.5; done
[[ -f "$ARCHIVE/manifest.json" ]] && ok "archive opened" || bad "archive opened"

# Wait for the slot, not for the manifest. OpenArchive writes manifest.json
# before the streamer creates the slot, so a write issued between the two is
# never in the slot's stream and is lost to the archive for good. Waiting on
# the file instead of the slot is what made this suite report zero segments
# while the trigger tier happily recorded every row.
for _ in $(seq 1 60); do
  [[ "$(q -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name='volvra_companion' AND active")" == "1" ]] && break
  sleep 0.5
done
[[ "$(q -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name='volvra_companion' AND active")" == "1" ]] \
  && ok "slot active, writes from here are in the stream" || bad "slot never became active"

qq <<'SQL'
UPDATE accounts SET balance = 0;
DELETE FROM accounts WHERE id = 3;
INSERT INTO accounts VALUES (4,'lovelace',400);
INSERT INTO accounts SELECT g, 'bulk'||g, g*10 FROM generate_series(100,160) g;
UPDATE accounts SET owner = owner || '!' WHERE id >= 100;
SQL

for _ in $(seq 1 90); do
  UP="$(python3 - "$ARCHIVE/manifest.json" <<'PY'
import json,sys
try: m=json.load(open(sys.argv[1]))
except Exception: print(0); raise SystemExit
print(sum(1 for s in (m.get('segments') or []) if s.get('uploaded_at')))
PY
)"
  [[ "${UP:-0}" -ge 1 ]] && break; sleep 1
done
if [[ "${UP:-0}" -ge 1 ]]; then
  ok "$UP segment(s) uploaded and recorded in the manifest"
else
  bad "segments uploaded (got ${UP:-0})"
  echo "       --- segments on disk: $(ls "$ARCHIVE"/*.ndjson 2>/dev/null | wc -l | tr -d ' ') ---"
  echo "       --- manifest ---"
  python3 -c "
import json,sys
m=json.load(open('$ARCHIVE/manifest.json'))
segs=m.get('segments') or []
print('       recorded segments:', len(segs))
for x in segs[:3]: print('        seq',x['seq'],'uploaded_at=',repr(x.get('uploaded_at')))
" 2>&1 | head -8
  echo "       --- change_log rows: $(q -c 'SELECT count(*) FROM volvra.change_log') ---"
  echo "       --- companion log ---"
  sed 's/^/       /' "$WORK/run.log" | tail -12
fi

printf '=== S5. the manifest records a verified upload, not just an attempt ===\n'
python3 - "$ARCHIVE/manifest.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
up=[s for s in (m.get('segments') or []) if s.get('uploaded_at')]
assert up, "no uploaded segment"
s=up[0]
assert s.get('remote_key')==s['file'], "remote_key must name the object"
assert s.get('sha256'), "the sealed hash is what the upload was checked against"
print("       segment %d: sha256=%s uploaded_at=%s" % (s['seq'], s['sha256'][:16], s['uploaded_at']))
PY
[[ $? -eq 0 ]] && ok "upload state is recorded per segment" || bad "upload state is recorded"

if [[ $S3MOCK -eq 1 ]]; then
  printf '=== S6/S7. outage and recovery -- SKIPPED on s3mock ===\n'
  # adobe/s3mock keeps objects in memory, so stopping the container destroys
  # the bucket rather than making it briefly unreachable. That is not an
  # outage, it is data loss, and every later assertion would fail for a
  # reason that has nothing to do with the companion. The outage path is
  # covered by the SeaweedFS run, which persists.
  echo "       (in-memory store: stopping it wipes the bucket, which is not an outage)"
else
printf '=== S6. the slot does not advance past an un-uploaded segment ===\n'
# Stop the store.  New segments keep being written locally and keep being
# recorded, but nothing more may be acknowledged to Postgres.
docker stop "$S3C" >/dev/null 2>&1
qq <<'SQL'
INSERT INTO accounts SELECT g, 'after'||g, g FROM generate_series(200,400) g;
UPDATE accounts SET balance = balance + 1 WHERE id >= 200;
SQL
sleep 16   # several status ticks, so the slot has every chance to advance

read -r PEND LAST_UP <<<"$(python3 - "$ARCHIVE/manifest.json" <<'MANI'
import json,sys
segs = json.load(open(sys.argv[1])).get('segments') or []
pend = [s for s in segs if not s.get('uploaded_at')]
up   = [s for s in segs if s.get('uploaded_at')]
print(len(pend), up[-1]['end_lsn'] if up else '0/0')
MANI
)"
if [[ "${PEND:-0}" -ge 1 ]]; then
  ok "$PEND segment(s) pending upload while the store is down"
else
  bad "the store being down should leave segments pending (got ${PEND:-0})"
fi

# The invariant is not "the slot stands still" -- it is free to catch up to
# segments that did upload, and asserting otherwise fails on legitimate
# catch-up. It is "the slot never passes the last segment the bucket
# confirmed", because WAL released beyond that point cannot be recovered if
# this host dies, which is the whole reason the feature exists.
ACK="$(q -c "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='volvra_companion'")"
HELD="$(q -c "SELECT confirmed_flush_lsn <= '${LAST_UP}'::pg_lsn FROM pg_replication_slots WHERE slot_name='volvra_companion'")"
if [[ "$HELD" == "t" ]]; then
  ok "slot at $ACK, not past the last uploaded segment ($LAST_UP)"
else
  bad "slot at $ACK is beyond the last uploaded segment ($LAST_UP): WAL released for data held only on local disk"
fi
# Poll rather than sample: the message is written on a status tick, so a
# fixed sleep races the five-second loop.
for _ in $(seq 1 20); do
  grep -q "still to upload" "$WORK/run.log" && break
  sleep 1
done
grep -q "still to upload" "$WORK/run.log" && ok "and the companion said so" \
  || { bad "the companion should log that uploads are outstanding"; \
       sed 's/^/       /' "$WORK/run.log" | tail -5; }

printf '=== S7. the backlog clears when the store returns ===\n'
docker start "$S3C" >/dev/null 2>&1
for _ in $(seq 1 60); do curl -s -m 2 "http://127.0.0.1:$S3PORT/" >/dev/null 2>&1 && break; sleep 1; done
sleep 4
for _ in $(seq 1 90); do
  PEND="$(python3 - "$ARCHIVE/manifest.json" <<'PY'
import json,sys
try: m=json.load(open(sys.argv[1]))
except Exception: print(99); raise SystemExit
print(sum(1 for s in (m.get('segments') or []) if not s.get('uploaded_at')))
PY
)"
  [[ "${PEND:-99}" -eq 0 ]] && break; sleep 2
done
[[ "${PEND:-99}" -eq 0 ]] && ok "every segment uploaded once the store came back" \
                          || bad "backlog cleared (still ${PEND:-?} pending)"
# Poll: the slot moves on the next status tick, not at the instant the last
# upload lands, so sampling once races the five-second loop.
for _ in $(seq 1 30); do
  ACK_RECOVERED="$(q -c "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='volvra_companion'")"
  [[ "$ACK_RECOVERED" != "$ACK" ]] && break
  sleep 1
done
[[ "$ACK_RECOVERED" != "$ACK" ]] && ok "and the slot then advanced to $ACK_RECOVERED" \
                                       || bad "the slot should advance once uploads caught up"

fi

# The slot must not pass what the manifest IN THE BUCKET covers, which is a
# stricter rule than "not past the last uploaded segment". The manifest is
# uploaded on a time bound rather than after every rotation, because a
# complete manifest per rotation makes archive traffic grow with the square
# of the segment count. A segment uploaded but not yet named by the uploaded
# manifest is unreachable to anyone reading the bucket, so acknowledging it
# would release write-ahead log for history that cannot be found again.
BUCKET_LAST="$(python3 - "$S3PORT" "$BUCKET" "$AK" "$SK" <<'MANIFETCH'
import sys, urllib.request, hashlib, hmac, datetime, json
port, bucket, ak, sk = sys.argv[1:5]
host = f"127.0.0.1:{port}"
t = datetime.datetime.now(datetime.timezone.utc)
amz = t.strftime('%Y%m%dT%H%M%SZ'); ds = t.strftime('%Y%m%d')
ph = hashlib.sha256(b'').hexdigest()
canon = (f"GET\n/{bucket}/manifest.json\n\nhost:{host}\nx-amz-content-sha256:{ph}\n"
         f"x-amz-date:{amz}\n\nhost;x-amz-content-sha256;x-amz-date\n{ph}")
scope = f"{ds}/us-east-1/s3/aws4_request"
sts = f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n{hashlib.sha256(canon.encode()).hexdigest()}"
def g(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
k = g(g(g(g(('AWS4'+sk).encode(), ds), 'us-east-1'), 's3'), 'aws4_request')
sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
auth = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
        f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}")
try:
    body = urllib.request.urlopen(urllib.request.Request(
        f"http://{host}/{bucket}/manifest.json",
        headers={'Authorization': auth, 'x-amz-date': amz,
                 'x-amz-content-sha256': ph}), timeout=15).read()
    segs = json.loads(body).get('segments') or []
    print(segs[-1]['end_lsn'] if segs else '0/0')
except Exception:
    print('0/0')
MANIFETCH
)"
HELD2="$(q -c "SELECT confirmed_flush_lsn <= '${BUCKET_LAST}'::pg_lsn FROM pg_replication_slots WHERE slot_name='volvra_companion'")"
if [[ "$HELD2" == "t" ]]; then
  ok "slot is within the manifest the bucket actually holds (to $BUCKET_LAST)"
else
  bad "slot passed the bucket's manifest ($BUCKET_LAST): WAL released for segments nothing in the bucket references"
fi

printf '=== S8. stop cleanly, then verify the bucket copy ===\n'
stop_companion "$COMPANION_PID"
unset COMPANION_PID
cm verify --archive "$ARCHIVE" "${S3FLAGS[@]}" >"$WORK/verify-both.log" 2>&1 \
  && ok "verify passes with local and bucket present" \
  || { bad "verify passes"; sed 's/^/       /' "$WORK/verify-both.log" | head -8; }

printf '=== S9. the decisive one: the host is gone ===\n'
# Delete the local archive entirely.  Everything from here reads the bucket.
mv "$ARCHIVE" "$WORK/archive-gone"
cm verify --archive "" "${S3FLAGS[@]}" >"$WORK/verify-remote.log" 2>&1 \
  && ok "the bucket copy verifies on its own" \
  || { bad "the bucket copy verifies on its own"; sed 's/^/       /' "$WORK/verify-remote.log" | head -8; }
grep -q "s3://" "$WORK/verify-remote.log" && ok "and reports the bucket as its source" \
  || bad "verify should name the bucket as its source"

printf '=== S10. restore from the bucket alone ===\n'
qq -c "TRUNCATE volvra.change_log" >/dev/null 2>&1
cm restore --archive "" "${S3FLAGS[@]}" --dsn "$DSN" >"$WORK/restore.log" 2>&1
RC=$?
sed 's/^/       /' "$WORK/restore.log" | head -4
LOADED="$(q -c "SELECT count(*) FROM volvra.change_log")"
if [[ $RC -eq 0 && "${LOADED:-0}" -gt 0 ]]; then
  ok "restored $LOADED change(s) into volvra.change_log from object storage"
else
  bad "restore from the bucket alone (rc=$RC, loaded=${LOADED:-0})"
fi

printf '=== S11. tampering in the bucket is detected ===\n'
python3 - "$S3PORT" "$BUCKET" "$AK" "$SK" <<'PY'
import sys, urllib.request, hashlib, hmac, datetime, json, urllib.error
port, bucket, ak, sk = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
host = f"127.0.0.1:{port}"
def signed(method, key, body=b''):
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate = t.strftime('%Y%m%dT%H%M%SZ'); datestamp = t.strftime('%Y%m%d')
    region, service = 'us-east-1', 's3'
    ph = hashlib.sha256(body).hexdigest()
    canonical = (f"{method}\n/{bucket}/{key}\n\nhost:{host}\nx-amz-content-sha256:{ph}\n"
                 f"x-amz-date:{amzdate}\n\nhost;x-amz-content-sha256;x-amz-date\n{ph}")
    scope = f"{datestamp}/{region}/{service}/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
    def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    k = sign(sign(sign(sign(('AWS4'+sk).encode(), datestamp), region), service), 'aws4_request')
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
            f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}")
    return urllib.request.Request(f"http://{host}/{bucket}/{key}", method=method, data=body or None,
        headers={'Authorization': auth, 'x-amz-date': amzdate, 'x-amz-content-sha256': ph})
m = json.loads(urllib.request.urlopen(signed('GET', 'manifest.json'), timeout=10).read())
first = m['segments'][0]['file']
body = urllib.request.urlopen(signed('GET', first), timeout=10).read()
body += b'{"lsn":"0/0","op":"U","table":"public.accounts","pk":{"id":1}}\n'
urllib.request.urlopen(signed('PUT', first, body), timeout=10)
print("       appended a forged line to", first, "in the bucket")
PY
cm verify --archive "" "${S3FLAGS[@]}" >"$WORK/tamper.log" 2>&1 \
  && bad "verify must fail on a tampered object" || ok "verify fails on a tampered object"
grep -qE "TAMPERED|TRUNCATED" "$WORK/tamper.log" && ok "and names it" \
  || { bad "and names it"; sed 's/^/       /' "$WORK/tamper.log" | head -6; }
cm restore --archive "" "${S3FLAGS[@]}" --dsn "$DSN" >/dev/null 2>&1 \
  && bad "restore must refuse a tampered bucket archive" \
  || ok "restore refuses a tampered bucket archive"

printf '=== S12. a corrupted upload is caught at upload time ===\n'
# The manifest hash is what the upload is checked against, so a segment whose
# recorded hash does not match its bytes must be refused rather than stored.
mv "$WORK/archive-gone" "$ARCHIVE"
python3 - "$ARCHIVE/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p))
s=(m.get('segments') or [])[-1]
s['uploaded_at']=''; s.pop('remote_key',None); s.pop('remote_etag',None)
s['sha256']='0'*64          # a hash the bytes cannot possibly produce
json.dump(m, open(p,'w'), indent=2)
print("       segment %d re-marked unuploaded with a wrong sha256" % s['seq'])
PY
run_until "manifest says|sha256" "$WORK/badhash.log" 45 volvra_companion \
  run --dsn "$DSN" --archive "$ARCHIVE" "${S3FLAGS[@]}"
grep -qi "manifest says\|sha256" "$WORK/badhash.log" \
  && ok "an upload whose bytes do not match the sealed hash is rejected" \
  || { bad "upload hash mismatch must be rejected"; sed 's/^/       /' "$WORK/badhash.log" | head -6; }
# And it must carry on rather than dying, which is what lets a transient
# bucket problem recover without anyone restarting the process.
grep -qi "will keep retrying\|still to upload" "$WORK/badhash.log" \
  && ok "and the companion keeps running instead of exiting" \
  || bad "a rejected upload should be retried, not fatal"

printf '=== S13. credentials never appear in logs or in the database ===\n'
if grep -q "$SK" "$WORK"/*.log 2>/dev/null; then
  bad "the secret key appears in a log"
else
  ok "no secret key in any companion log"
fi
URI="$(q -c "SELECT coalesce(archive_uri,'') FROM volvra.companion_checkpoint LIMIT 1")"
if [[ "$URI" == *"$SK"* || "$URI" == *"$AK"* ]]; then
  bad "credentials leaked into volvra.companion_checkpoint"
else
  ok "companion_checkpoint records the location only: $URI"
fi

printf '=== S14. a bucket that enforces object lock is reported ===\n'
# pgVolvra never SETS a retention; it reads the one the bucket already
# enforces. That is the case that actually happens: a security team sets a
# bucket policy, a DBA points the companion at it, and nobody connects that to
# volvra.forget() until an erasure request arrives.
#
# Creating locks was deliberately left out of this release. No S3
# implementation available as a container image enforces Object Lock --
# SeaweedFS and adobe/s3mock both accept a COMPLIANCE retention and then permit
# deleting and overwriting the object -- so a retention this code set would
# have been untested in the one respect that matters. See
# docs/archive_storage.md.
#
# So what is tested here is detection and reporting, which is the whole of what
# the feature now claims.
qq -c "TRUNCATE volvra.companion_checkpoint" >/dev/null 2>&1

LOCK_UNTESTED=0
LOCKBUCKET="volvra-locked"
python3 - "$S3PORT" "$LOCKBUCKET" "$AK" "$SK" <<'MKLOCK'
import sys, urllib.request, hashlib, hmac, datetime
port, bucket, ak, sk = sys.argv[1:5]
host = f"127.0.0.1:{port}"

def signed(method, path, hdrs_extra=None, body=b'', query=''):
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate = t.strftime('%Y%m%dT%H%M%SZ'); ds = t.strftime('%Y%m%d')
    ph = hashlib.sha256(body).hexdigest()
    hdrs = {'host': host, 'x-amz-content-sha256': ph, 'x-amz-date': amzdate}
    if hdrs_extra:
        hdrs.update(hdrs_extra)
    signed_h = ';'.join(sorted(hdrs))
    canon_h = ''.join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs))
    canonical = f"{method}\n{path}\n{query}\n{canon_h}\n{signed_h}\n{ph}"
    scope = f"{ds}/us-east-1/s3/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
    def sg(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    k = sg(sg(sg(sg(('AWS4'+sk).encode(), ds), 'us-east-1'), 's3'), 'aws4_request')
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    h = dict(hdrs)
    h['Authorization'] = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
                          f"SignedHeaders={signed_h}, Signature={sig}")
    del h['host']
    url = f"http://{host}{path}" + (f"?{query}" if query else '')
    return urllib.request.Request(url, method=method, data=body or None, headers=h)

# Object lock can only be enabled when the bucket is created.
try:
    urllib.request.urlopen(signed('PUT', f"/{bucket}",
        {'x-amz-bucket-object-lock-enabled': 'true'}), timeout=10)
    print("       lock-enabled bucket created")
except Exception as e:
    print("       bucket create:", e)

# The bucket POLICY carries the retention -- nothing pgVolvra does.
cfg = (b'<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled>'
       b'<Rule><DefaultRetention><Mode>COMPLIANCE</Mode><Days>2555</Days>'
       b'</DefaultRetention></Rule></ObjectLockConfiguration>')
try:
    urllib.request.urlopen(signed('PUT', f"/{bucket}", body=cfg,
                                  query='object-lock='), timeout=10)
    print("       bucket default retention set: COMPLIANCE 2555 days")
except Exception as e:
    print("       set retention:", e)
MKLOCK

cmbg run --dsn "$DSN" --archive "$WORK/lockarch" \
  --s3-bucket "$LOCKBUCKET" --s3-endpoint "127.0.0.1:$S3PORT" --s3-insecure \
  >"$WORK/lock.log" 2>&1 &
LOCKPID=$!
for _ in $(seq 1 60); do
  [[ "$(q -c "SELECT count(*) FROM volvra.companion_checkpoint WHERE immutable_mode IS NOT NULL")" == "1" ]] && break
  kill -0 "$LOCKPID" 2>/dev/null || break      # it died; stop waiting on it
  sleep 0.5
done

# Separate "the companion could not start" from "the companion did not
# report". They fail the same assertions and have nothing else in common.
# A loaded machine can make the store slow enough that the startup upload
# fails, and that failure is fatal by design, so the run ends before
# anything is recorded.
if ! kill -0 "$LOCKPID" 2>/dev/null; then
  if grep -qi "could not reach the bucket at startup" "$WORK/lock.log"; then
    echo "  SKIP the companion could not reach the store at startup, so the"
    echo "       object lock reporting below was never exercised. This is the"
    echo "       test store being slow, not a product failure:"
    sed -n 's/^/       /p' "$WORK/lock.log" | tail -2
    LOCK_UNTESTED=1
  fi
fi
stop_companion "$LOCKPID"

if [[ $LOCK_UNTESTED -eq 1 ]]; then
  bad "object lock reporting was not exercised: the test store did not come up"
else
grep -q "this bucket enforces object lock" "$WORK/lock.log" \
  && ok "the companion notices a retention it did not ask for" \
  || { bad "should detect the bucket's retention"; sed 's/^/       /' "$WORK/lock.log" | head -6; }
grep -q "WARNING: COMPLIANCE mode cannot be bypassed" "$WORK/lock.log" \
  && ok "and warns that COMPLIANCE cannot be bypassed" \
  || bad "startup warning for COMPLIANCE mode"
grep -q "volvra.forget() redacts history in the database" "$WORK/lock.log" \
  && ok "and names the conflict with volvra.forget()" \
  || bad "the startup warning should name the forget() conflict"

LOCKROW="$(q -c "SELECT immutable_mode||' '||immutable_days||' '||immutable_source FROM volvra.companion_checkpoint WHERE immutable_mode IS NOT NULL")"
[[ "$LOCKROW" == "COMPLIANCE 2555 bucket policy" ]] \
  && ok "recorded in the database: $LOCKROW" \
  || { bad "lock state recorded (got '$LOCKROW')"; sed 's/^/       /' "$WORK/lock.log" | tail -6; }

# pgVolvra must never be the thing that creates a lock.
grep -qiE "object-lock-days|object-lock-mode" "$WORK/lock.log" \
  && bad "the companion must not offer to set a retention" \
  || ok "the companion sets no retention of its own"

# The decision this has to reach is an erasure request.
qq <<'SQL'
CREATE TABLE IF NOT EXISTS people (id int PRIMARY KEY, email text);
SELECT volvra.enable('people');
INSERT INTO people VALUES (1,'subject@example.invalid') ON CONFLICT DO NOTHING;
UPDATE people SET email = 'changed@example.invalid' WHERE id = 1;
SQL
q -c "SELECT mode FROM volvra.forget('people','{\"id\":1}', reason=>'erasure request')" \
  >"$WORK/forget.log" 2>&1
grep -q "the archived copy of this history is immutable" "$WORK/forget.log" \
  && ok "volvra.forget() warns that the archived copy cannot be erased" \
  || { bad "forget() must warn about the immutable archive"; sed 's/^/       /' "$WORK/forget.log" | head -8; }
grep -q "including the account root" "$WORK/forget.log" \
  && ok "and says COMPLIANCE cannot be bypassed by anyone" \
  || bad "the forget warning should spell out what COMPLIANCE means"

PF="$(q -c "SELECT severity||': '||finding FROM volvra.preflight() WHERE finding LIKE '%object lock%'")"
[[ "$PF" == warning:* ]] && ok "preflight reports it: $PF" \
                         || bad "preflight should report the object lock (got '$PF')"
fi

printf '=== S15. no object lock means no noise ===\n'
qq -c "UPDATE volvra.companion_checkpoint SET immutable_mode=NULL, immutable_days=NULL, immutable_source=NULL" >/dev/null 2>&1
qq <<'SQL'
INSERT INTO people VALUES (2,'other@example.invalid') ON CONFLICT DO NOTHING;
UPDATE people SET email = 'x@example.invalid' WHERE id = 2;
SQL
q -c "SELECT mode FROM volvra.forget('people','{\"id\":2}', reason=>'erasure request')" \
  >"$WORK/forget2.log" 2>&1
grep -q "immutable" "$WORK/forget2.log" \
  && bad "forget() must stay quiet when the archive is not locked" \
  || ok "forget() says nothing extra when no lock is in force"
[[ -z "$(q -c "SELECT finding FROM volvra.preflight() WHERE finding LIKE '%object lock%'")" ]] \
  && ok "and preflight reports nothing" || bad "preflight should report nothing"

printf '=== S16. readback verification, the path GCS will take ===\n'
# Google Cloud Storage speaks the S3 API but rejects aws-chunked trailing
# headers, so a server-side checksum cannot be requested there and --s3-checksum
# resolves to readback. That path has to be proven to verify an upload just as
# strictly, which is what this does: force readback on a store that WOULD have
# supported server checksums, so the mode is the only thing that changed.
cmbg run --dsn "$DSN" --archive "$WORK/rbarch" "${S3FLAGS[@]}" \
  --slot volvra_readback --s3-prefix readback --s3-checksum readback \
  --segment-bytes 2048 >"$WORK/readback.log" 2>&1 &
RBPID=$!
for _ in $(seq 1 60); do
  [[ "$(q -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name='volvra_readback' AND active")" == "1" ]] && break
  sleep 0.5
done
qq <<'SQL'
INSERT INTO accounts SELECT g, 'rb'||g, g FROM generate_series(700,800) g;
UPDATE accounts SET balance = balance + 5 WHERE id >= 700;
SQL
for _ in $(seq 1 90); do
  RBUP="$(python3 - "$WORK/rbarch/manifest.json" <<'MANI'
import json,sys
try: m=json.load(open(sys.argv[1]))
except Exception: print(0); raise SystemExit
print(sum(1 for s in (m.get('segments') or []) if s.get('uploaded_at')))
MANI
)"
  [[ "${RBUP:-0}" -ge 1 ]] && break; sleep 1
done
stop_companion "$RBPID" volvra_readback

grep -q "verified by reading each segment back" "$WORK/readback.log" \
  && ok "the companion says readback doubles the traffic" \
  || { bad "readback mode must announce its cost"; sed 's/^/       /' "$WORK/readback.log" | head -5; }
if [[ "${RBUP:-0}" -ge 1 ]]; then
  ok "$RBUP segment(s) uploaded and verified by readback"
else
  bad "readback upload (got ${RBUP:-0})"
  echo "       --- readback log ---"; sed 's/^/       /' "$WORK/readback.log" | tail -8
fi

cm verify --archive "" "${S3FLAGS[@]}" --s3-prefix readback \
  >"$WORK/rbverify.log" 2>&1
RBRC=$?
RBSEGS="$(grep -E '^segments' "$WORK/rbverify.log" | awk '{print $2}')"
if [[ $RBRC -eq 0 && "${RBSEGS:-0}" -ge 1 ]]; then
  ok "and the result verifies from the bucket alone ($RBSEGS segment(s))"
else
  # An empty manifest verifies trivially, so the segment count is the part
  # that makes this assertion mean anything.
  bad "readback archive verifies with segments (rc=$RBRC, segments=${RBSEGS:-0})"
  sed 's/^/       /' "$WORK/rbverify.log" | head -6
fi

# readback must be no weaker than the server path: a hash the bytes cannot
# produce has to be refused either way.
python3 - "$WORK/rbarch/manifest.json" <<'BADHASH'
import json,sys
p=sys.argv[1]; m=json.load(open(p))
s=(m.get('segments') or [])[-1]
s['uploaded_at']=''; s.pop('remote_key',None); s.pop('remote_etag',None)
s['sha256']='0'*64
json.dump(m, open(p,'w'), indent=2)
BADHASH
run_until "manifest says|sha256" "$WORK/rbbad.log" 45 volvra_readback \
  run --dsn "$DSN" --archive "$WORK/rbarch" "${S3FLAGS[@]}" \
  --slot volvra_readback --s3-prefix readback --s3-checksum readback
grep -qi "manifest says\|sha256" "$WORK/rbbad.log" \
  && ok "readback rejects an upload whose bytes do not match the sealed hash" \
  || { bad "readback must reject a hash mismatch"; echo "       --- rbbad.log (full) ---"; sed 's/^/       /' "$WORK/rbbad.log"; echo "       --- manifest ---"; sed 's/^/       /' "$WORK/rbarch/manifest.json" | head -25; }

# An unknown mode is a typo, not a reason to silently pick one.
cm run --dsn "$DSN" --archive "$WORK/badck" "${S3FLAGS[@]}" \
  --s3-checksum nonsense >"$WORK/badck.log" 2>&1
grep -q "must be auto, server or readback" "$WORK/badck.log" \
  && ok "an unknown --s3-checksum is refused" || bad "unknown --s3-checksum must be refused"

echo
if [[ $FAILED -eq 0 ]]; then
  echo "*** ALL VOLVRA COMPANION S3 CHECKS PASSED ***"
else
  echo "!!! VOLVRA COMPANION S3 CHECKS FAILED"
fi
exit $FAILED
