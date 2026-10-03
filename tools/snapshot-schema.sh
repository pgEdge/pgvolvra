#!/usr/bin/env bash
# Freeze the current install script as a release snapshot.
#
#   ./tools/snapshot-schema.sh            # version from extension/volvra.control
#   ./tools/snapshot-schema.sh 0.2.0
#
# Run this at every release, right after tagging. The snapshot it writes is
# how the next release proves that upgrading from this one preserves history.
#
# Reconstructing a released schema afterwards, from git or from memory, is the
# thing this exists to avoid: it is guesswork exactly when accuracy matters,
# and the guess is unfalsifiable because the release it describes is gone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/volvra.control")}"
[[ -n "$VERSION" ]] || { echo "could not determine a version" >&2; exit 1; }

OUT="$ROOT/test/releases/volvra-${VERSION}.sql"

if [[ -e "$OUT" ]]; then
  echo "$OUT already exists." >&2
  echo "A released schema never changes, so this refuses to overwrite one." >&2
  echo "Delete it deliberately if the release was never published." >&2
  exit 1
fi

mkdir -p "$ROOT/test/releases"
{
  echo "-- ====================================================================="
  echo "-- pgVolvra ${VERSION} -- FROZEN RELEASE SNAPSHOT. Do not edit."
  echo "--"
  echo "-- Captured from sql/volvra.sql by tools/snapshot-schema.sh at release"
  echo "-- time. Its only purpose is to let a later release prove that"
  echo "-- upgrading from ${VERSION} preserves history and leaves a working"
  echo "-- engine behind. Editing it makes that proof a fiction."
  echo "--"
  echo "-- If ${VERSION} had a bug, the snapshot keeps the bug. That is correct:"
  echo "-- the databases being upgraded have it too."
  echo "-- ====================================================================="
  cat "$ROOT/sql/volvra.sql"
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
echo
echo "This snapshot is also what tells extension/build.sh that ${VERSION} is a"
echo "released version, so the next release emits an ALTER EXTENSION UPDATE"
echo "path from it.  Nothing further to add by hand."
