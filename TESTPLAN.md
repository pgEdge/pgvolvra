# Test plan

Planned 2026-09-07, to run next session. The goal is coverage that is
comprehensive across three axes at once: every supported PostgreSQL
version, every privilege context, and every scenario the design makes
claims about.

## Where we are

The following table describes the current baseline:

| Measure | Value |
|---|---|
| SQL assertions | 472 across 12 suites, in two privilege contexts |
| Privilege pairs | 322, asserted in both directions |
| Shell checks | 148 across seven shell suites |
| PostgreSQL versions | 14, 15, 16, 17, 18, 19beta1 |
| Linux distributions | 11, via `test/portability.sh` |
| Public functions | 47 |

Every priority is complete. The following table describes what each
one delivered:

| Priority | State | Where |
|---|---|---|
| 1. Both privilege contexts | Done | `test/run.sh`, `CONTEXTS=(owner super)` |
| 2. Privilege matrix | Done | `test/privileges.sql`, 301 pairs |
| 3. Concurrency | Done | `test/concurrency.sh`, 21 checks |
| 4. Crash and recovery | Done | `test/recovery.sh`, 22 checks |
| 5. Upgrade paths | Done | Snapshot tooling, release-to-release test |
| 6. Scenario coverage | Done | `test/scenarios.sql`, 81 assertions |
| 7. Scale | Done | `test/scale.sh`, 23 checks |

## The central gap

Everything substantial runs as a superuser. The non-superuser path
runs `nosuperuser.sql` only, which is 9 assertions, so 263 of 272
assertions have never executed as anything but a superuser.

That is not a hypothetical weakness. It is exactly what hid two
`GRANT` statements that had silently failed to apply, leaving
`volvra_viewer` unable to read six documented tables and the companion
unable to report progress unless it owned the schema. A documentation
audit found those, not the tests.

Closing this gap was the first priority. It is closed: `test/run.sh`
now runs the whole battery in both contexts, and the privilege matrix
in priority 2 is what catches a grant that fails to apply. It has
since caught a third such case, on `volvra.restore_point`.

## Priority 1: run everything twice per version

Restructure `test/run.sh` so each version runs the whole battery in
two privilege contexts:

- installed and operated by a superuser, which is today's behavior.
- installed and operated by a non-superuser owner holding CREATE on
  the database and CREATEROLE, which is what a managed provider gives
  you.

This turns 6 runs into 12 and needs no new assertions. Every existing
suite must pass unchanged in both contexts; any that cannot is either
a bug or a documented superuser-only behavior, and both outcomes are
worth having in writing.

Expect real failures on the first attempt. Candidates include the
partition grants, `SECURITY DEFINER` ownership, `ALTER TABLE` on
tables the owner does not own, and `pg_replication_slots` visibility.

## Priority 2: a privilege matrix

Add `test/privileges.sql`, driven by a table rather than by prose. For
each role and each public function, assert allowed or denied.

The following table describes the roles to cover:

| Role | Represents |
|---|---|
| superuser | The install that preflight grades as critical. |
| schema owner, not superuser | The recommended production install. |
| volvra_admin, not owner | An administrator who does not own the schema. |
| volvra_operator with table rights | An operator who can legitimately undo. |
| volvra_operator without table rights | An operator who must be refused. |
| volvra_viewer with SELECT | A reader of history. |
| volvra_viewer without SELECT | A reader who must see nothing. |
| application role, no volvra grants | The role whose writes are captured. |
| role with no grants at all | The role that must reach nothing. |

Assert both directions for every cell: that a permitted call succeeds,
and that a forbidden call raises `insufficient_privilege` rather than
returning empty. An empty result and a refusal are different answers,
and only one of them is safe.

This is the suite that would have caught the grant bugs on the day
they were introduced.

## Priority 3: concurrency

Done on 2026-09-08. `test/concurrency.sh` drives real parallel `psql`
sessions and passes 21 checks on all six versions.

