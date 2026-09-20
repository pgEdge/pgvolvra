# Function Reference

This document documents every pgVolvra function, its arguments, and its
result. Functions live in the `volvra` schema.

## Coverage

The functions in this section control which tables pgVolvra records.

### volvra.enable

Starts covering a table. The table must have a primary key. Requires
membership in `volvra_admin`.

The function takes one argument, `target regclass`, and returns a text
confirmation naming the table and its primary key columns.

### volvra.enable_all

Covers every eligible table in a schema. The function is idempotent,
so calling the function again acts as a synchronization pass after a
migration. Requires membership in `volvra_admin`.

The function takes `p_schema text`, defaulting to `public`, and
returns one row per table with the columns `table_name`, `status`, and
`detail`. A table with no primary key reports a status of `skipped`.

### volvra.disable

Stops covering a table and keeps the recorded history. Requires
membership in `volvra_admin`.

The function takes one argument, `target regclass`, and returns a text
confirmation.

### volvra.disable_all

Stops covering every table in a schema. Requires membership in
`volvra_admin`.

The function takes `p_schema text`, defaulting to `public`, and
returns one row per table with the columns `table_name` and `status`.

### volvra.uncovered

Lists the tables in a schema that have no undo. Requires membership in
`volvra_viewer`.

The function takes `p_schema text`, defaulting to `public`, and
returns rows of `table_name` and `reason`. The reason distinguishes a
table never covered from a table with no primary key.

### volvra.exclude_columns

Excludes columns from capture, so the values never reach the history.
Requires membership in `volvra_admin`.

The function takes `target regclass` and `p_columns text[]`, and
returns `table_name`, `excluded`, and `warning`. The warning names any
excluded column that is NOT NULL with no default, because a DELETE on
that table can no longer be undone.

The function raises `invalid_column_reference` for a primary key
column, and `undefined_column` for a column that does not exist.

### volvra.set_capture_mode

Overrides the `capture_updates` setting for one table. Requires
membership in `volvra_admin`.

The function takes `target regclass` and `p_mode text`, which accepts
`changed`, `full`, or NULL. Passing NULL removes the override. The
function raises `invalid_parameter_value` for any other value.

## Undo

The functions in this section preview and apply undos.

### volvra.preview_undo

Returns the plan and executes nothing. Requires membership in
`volvra_viewer` and SELECT privilege on every table the plan touches.

The following table describes each argument:

| Argument | Type | Default | Meaning |
|---|---|---|---|
| target | regclass | NULL | One table to select. |
| from_ts | timestamptz | NULL | Select changes captured after this time. |
| to_ts | timestamptz | NULL | Select changes captured up to this time. |
| txid | bigint | NULL | Select one transaction. |
| actor | text | NULL | Select changes an application declared. |
| db_user | text | NULL | Select changes one authenticated role made. |
| predicate | text | NULL | A SQL boolean over old_row, new_row, pk, actor, db_user, ts, and txid. |
| tables | regclass[] | NULL | Several tables to select. |

At least one argument must be given. The function raises
`null_value_not_allowed` when every argument is NULL.

The function returns rows of the `volvra.undo_step` type. The
following table describes each column:

| Column | Meaning |
|---|---|
| seq | Position in the plan, in reverse chronological order. |
| change_id | Identifier of the captured change. |
| table_name | Table the change belongs to. |
| op | The captured operation. |
| inverse_op | The operation that reverts it. |
| pk | Primary key of the affected row. |
| actor | What the application declared. |
| db_user | The authenticated principal. |
| ts | When pgVolvra captured the change. |
| conflict | True when the live row no longer matches the captured values. |
| status | planned, applied, or skipped. |
| stmt | The exact compensating statement. |

### volvra.undo

Applies the plan when `confirm` is true, and otherwise behaves as a
preview. Requires membership in `volvra_operator` to apply, plus the
caller's own write privileges on the target table.

The function accepts every selector argument `volvra.preview_undo`
accepts, plus the three in the following table:

| Argument | Type | Default | Meaning |
|---|---|---|---|
| confirm | boolean | false | Apply the plan rather than preview it. |
| max_rows | integer | NULL | Override max_undo_rows for this call. |
| skip_conflicts | boolean | false | Revert what still matches and leave changed rows alone. |

The three arguments sit at positions 4, 5, and 6 rather than after the
selector, so the full order is `target`, `from_ts`, `to_ts`,
`confirm`, `max_rows`, `skip_conflicts`, `txid`, `actor`, `db_user`,
`predicate`, `tables`. The positional order therefore differs from
`volvra.preview_undo` past the third argument; use named notation
beyond `to_ts`.

