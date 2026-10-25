# Erasing Data

This document describes how pgVolvra answers a deletion request for one
person, and how to keep data out of the history in the first place.
Retention cannot answer either question.

## Why retention is not enough

Retention answers "forget everything older than a horizon". A subject
access or deletion request names a person, which is a different
question that a time-based policy cannot express.

pgVolvra therefore provides a separate operation that finds every
recorded change for one subject and removes the content.

## Erasing one subject's history

`volvra.forget` removes the row images pgVolvra recorded for a subject:

```sql
SELECT mode, rows_erased, from_id, to_id
FROM volvra.forget('people', '{"id":1}', reason => 'GDPR art.17');
```

Redaction is the default. The change record stays and the content
goes, which keeps the fact that a change happened while removing the
personal data. pgVolvra stamps `redacted_at` and `redacted_by` on each
affected row.

Erasing an unknown subject reports zero rows rather than raising, so
the operation is safe to call from a request-handling workflow.

## Choosing hard erasure

A redacted row still carries its primary key. When the primary key is
itself personal data, such as an email address, redaction is not
enough:

```sql
SELECT mode, rows_erased
FROM volvra.forget('subscribers', '{"email":"ada@example.com"}',
                   hard => true, reason => 'GDPR art.17');
```

Hard mode deletes the history rows outright. The following table
compares the two modes:

| Mode | Row images | Change record | Use when |
|---|---|---|---|
| redact | Removed | Retained, marked redacted | The primary key is not personal data. |
| hard | Removed | Removed | The primary key is itself personal data. |

## Erasure is auditable

pgVolvra records every erasure request in `volvra.erasure_log`, before
making the change:

```sql
SELECT at, by_user, table_name, subject_pk, mode,
       rows_erased, reason
FROM volvra.erasure_log ORDER BY id DESC;
```

The ledger is what lets `volvra.verify` distinguish a lawful erasure
from tampering. Re-seal after an erasure to restore provable coverage.

## Erasure cannot rewrite history

The path that erasure uses is deliberately narrow. pgVolvra permits an
update to the history only when the update removes content, and
rejects any update that:

- changes the recorded `db_user` or `actor` attribution.
- changes the operation, the primary key, the transaction identifier,
  or the timestamp.
- substitutes different content instead of setting the images to null.

Erasure therefore cannot become a way to make the history say
something that did not happen.

## Keeping data out of the history

Some columns must never be copied into a second table, whatever the
recovery cost. Exclude such a column from capture:

```sql
SELECT table_name, excluded, warning
FROM volvra.exclude_columns('cards', ARRAY['pan']);
```

An excluded column never reaches the history, and an update confined
to excluded columns records nothing at all, so not even the fact of
the change is stored.

The cost is stated when you make the change rather than discovered
later. pgVolvra cannot restore a column pgVolvra never captured, and if
the column is NOT NULL with no default then undoing a DELETE on that
table becomes impossible. pgVolvra warns at that moment, and a later
undo refuses with `datatype_mismatch` rather than inserting a row with
a wrong value.

pgVolvra refuses to exclude a primary key column. Use hard erasure when
the key itself is the problem.

## Choosing between exclusion and erasure

The following table compares the two approaches:

| Approach | When | Effect on undo |
|---|---|---|
| exclude_columns | The data must never be recorded at all. | That column can never be restored. |
| forget | The data was recorded and must now be removed. | Changes for that subject can no longer be undone. |


## Erasure and an immutable archive

`volvra.forget` erases history in this database. If the companion
archives to object storage under an S3 Object Lock retention, the
archived copy of the same rows cannot be deleted or overwritten while
that retention stands, and under compliance mode it cannot be erased by
anyone, including the account root.

pgVolvra raises a warning from `volvra.forget` whenever a lock is in
force, naming the archive and the retention, and `volvra.preflight`
reports the same condition. Treat an erasure request as only partly
satisfied until the archived copy is also dealt with.

The Where the Archive Is Stored document describes the setting and the
trade it involves.

## Next Steps

- The [Verifying History Integrity](integrity.md) document explains
  how erasure is distinguished from tampering.
- The [Managing Retention](retention.md) document covers time-based
  removal.
- The [Security](security.md) document describes who may erase.