Writing it corrected one assumption rather than finding a defect. The
first version of the lost-update scenario had the racing writer write
inside the undo window, and reverting that write is correct behavior,
not a lost update. The scenario only tests the conflict guard when the
racing write lands after the window closes, which is what the suite
now does; it also asserts that `skip_conflicts` then reverts the
uncontended rows and still refuses the contended one.

The following scenarios are covered:

- two undos of the same table at once, which must serialize on the
  advisory lock rather than interleave.
- two undos of overlapping multi-table selections, which must queue
  rather than deadlock.
- an undo running while another session writes the same rows, which
  must produce a conflict rather than a lost update.
- two `volvra.seal()` calls at once, which must not produce
  overlapping spans.
- two companions on one slot, where the second must be refused. The
  second reports PostgreSQL's own `55006`, "replication slot is active
  for PID", and exits without writing change data.
- `volvra.maintain()` running while an undo is in progress.
- every write from four concurrent writers captured and attributed
  separately, which the single-session suites cannot show.

The companion scenario needs a Linux binary in
`VOLVRA_COMPANION_BIN`; without one it is skipped rather than passing
quietly.

## Priority 4: crash and recovery

Done on 2026-09-08. `test/recovery.sh` passes 22 checks on all six
versions, killing the server with `pg_ctl -m immediate` and the
companion with `SIGKILL`.

This one found a real defect. After a `SIGKILL` the companion
re-archived 500 changes it already held, because the LSN passed to
`START_REPLICATION` is a request rather than a guarantee: PostgreSQL
may begin streaming from an earlier point, and after a hard kill it
does, since the slot's confirmed position lags what the archive holds
durably. The companion resumed from the right place and then wrote
whatever the server sent it. It now drops changes at or below the
archive's resume point, and `verify()` no longer reports the result as
out of order.

Writing the suite also found that `verify` walked only the segments
the manifest covered, so a segment file the manifest did not
cover - the normal residue of a kill mid-segment, or a file planted by
hand - was silently ignored. Since the archive is documented as
readable without the binary, `verify` now reports those as
`UNRECORDED`. They are notices rather than integrity failures, so a
crash does not make verification fail, and `restore` still refuses
only on real failures.

A third finding was in the test rather than the product: the first
version asserted that an archive verified while its manifest recorded
zero segments, which is the same vacuous shape as the earlier
`>= 0` size assertion. The suite now asserts the manifest is
non-empty before it trusts any tamper check, and forces rotation with
`--segment-bytes 8192` so segments actually reach the manifest.

The following scenarios are covered:

- the companion killed with SIGKILL mid-segment, then restarted, which
  must resume without losing or duplicating a change.
- the database restarted mid-undo, which must leave no partial undo.
- the database restarted mid-`purge`, mid-`seal`, and mid-migration.
- the archive filesystem full during a write, using a 1 MB tmpfs. If
  the tmpfs never fills the check reports itself as inconclusive
  rather than passing.
- a manifest truncated mid-write, which the atomic rename should make
  impossible, plus a flipped byte in a manifested segment and a
  segment file planted by hand.
- a crash mid-install, which must leave the schema either absent or
  complete, because the install is one transaction.

## Priority 5: upgrade paths

Done on 2026-09-08, ahead of the first release rather than after it.

The priority as written assumed schema versions 1 through 6 existed.
Collapsing the pre-release migrations into a single
`1 | initial schema` left one released schema, so there was no
multi-version path to fix. What was actually owed was the mechanism,
and that is now in place:

- **The pre-release repair blocks are gone.** Three of them existed
  only to fix databases created during development, and they made the
  install script carry code that could never run again once anything
  was released. The engine is 78 lines shorter for it.
- **`tools/snapshot-schema.sh` freezes a release as a snapshot.**
  `test/releases/volvra-1.0.0-beta1.sql` is the first. Reconstructing a
  released schema later, from git or from memory, is guesswork exactly
  when accuracy matters, and the guess is unfalsifiable because the
  release it describes is gone. The tool refuses to overwrite an
  existing snapshot, because a released schema never changes.
