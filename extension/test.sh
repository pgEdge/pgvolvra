#!/usr/bin/env bash
# Verify the generated extension script actually loads via CREATE EXTENSION,
# and that the engine works afterwards.  Runs in a container so no local
# PostgreSQL install is needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"
VER="${1:-17}"
IMG="postgres:$VER"; [[ "$VER" == "19" ]] && IMG="postgres:19beta1"
C="volvra-ext-$$"

cleanup() { docker rm -f "$C" >/dev/null 2>&1; }
trap cleanup EXIT

VERSION="$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/volvra.control")"
[[ -f "$ROOT/extension/volvra--${VERSION}.sql" ]] \
  || { echo "run extension/build.sh first"; exit 1; }

# ---------------------------------------------------------------------
# Every released version must have an update path to this one.
#
# PostgreSQL reads the paths an extension offers off the filenames in
# SHAREDIR/extension, so a missing file is not an error until someone runs
# ALTER EXTENSION UPDATE on a database installed from that version -- in
# production, one release too late to fix.  Checking it here turns the
# omission into a failed build instead.
#
# test/releases holds one frozen snapshot per release, so it is the list of
# versions that exist in the wild.  Asserting against it, rather than against
# whatever build.sh happened to derive, means the two would have to be wrong
# in the same way to pass.
# ---------------------------------------------------------------------
missing=()
shopt -s nullglob
for snap in "$ROOT"/test/releases/volvra-*.sql; do
  from="$(basename "$snap")"; from="${from#volvra-}"; from="${from%.sql}"
  [[ "$from" == "$VERSION" ]] && continue
  [[ -f "$ROOT/extension/volvra--${from}--${VERSION}.sql" ]] || missing+=("$from")
done
shopt -u nullglob
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "!!! no update path to $VERSION from released version(s): ${missing[*]}"
  echo "    extension/build.sh should have emitted one per snapshot in"
  echo "    test/releases/; databases installed from those versions would be"
  echo "    stranded with \"extension has no update path\"."
  exit 1
fi
echo "update paths present for: $(ls "$ROOT"/extension/volvra--*--*.sql 2>/dev/null \
                                  | wc -l | tr -d ' ') released version(s)"

echo "▶ CREATE EXTENSION volvra on $IMG"
docker run -d --name "$C" -e POSTGRES_PASSWORD=e -e POSTGRES_DB=ext \
  -v "$ROOT:/volvra:ro" "$IMG" >/dev/null

# pg_isready is not enough here.  The postgres image runs initdb against a
# temporary server so the init scripts can run, and pg_isready answers yes
# during that window -- before POSTGRES_DB exists.  Connecting then fails with
# 'database "ext" does not exist', which reads as a product failure and is not
# one.  volvra_wait_ready requires two consecutive real queries instead; the
# rest of the suite has used it for exactly this reason since it cost two CI
# jobs.
volvra_wait_ready "$C" ext || { echo "!!! server never became ready"; exit 1; }

SHAREDIR="$(docker exec "$C" pg_config --sharedir)"
docker exec "$C" bash -c "cp /volvra/extension/volvra.control '$SHAREDIR/extension/' && \
                          cp /volvra/extension/volvra--${VERSION}.sql '$SHAREDIR/extension/'"

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d ext <<'SQL'
CREATE EXTENSION volvra;

CREATE TABLE ext_orders (id int PRIMARY KEY, total numeric);
SELECT volvra.enable('ext_orders');
INSERT INTO ext_orders VALUES (1, 100);
SQL
rc=$?
[[ $rc -eq 0 ]] || { echo "!!! CREATE EXTENSION FAILED"; exit 1; }

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d ext <<'SQL'
SELECT pg_sleep(0.05);
UPDATE ext_orders SET total = 0;
DO $$
DECLARE v_n bigint;
BEGIN
  -- Scope by op rather than by time: a window wide enough to catch the update
  -- also catches the insert, and would correctly delete the row.
  SELECT count(*) INTO v_n
  FROM volvra.undo('ext_orders', predicate => $p$op = 'U'$p$, confirm => true);
  ASSERT v_n = 1, format('expected to revert 1 update, reverted %s', v_n);
  ASSERT (SELECT total FROM ext_orders WHERE id = 1) = 100,
    'undo works when installed as an extension';
  ASSERT (SELECT extversion FROM pg_extension WHERE extname = 'volvra') IS NOT NULL,
    'registered as an extension';
