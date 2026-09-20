# Viewing History

This document describes how to read what pgVolvra recorded. Reading
history requires only membership in `volvra_viewer` and the privilege
to read the underlying table.

## The history of one row

`volvra.history` returns every version of a row over time, in order:

```sql
SELECT change_id, ts, actor, db_user, op, old_row, new_row
FROM volvra.history('orders', '{"id":1}');
```

The second argument is the primary key as `jsonb`. pgVolvra matches by
containment, so a composite key can be given in full or in part.

The following table describes each column of the result:

| Column | Contents |
|---|---|
| change_id | Identifier of the captured change. |
| ts | When pgVolvra captured the change. |
| actor | What the application declared it was doing. Spoofable by design. |
| db_user | The authenticated principal. This is the audit column. |
| op | I for insert, U for update, D for delete, T for an uncaptured truncate. |
| old_row | Values before the change, for an update or delete. |
| new_row | Values after the change, for an insert or update. |
| txid | Transaction that made the change. |

An UPDATE stores only the columns whose values changed, so `old_row`
and `new_row` show the difference rather than the whole row. Set
`capture_updates` to `full` if you need complete images.

## The table as it was

`volvra.as_of` reconstructs a covered table at a past instant. It writes
nothing, so it is safe to run while you are still deciding whether to
undo anything:

```sql
SELECT * FROM volvra.as_of('public.orders', '2026-09-16 15:39');
```

Each row comes back as a `jsonb` object. Expand them into typed columns
with `jsonb_populate_record`:

```sql
SELECT (jsonb_populate_record(NULL::public.orders, r)).*
FROM volvra.as_of('public.orders', '2026-09-16 15:39') AS r;
```

Rows deleted since that instant reappear, and rows created since then
are absent. The instant is inclusive: a change recorded at exactly that
timestamp counts as having happened.

Two limits are worth knowing. A table that was never covered is refused
rather than answered, because returning the table as it stands now and
presenting it as the past would be worse than an error. And a column
removed from capture with `volvra.exclude_columns` is reported at its
current value, because no history of it was ever recorded.

## Recent transactions

`volvra.transactions` groups the history by transaction, newest first,
which is how you find a mistaken migration:

```sql
SELECT txid, started, ended, db_users, tables,
       inserts, updates, deletes, changes
FROM volvra.transactions();
```

Limit the result to a time range and a row count:

```sql
SELECT * FROM volvra.transactions(now() - interval '1 day', now(), 50);
```

## Reading the history table directly

The `volvra.change_log` table is readable, and row-level security
restricts each reader to the history of tables that reader may
already SELECT:

```sql
SELECT table_name, op, pk, ts, db_user
FROM volvra.change_log
WHERE table_name = 'public.orders'
ORDER BY id DESC
LIMIT 20;
```

Reading history is never a way around a table's own grants. A reader
who cannot SELECT a table cannot read that table's history either.

## Two identities for every change

pgVolvra records both what the application claimed and who the database
authenticated. The following table compares the two columns:

| Column | Source | Trust |
|---|---|---|
| actor | The volvra.actor setting, or the authenticated principal when the application sets nothing. | Spoofable by design, because only the application knows which of its services acted. |
| db_user | The SET ROLE target if one is active, otherwise session_user. | Authenticated by the database. Use this column for audit. |

Set the actor for a transaction as follows:

```sql
SET LOCAL volvra.actor = 'svc:checkout';
```

## Who changed a row, and when

The following statement answers the common audit question for a single
row:

```sql
SELECT ts, db_user, actor, op,
       old_row -> 'total' AS was,
       new_row -> 'total' AS became
FROM volvra.history('orders', '{"id":1}')
ORDER BY change_id;
```

## Redacted history

An erasure request blanks the row images and leaves the change record
in place, so the fact that a change happened survives. Such rows carry
`redacted_at` and `redacted_by`:

```sql
SELECT id, ts, op, redacted_at, redacted_by
FROM volvra.change_log
WHERE redacted_at IS NOT NULL;
```

See the [Erasing Data](erasure.md) document.

## Next Steps

- The [Undoing Changes](undoing_changes.md) document describes how to
  revert what you find.
- The [Erasing Data](erasure.md) document explains redaction and
  erasure.
- The [Security](security.md) document describes who may read history.