- **`test/run.sh` picks the highest-versioned fixture itself**, so
  adding a snapshot is all it takes to make the upgrade test cover
  that release.
- **The upgrade test is now release-to-release.** It seeds real
  history *and a seal* through the previous release's own capture
  path, then asserts the version ledger never goes backwards, every
  row and id survives, the seal chain still verifies with an unchanged
  head, and an undo driven entirely by pre-upgrade history restores
  the row. With one release the fixture is the current schema, so this
  proves reinstalling over live history is safe; it becomes a genuine
  cross-version upgrade at release 2 with no change to the test.
- **`ALTER EXTENSION UPDATE` has a tested path.**
  `extension/build.sh` emits a `volvra--<from>--<to>.sql` for every
  version in `extension/upgrade-from.txt`, byte-identical to the
  install script because the installer is a version-aware migration
  runner. `extension/test.sh` proves the machinery now, against a
  synthetic older version it fabricates itself, rather than waiting
  for release 2 to discover that extension-installed databases are
  stranded.

## Priority 6: scenario coverage

Done on 2026-09-08. `test/scenarios.sql` covers eleven areas and runs
in a database of its own as the unprivileged owner, because it asserts
that `verify()` is clean and phase 4 deliberately plants tampering.

This priority found the two worst defects of the whole effort, both in
the same blind spot: volvra assumed a covered table keeps the name and
the shape it had when it was covered.

**A partitioned table was left unusable.** `enable()` on a partitioned
parent reported success, and then every INSERT failed with
"sc.part_a is not registered via volvra.enable()". PostgreSQL
propagates a row trigger from a parent to its partitions and fires it
with `TG_RELID` set to the partition, which was not what had been
registered. `capture()` now walks up to the covered ancestor through
`volvra._covered_ancestor()` and records the change under that name,
so a partitioned table behaves as the one table the caller covered,
including partitions attached later. Two consequences fell out of
fixing it: statement-level TRUNCATE triggers are *not* propagated, so
`volvra.cover_partitions()` attaches them and `maintain()` reconciles
partitions added since; and a truncate of a parent fires the trigger on
the parent and on every partition, so the parent must capture nothing
and each partition only its own rows, or three rows are captured nine
times.

**Renaming a covered table left it unwritable.** `ALTER TABLE ...
RENAME` moves the triggers with the table but left `enabled_tables`
naming a table that no longer existed, so every subsequent write
failed. `enabled_tables` gained `rel_oid`, which survives both RENAME
and SET SCHEMA, and `capture()` finds the row by OID and corrects the
name, raising a notice. History stays under the old name, because that
is what was true when the change happened.

Neither defect could have been found by the other suites: every one of
them covers a table and then leaves its name and shape alone.

Five test bugs were also found and fixed while writing it, and they are
worth recording because four are the same mistake:

- `on_truncate` values are `block`, `capture`, and `allow`. There is
  no `refuse`.
- `capture` mode records truncated rows as `D`, not `T`, because
  re-inserting a deleted row is what undoing a truncate does. `T` is
  the marker written by `allow` mode.
- `change_log` columns are `ts`, `old_row`, and `new_row`.
- `now()` inside a `DO` block is the transaction's start time, which is
  earlier than a `clock_timestamp()` taken inside the same block.
- multi-table selection is the named `tables` parameter; the first
  positional argument is a single `regclass`.

The following table describes the areas the suite covers:

| Area | Scenario |
|---|---|
| Table shapes | Composite primary key, natural text key, identity key, generated columns, a partitioned user table, an unlogged table, a temporary table. |
| Type fidelity | The full 37-column matrix under `capture_updates = full`, which is currently proven on three columns. |
| Schema change | Add, drop, and rename a column; change a type; add NOT NULL; rename the table; move it between schemas; drop and recreate it. |
| Identifiers | Quoted, mixed case, 63-character maximum length, non-ASCII, and names containing quotes and dots. |
| Foreign keys | Self-referencing, multi-level cascade, `SET NULL`, `SET DEFAULT`, deferrable and non-deferrable, circular. |
| Truncate | All three modes against an empty table, a table at the row cap, and a partitioned table. |
| Partitions | A transaction spanning a month boundary, a missing month, a full default partition, and retention that empties every partition. |
| Integrity | A `TimeZone` change between sealing and verifying, a clock moved backwards, and sealing across a retention run. |
| Erasure | A subject whose key appears in several tables, a composite key, and a redaction followed by an undo of the redacted range. |
| Row-level security | A covered table that has its own RLS policies, and a `FORCE ROW LEVEL SECURITY` table. |
| Pooling | `volvra.actor` under transaction-mode pooling, which is the documented failure mode. |
| Companion | Publication drift after covering a new table, `wal_level` turned off while a slot exists, `REPLICA IDENTITY` removed after setup, a slot conflict, and an archive from a different slot. |
| Locale | A non-UTF8 database encoding and a non-C collation. |

Three rows in that table remain deliberately out of scope, with
reasons rather than assertions:

- a temporary table cannot be covered usefully, because its triggers
  and its rows die with the session that created it, and the history
  would outlive the table it describes.
- a non-UTF8 database encoding and a non-C collation need a database
  created with those settings, so they belong to a separate driver
  rather than a suite that runs inside an existing database. The
  identifier and type assertions cover the cases most likely to break,
  including non-ASCII identifiers and values.
- transaction-mode pooling is asserted through the mechanism rather
  than through a pooler: the suite proves `SET LOCAL` does not leak
  across transactions and a plain `SET` does, which is the whole of
  the documented failure mode.

## Beyond the plan: replay, backups, and multi-node

Three suites exist that no priority asked for, because the work that
produced them turned up questions the plan had not anticipated.

`test/replay.sql` and `test/replay-edge.sql` cover forward replay, the
mirror of undo, across 23 sections. The engine shares one plan builder,
one guard, one cap and one transaction between the two directions, so
a safety property cannot hold for an undo and not a replay. The
assertions were checked by mutating the engine three ways -- removing
the guard, reversing the order, applying the wrong image -- and each
mutation is caught by a different section.

`test/backup-replay.sh` takes a real `pg_dump`, drops the database,
restores it, loads the archived history and replays forward, then
asserts the recovered database is byte-identical to the one that was
lost by hashing every row of every covered table. It runs on all six
versions. Writing it found two defects that affected undo as well as
replay: guards compared generated columns, which logical replication
does not send, and on PostgreSQL 18 `companion_setup` left a covered
table with a generated column impossible to update at all.

`test/multinode.sh` builds a two-node Spock cluster from the
`pgedge/pgedge` image. PostgreSQL does not fire an ordinary row
trigger for rows applied by replication, so a node would record only
its own changes; the suite measures both settings of
`capture_replicated` and ends by having a node revert a change made on
its peer. It is the only suite that needs more than one server.

## Priority 7: scale

Done on 2026-09-08. `test/scale.sh` runs on demand, defaults to one
million rows on PostgreSQL 17, and prints timings for information
without asserting on them, because a laptop under Docker is not a
benchmark.

This priority found **three engine defects**, two of them quadratic and
one that could stop retention from running at all. None was visible
below roughly fifty thousand rows, which is why every other suite
missed them.

**Two quadratic defects in `volvra._plan()`**, which both
`preview_undo` and `undo` go through:

- the statement builders compared primary-key columns with
  `IS NOT DISTINCT FROM`. That is NULL-safe and **not indexable**, so
  every conflict probe was a sequential scan of the target table, one
  per row. Now plain `=`, which is correct because a primary key column
  cannot be NULL: the NULL-safety bought nothing and cost the index.
- the dedup that decides which change is the newest for its row kept a
  jsonb object of every row already seen and grew it by concatenation.
  **jsonb concatenation copies the whole object**, so a 200,000-row
  plan copied roughly 500 GB and ran for over twenty minutes, looking
  like a hang. Now a window function in the driving query.

