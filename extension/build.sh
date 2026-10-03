#!/usr/bin/env bash
# Generate the extension script from the canonical install file.
#
# There is deliberately no second copy of the engine: the extension SQL is
# derived, so the two cannot drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/volvra.control")"
OUT="$ROOT/extension/volvra--${VERSION}.sql"

# The schema version is reported, not enforced: it is an internal migration
# counter and the product version is a release decision.  What matters is that
# the generated script is rebuilt from the current source every time, which is
# why the old ones are removed below.
SCHEMA_V="$(grep -oE "VALUES \(([0-9]+), '" "$ROOT/sql/volvra.sql" \
            | grep -oE '[0-9]+' | sort -n | tail -1)"

# Stale generated scripts are a trap: an old one still installs.
rm -f "$ROOT"/extension/volvra--*.sql

{
  echo "-- Generated from sql/volvra.sql by extension/build.sh -- do not edit."
  echo "-- CREATE EXTENSION already runs in a transaction and forbids"
  echo "-- transaction control, so the BEGIN/COMMIT wrapper is stripped."
  echo
  echo "\\echo Use \"CREATE EXTENSION volvra\" to load this file. \\quit"
  echo
  # Drop the transaction wrapper and any psql meta-command; keep every SQL
  # statement byte for byte.
  grep -v -e '^\\' -e 'volvra:tx' "$ROOT/sql/volvra.sql"
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, schema v$SCHEMA_V)"

# Upgrade scripts, one per previously released version.
#
# PostgreSQL discovers the update paths an extension offers from the filenames
# present in SHAREDIR/extension: a volvra--<from>--<to>.sql *is* the
# declaration that <from> can be updated to <to>.  Without one, ALTER EXTENSION
# UPDATE refuses with "extension has no update path" and an extension-installed
# database is stranded on the version it has.
#
# The list of released versions is derived from test/releases/, which already
# holds one frozen snapshot per release, written by tools/snapshot-schema.sh as
# part of cutting one.  Deriving it is the whole point: a hand-maintained list
# is a step someone has to remember at every release, and forgetting it is
# invisible until the release after next, by which time it is too late for
# anyone already installed.  Not git tags -- a tarball build has none.
#
# The bodies are byte-identical to the install script, because the installer is
# a version-aware migration runner: it reads what a database already has and
# applies only what is missing.  Only the header differs, naming
# ALTER EXTENSION ... UPDATE rather than CREATE EXTENSION.

# Semantic version ordering.  `sort -V` is natural sort, not semver: it ranks
# 1.0.0 *below* 1.0.0-beta1, where semver has a pre-release precede the release
# it leads to.  Comparing the cores separately fixes exactly that one
# disagreement, and still leaves sort -V to rank beta2 below beta10.
ver_lt() {
  local a="$1" b="$2" ca="${1%%-*}" cb="${2%%-*}"
  [[ "$a" == "$b" ]] && return 1
  if [[ "$ca" != "$cb" ]]; then
    [[ "$(printf '%s\n%s\n' "$ca" "$cb" | sort -V | head -1)" == "$ca" ]]
    return
  fi
  [[ "$a" == *-* && "$b" != *-* ]] && return 0   # pre-release precedes release
  [[ "$a" != *-* && "$b" == *-* ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]
}

emitted=0
shopt -s nullglob
for snap in "$ROOT"/test/releases/volvra-*.sql; do
  from="$(basename "$snap")"; from="${from#volvra-}"; from="${from%.sql}"

  # A version cannot upgrade to itself, and the current release has a snapshot
  # of its own as soon as it is cut.
  [[ "$from" == "$VERSION" ]] && continue

  # A snapshot above default_version means the control file and the release
  # history disagree.  Emitting a script for it would name a downgrade as an
  # upgrade, so this stops instead of guessing which of the two is wrong.
  if ! ver_lt "$from" "$VERSION"; then
    echo "error: test/releases holds $from, which is not below default_version" >&2
    echo "       $VERSION in extension/volvra.control.  One of the two is wrong;" >&2
    echo "       a $from -> $VERSION script would declare a downgrade path." >&2
    exit 1
  fi

  UP="$ROOT/extension/volvra--${from}--${VERSION}.sql"
  {
    echo "-- Generated from sql/volvra.sql by extension/build.sh -- do not edit."
    echo "-- Upgrade $from -> $VERSION.  Byte-identical to the install script:"
    echo "-- the installer applies only the migrations a database is missing."
    echo
    echo "\\echo Use \"ALTER EXTENSION volvra UPDATE\" to load this file. \\quit"
    echo
    grep -v -e '^\\' -e 'volvra:tx' "$ROOT/sql/volvra.sql"
  } > "$UP"
  echo "wrote $UP"
  emitted=$(( emitted + 1 ))
done
shopt -u nullglob

if [[ $emitted -eq 0 ]]; then
  echo "no upgrade scripts: test/releases holds no version below $VERSION"
fi