END $$;
SELECT 'extension ok' AS result;
SQL
rc=$?

[[ $rc -eq 0 ]] || { echo "!!! VOLVRA EXTENSION PACKAGING FAILED"; exit 1; }

# ---------------------------------------------------------------------
# ALTER EXTENSION UPDATE
#
# An extension-installed database that cannot be upgraded is stranded on the
# version it has, and the failure only shows up at the *second* release --
# by which time it is too late to fix for anyone already installed. So the
# path is tested now, before there is a real version to upgrade from.
#
# The older version here is fabricated by this test: the install body is
# copied under a synthetic 0.0.0, together with the 0.0.0 -> current upgrade
# script that build.sh would emit for a real one. That exercises the actual
# ALTER EXTENSION UPDATE machinery -- version resolution, the update path,
# and re-running the installer against a database that already has the schema.
# ---------------------------------------------------------------------
echo "▶ ALTER EXTENSION UPDATE from a synthetic older version"

docker exec "$C" psql -q -U postgres -d postgres -c "CREATE DATABASE upg" >/dev/null 2>&1

docker exec "$C" bash -c "
  set -e
  cd '$SHAREDIR/extension'
  # A 0.0.0 whose body is the current install script, and an upgrade script
  # to the current version. Both are what build.sh produces for a real
  # released version; only the version number is invented.
  cp volvra--${VERSION}.sql volvra--0.0.0.sql
  cp volvra--${VERSION}.sql volvra--0.0.0--${VERSION}.sql
  sed -i 's/^default_version = .*/default_version = '\''0.0.0'\''/' volvra.control
"

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d upg >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION volvra VERSION '0.0.0';
CREATE TABLE upg_t (id int PRIMARY KEY, v int);
SELECT volvra.enable('upg_t');
INSERT INTO upg_t VALUES (1, 1);
SELECT pg_sleep(0.05);
UPDATE upg_t SET v = 0;
SQL
[[ $? -eq 0 ]] || { echo "!!! could not install the synthetic older version"; exit 1; }

BEFORE=$(docker exec "$C" psql -tA -U postgres -d upg \
  -c "SELECT count(*) FROM volvra.change_log" 2>/dev/null | tr -d '[:space:]')

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d upg <<SQL
ALTER EXTENSION volvra UPDATE TO '${VERSION}';
SQL
urc=$?
[[ $urc -eq 0 ]] || { echo "!!! ALTER EXTENSION UPDATE FAILED"; exit 1; }

# The upgrade must keep the history and leave a working engine behind it.
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d upg <<SQL
DO \$\$
DECLARE v_n bigint;
BEGIN
  ASSERT (SELECT extversion FROM pg_extension WHERE extname = 'volvra')
         = '${VERSION}',
    'the extension reports the new version';
  ASSERT (SELECT count(*) FROM volvra.change_log) = ${BEFORE:-0},
    'the upgrade preserved every captured change';
  SELECT count(*) INTO v_n
  FROM volvra.undo('upg_t', predicate => \$p\$op = 'U'\$p\$, confirm => true);
  ASSERT v_n = 1, format('an undo driven by pre-upgrade history reverted %s', v_n);
  ASSERT (SELECT v FROM upg_t WHERE id = 1) = 1,
    'and it restored the pre-upgrade value';
END \$\$;
SELECT 'upgrade ok' AS result;
SQL
[[ $? -eq 0 ]] || { echo "!!! post-upgrade checks FAILED"; exit 1; }

echo "*** VOLVRA EXTENSION PACKAGING PASSED ***"