Measured on 200,000 rows, before and after: a preview went from over
twenty-two minutes, never observed to finish, to **19 seconds**; the
undo it enables takes **22 seconds**.

**`seal()` refused a backlog instead of sealing a batch.** The
`seal_max_rows` setting is documented as the largest span one call will
hash, which describes batching. The implementation raised
`program_limit_exceeded` instead, and because `volvra.maintain` calls
`seal()` inside a single transaction, one over-limit seal aborted the
whole maintenance run and **rolled back partition creation and
retention with it**. A database that crossed a million unsealed
changes would stop provisioning partitions and stop applying retention,
growing disk without bound, with a limit on *sealing* as the cause, and
recover only when an operator noticed and raised the setting by hand.
`seal()` now caps the span, reports through a notice that more remains,
and catches up over successive calls. The suite asserts both the
batching and that `maintain()` survives a backlog over the limit.

The following scenarios are covered:

- an undo of one million rows against the blast-radius cap, refused at
  the cap and completing when the cap is raised deliberately.
- `volvra.seal()` at and past `seal_max_rows`, including that repeated
  calls make progress, produce no overlapping spans, and still verify.
- `TRUNCATE` refused above `truncate_capture_max_rows`.
- history across twelve past months, with retention dropping whole
  partitions rather than deleting rows.
- every reporting function against a large history, including that
  `volvra.storage()` reports a real size for the partitioned parent.

Four of the suite's own assertions could not fail when first written,
and each reported success while measuring state the suite had not
created. They are recorded here because the same mistake was made four
times:

- an archive tamper check ran against a manifest holding zero
  segments, so nothing was verified.
- "no back-dated rows in the default partition" is true both when the
  rows are placed correctly and when no rows exist at all.
- "thirteen month partitions exist" passed while the section that
  creates them did nothing, because the install provisions a year
  ahead. Only partitions older than the retention cutoff are
  countable evidence.
- a `pg_total_relation_size()` assertion of `>= 0`, which no value can
  fail.

The rule the suite now follows: assert the fixture is non-trivial
before asserting anything about it.

One more failure was neither the product nor an assertion.
`docker exec` needs `-i` to accept a heredoc; without it psql is handed
no stdin and exits silently, with no output and nothing in the log. The
block creating the past partitions and the back-dated history did
nothing for two runs. Every suite has a `sql()` helper that passes
`-i`; use it rather than a bare `docker exec`.

## How to run it

The matrix must stay one command. Extend `test/run.sh` to take the
privilege context as a dimension, and keep the on-demand suites
separate because they need special setup or a long run:

```bash
./test/run.sh                  # 6 versions, both privilege contexts
./test/run-companion.sh        # durable tier, 6 versions
./test/examples.sh             # the six documented examples, 6 versions
./test/scale.sh 17 1000000     # limits at size, on demand
# scenarios run inside ./test/run.sh, in a database of their own
./test/concurrency.sh 17       # parallel sessions
./test/recovery.sh 17          # crash and restart
./test/bench.sh 17 20 3        # cost, on demand
```

The concurrency and recovery suites exercise the companion when a
Linux binary is available. Build one first:

```bash
GOOS=linux GOARCH=amd64 go build -C companion -o /tmp/volvra-companion .
export VOLVRA_COMPANION_BIN=/tmp/volvra-companion
```

## What done looks like

The plan is complete when the following are all true:

- every suite passes in both privilege contexts on all six versions.
- the privilege matrix asserts both directions for every role and
  function pair.
- every scenario in the priority 6 table has a named assertion or a
  written reason for being out of scope. Satisfied: eleven areas are
  asserted, and three are out of scope with reasons.
- every released schema version has an upgrade fixture and a tested
  path to the current version. There is one released schema, so this
  is satisfied for now and becomes real work at the second release.
- concurrency and recovery suites exist and pass.

## Before starting

Done. The repository is under version control at
`github.com/pgEdge/pgvolvra`, so the restructuring of `test/run.sh`
and everything after it is reviewable and revertable.