The function raises `serialization_failure` when a row has changed and
`skip_conflicts` is false, `program_limit_exceeded` when the plan
exceeds the cap, `foreign_key_violation` when a constraint blocks the
plan, and `invalid_parameter_value` when the target was never covered.

### volvra.replay

Reapplies each change in a selection in its original direction, oldest
first. Requires membership in `volvra_operator`, and the caller still
needs their own rights on the target table, because the function is
SECURITY INVOKER.

Replay is the mirror of `volvra.undo` and takes the same arguments:
`target`, `from_ts`, `to_ts`, `confirm`, `max_rows`, `skip_conflicts`,
`txid`, `actor`, `db_user`, `predicate`, and `tables`. It returns the
same `volvra.undo_step` rows, where `inverse_op` holds the operation
the step applied, which for a replay is the original operation.

Every statement asserts that the row still holds the image captured
before the change. A row that has moved on is a conflict, and the
whole replay refuses unless `skip_conflicts` is true, in which case
that row is left exactly as it is. There is deliberately no option to
apply a change over a row that does not match, because that is how a
replay would corrupt data.

The function refuses a selection containing a TRUNCATE that was not
captured, applies the blast-radius cap, takes the same advisory locks
as an undo, and runs in one transaction. It records its work in
`volvra.undo_log` with `operation` set to `replay`.

### volvra.preview_replay

Shows what `volvra.replay` would do, and changes nothing. Requires
membership in `volvra_viewer`.

The function takes the same selector arguments as
`volvra.preview_undo` and returns the same columns, including
`conflict`, which marks a row that does not hold the image captured
before its change.

### volvra.undo_txid

Reverts one transaction across every table the transaction touched.
Requires membership in `volvra_operator`.

The function takes `p_txid bigint`, `confirm boolean` defaulting to
false, `max_rows integer` defaulting to NULL, and `skip_conflicts
boolean` defaulting to false.

### volvra.preview_undo_txid

Returns the plan for one transaction and executes nothing. Requires
membership in `volvra_viewer` and SELECT privilege on every table the
plan touches, because the function delegates to
`volvra.preview_undo`.

The function takes `p_txid bigint`.

### volvra.mark

Names a moment you may want to return to. Requires membership in
`volvra_operator`.

The function takes `p_name text`, `p_note text` defaulting to NULL,
and `p_replace boolean` defaulting to false. The function returns the
timestamp recorded.

A duplicate name raises `unique_violation` rather than moving the
existing mark, because a restore point people believe in should not be
relocated silently. Pass `p_replace => true` to move one deliberately.

### volvra.unmark

Removes a mark. Requires membership in `volvra_operator`.

The function takes `p_name text` and returns true when a mark was
removed, false when there was none. Removing a mark removes a pointer;
the history is untouched.

### volvra.marks

Lists every mark with what undoing to it would cost. Requires
membership in `volvra_viewer`.

The function takes no arguments and returns `name`, `at`, `age`,
`created_by`, `changes_since`, `tables_since`, and `note`. The two
counts cover only tables the caller may read, like every other read.

### volvra.undo_to

Undoes everything recorded between a mark and now. Requires the same
privileges as `volvra.undo`, which this function delegates to.

The function takes `p_name text`, then `target regclass`,
`confirm boolean`, `max_rows integer`, `skip_conflicts boolean`, and
`tables regclass[]`, all with the same defaults `volvra.undo` uses. An
unknown mark raises `invalid_parameter_value`.

### volvra.preview_undo_to

Returns the plan for undoing to a mark, and executes nothing. Requires
membership in `volvra_viewer` and SELECT on the tables involved.

The function takes `p_name text`, `target regclass`, and
`tables regclass[]`.

### volvra.make_fks_deferrable

Alters every foreign key in a schema to
`DEFERRABLE INITIALLY IMMEDIATE`, which lets an undo defer the checks
to COMMIT. Requires membership in `volvra_admin`, and takes a brief
ACCESS EXCLUSIVE lock per table.

The function takes `p_schema text`, defaulting to `public`, and
returns `constraint_name`, `table_name`, and `status`.

## History

The functions in this section read what pgVolvra recorded.

### volvra.history

Returns every version of one row, in order. Requires membership in
`volvra_viewer` and SELECT privilege on the table.

The function takes `target regclass` and `pk jsonb`, matching the key
by containment, and returns `change_id`, `ts`, `actor`, `db_user`,
`op`, `txid`, `old_row`, and `new_row`.

### volvra.as_of

Returns a covered table as it stood at a past instant, without changing
anything. Requires membership in `volvra_viewer` and SELECT privilege
on the table.

The function takes `target regclass` and `at_ts timestamptz`, and
returns one `jsonb` object per row. Expand a result with
`jsonb_populate_record` when typed columns are wanted:

```sql
SELECT (jsonb_populate_record(NULL::public.orders, r)).*
FROM volvra.as_of('public.orders', '2026-09-16 15:39') AS r;
```

A row is reconstructed from the current row overlaid with the recorded
values of every change made since `at_ts`. Rows deleted since then
reappear, and rows created since then are absent. The instant is
inclusive: a change recorded at exactly `at_ts` is treated as having
happened.

The function refuses on a table that was never covered, because
returning the table as it stands now and presenting it as the past
would be worse than an error. It warns when a table is registered but
not currently capturing, because changes made while capture was off
cannot be reconstructed.

Columns removed from capture with `volvra.exclude_columns` are
reported at their current values, because their history was never
recorded and cannot be reconstructed. Generated columns are
reconstructed correctly: a stored generated column changes whenever its
source column does, so it is captured along with it.

### volvra.transactions

Groups recent history by transaction, newest first. Requires
membership in `volvra_viewer`.

The function takes `from_ts timestamptz` and `to_ts timestamptz`, both
defaulting to NULL, and `p_limit integer`, defaulting to 25. The
function returns `txid`, `started`, `ended`, `actors`, `db_users`,
`tables`, `inserts`, `updates`, `deletes`, and `changes`.

## Monitoring

The functions in this section report whether pgVolvra is working.

### volvra.status

Reports the live state of every registered table. Requires membership
in `volvra_viewer`.

The function takes no arguments and returns `table_name`, `covered`,
`truncate_covered`, `changes`, `oldest_change`, and `newest_change`.
The two boolean columns read `pg_trigger`, so both report whether the
triggers are attached and enabled.

### volvra.health

Reports problems, and returns no rows when nothing is wrong. Requires
membership in `volvra_viewer`.

The function takes no arguments and returns `severity`, `problem`, and
`detail`. Severity is `critical` or `warning`.

### volvra.preflight

Reports whether the install is shaped for production. Requires
membership in `volvra_viewer`.

The function takes no arguments and returns `severity`, `finding`, and
`detail`. Severity is `critical`, `warning`, or `info`.

### volvra.storage

Reports disk usage per covered table. Requires membership in
`volvra_viewer`.

The function takes no arguments and returns `table_name`,
`table_bytes`, `history_rows`, `history_bytes`, `ratio`, and
`oldest_change`. The history figure apportions the shared history
table by row share, so the figure is an estimate.

### volvra.activity

Reports captured changes over time. Requires membership in
`volvra_viewer`.

The function takes `p_window interval`, defaulting to 24 hours, and
`p_bucket interval`, defaulting to 1 hour. The function returns
`bucket`, `inserts`, `updates`, `deletes`, and `changes`.

### volvra.fingerprint

Hashes the installed code, so the code can be compared against a
published release. Requires membership in `volvra_viewer`.

The function takes no arguments and returns `scope`, `objects`, and
`sha256`. Scope is `functions`, `tables`, `triggers`, or `all`.

### volvra.version

Returns the installed schema version as an integer. The function takes
no arguments and requires no role.

## Retention and maintenance

The functions in this section reclaim history and keep partitions
current.

### volvra.set_retention

Sets a per-table retention policy. Requires membership in
`volvra_admin`.

The function takes `target regclass` and `keep_for interval`, and
returns a text confirmation.

### volvra.purge

Applies the per-table retention policies and the
`retention_default` setting. Requires membership in `volvra_admin`.

The no-argument form returns `table_name`, `keep_for`, and
`rows_removed`, one row per covered table.

### volvra.purge with an interval

Removes everything older than the given interval, whatever the
per-table policies say. Requires membership in `volvra_admin`.

The function takes `older_than interval` and returns `action`,
`object`, and `rows_removed`. The action is `dropped partition` or
`deleted rows`.

### volvra.set_capture_replicated

Turns capture of replicated changes on or off across every covered
table. Requires membership in `volvra_admin`, and ownership of the
covered tables, because it alters their triggers.

The function takes `p_value text`, which must be `on` or `off`, and
returns `table_name` and `captures_replicated` for each covered table.

PostgreSQL does not fire an ordinary `AFTER` trigger for rows applied
by replication, so a node in a multi-master cluster records only what
was written to it. Setting this to `on` makes the capture triggers
`ENABLE ALWAYS`, so each node records its peers' changes as well.

The default is `off`, because an `ENABLE ALWAYS` trigger also fires
when `session_replication_role` is `replica`, which bulk loaders use
to suppress triggers. A table whose owner differs from the caller
produces a warning naming that table rather than failing the whole
call.

### volvra.cover_partitions

Attaches the statement-level TRUNCATE trigger to every partition of a
covered partitioned table that does not already have the trigger.
Requires membership in `volvra_admin`.

PostgreSQL propagates row triggers from a partitioned parent to its
partitions but never statement-level TRUNCATE triggers, so a partition
attached after `volvra.enable` captures INSERT, UPDATE, and DELETE
while a TRUNCATE of that partition alone would destroy rows with no
history. `volvra.enable` calls this function for a partitioned table,
and `volvra.maintain` calls the function on every run to reconcile
partitions added since.

The function takes `target regclass` defaulting to NULL, which
reconciles every covered partitioned table, and returns
`partition_name` and `action`.

### volvra.ensure_partitions

Creates the current month and the requested number of following
months, plus the default partition when absent. Requires membership in
`volvra_admin`.

The function takes `p_months_ahead int`, defaulting to 12, and returns
`partition_name` and `status`.

### volvra.relocate_default

Moves rows out of the default partition into real monthly partitions.
Requires membership in `volvra_admin`.

The function takes no arguments and returns `partition_name` and
`rows_moved`.

### volvra.maintain

Extends partitions, rescues rows from the default partition, applies
retention, seals the history, and reports critical findings. Requires
membership in `volvra_admin`.

The function takes `p_months_ahead int` defaulting to 12,
`p_purge boolean` defaulting to true, and `p_seal boolean` defaulting
to true. The function returns `step`, `detail`, and `affected`.

## Integrity

The functions in this section prove that the history has not been
altered.

### volvra.seal

Hashes everything captured since the last seal and links the result to
the previous seal. Requires membership in `volvra_admin`.

The function takes no arguments and returns `seal_id`, `from_id`,
`to_id`, `row_count`, and `chain_hash`. The function returns no rows
when nothing new has been captured.

A backlog longer than `seal_max_rows` is sealed in batches rather than
refused. The function seals up to the limit, reports through a notice
that more remains, and catches up over successive calls. Sealing
therefore always makes progress, which matters because
`volvra.maintain` calls this function inside a single transaction: a
refusal would abort partition maintenance and retention along with the
seal.

### volvra.verify

Re-hashes every sealed span and re-walks the chain. Requires
membership in `volvra_viewer`.

The function takes no arguments and returns `seal_id`, `from_id`,
`to_id`, `sealed_at`, `rows_sealed`, `rows_found`, `verdict`, `kind`,
and `detail`.

## Erasure

The function in this section answers a deletion request.

### volvra.forget

Removes the row images pgVolvra recorded for one subject. Requires
membership in `volvra_admin`.

The function takes `target regclass`, `subject_pk jsonb`,
`hard boolean` defaulting to false, and `reason text` defaulting to
NULL. The function returns `mode`, `rows_erased`, `from_id`, and
`to_id`.

Redaction is the default and keeps the change record. Hard mode
deletes the history rows outright, for use when the primary key is
itself personal data.

## Configuration

The functions in this section read and change settings.

### volvra.get_setting

Returns one setting value as text. The function takes `p_key text`.

### volvra.set_setting

Sets one setting value. Requires membership in `volvra_admin`. The
function takes `p_key text` and `p_value text`.

## Durable tier

The functions in this section support the companion.

### volvra.companion_setup

Reports the server `wal_level`, sets `REPLICA IDENTITY FULL` on
covered tables in the schema, and rebuilds the publication. Requires
membership in `volvra_admin`.

The function takes `p_schema text` defaulting to `public`, and
`p_publication text` defaulting to NULL. A NULL publication resolves
at run time to the `companion_publication` setting, and then to
`volvra_pub`. The function returns `step`, `object`, and `detail`.

### volvra.companion_status

Reports the durable tier, beginning with the numbers that predict disk
exhaustion, and including a `publication drift` row that counts
covered tables the publication does not carry. Requires membership in
`volvra_viewer`.

The function takes no arguments and returns `item`, `value`, and
`status`.

### volvra.companion_report

Records the companion's progress. The companion calls this function;
operators do not need to. Requires membership in `volvra_viewer`, so
that a companion can connect as an ordinary role rather than as the
schema owner.

The function takes `p_slot text`, `p_lsn pg_lsn`,
`p_segments bigint`, `p_changes bigint`, and `p_uri text` defaulting
to NULL.

### volvra.companion_record_gap

Records history the companion could not archive. The companion calls
this function. Requires membership in `volvra_viewer`, for the same
reason as `volvra.companion_report`.

The function takes `p_slot text`, `p_from pg_lsn`, `p_to pg_lsn`,
`p_reason text`, and `p_detail text` defaulting to NULL, and returns
the new ledger identifier.

## Trigger functions

pgVolvra attaches two trigger functions to each covered table. Neither
is called directly.

The `volvra.capture` function records row-level changes and is
SECURITY DEFINER, granted to no role. The
`volvra.capture_truncate` function handles TRUNCATE according to the
`on_truncate` setting.
