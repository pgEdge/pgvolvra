# pgVolvra

pgVolvra is row-level undo and history for PostgreSQL. pgVolvra reverts the
exact rows changed by a mistaken UPDATE, DELETE, or migration, rather
than rolling an entire cluster back to a point in time.

PostgreSQL has no equivalent of Oracle Flashback. Recovering from a
mistaken statement normally means restoring a backup or performing
point-in-time recovery, which discards every other change made since.
pgVolvra reverts only the rows the mistake touched, and leaves unrelated
work in place.

pgVolvra installs as plain SQL. pgVolvra requires no compiled extension,
no superuser, and no access to the database server filesystem, which
is what managed providers withhold. pgVolvra is verified on
Supabase and on Neon, where verification runs pass on the free plan,
and is designed for Amazon RDS, Amazon Aurora, and Google Cloud SQL on
the same basis. The
[Managed Providers](managed_providers.md) document records what has
been verified on which service, and how to verify the rest.

pgVolvra includes the following features:

- reverting an UPDATE, DELETE, or INSERT on specific rows.
- reverting an entire transaction, such as a mistaken migration,
  across every table the transaction touched.
- viewing every version of a row over time, with the actor and
  timestamp for each change.
- reading a whole table as it stood at a past instant, without
  changing anything.
- refusing to overwrite a change made after the mistake, rather than
  silently destroying it.
- capping the number of rows a single undo may affect.
- proving that the recorded history has not been altered.
- erasing one subject's history in response to a deletion request.
- archiving change data to storage you own, so the history survives
  the loss of the database.

## An important constraint

pgVolvra records changes from the moment you enable pgVolvra on a table.
pgVolvra cannot recover a change made before that point, because no
record of the change exists. Setup is therefore the whole job; see the
[Getting Started](quick_start.md) document.

## Two tiers

pgVolvra has two capture tiers that solve different problems. The
following table compares the two tiers:

| Property | Trigger tier | Companion |
|---|---|---|
| Mechanism | Row triggers writing to a table in the same database | External process reading a logical replication slot |
| Storage | Inside the database | Files in storage you own |
| Timing | Synchronous, in the writing transaction | Asynchronous |
| Survives loss of the database | No | Yes |
| Requires wal_level = logical | No | Yes |
| Requires REPLICA IDENTITY FULL | No | Yes |
| Recovers a TRUNCATE | Yes, by default | No |
| Installs with no superuser | Yes | Yes |

The trigger tier is the everyday undo. The companion is the durable
copy. Most deployments use the trigger tier alone; add the companion
when the history must outlive the database.

## Requirements

pgVolvra requires PostgreSQL 14 or later. pgVolvra requires no PostgreSQL
extensions; the `plpgsql` language that pgVolvra uses ships enabled in
every PostgreSQL installation.

pgVolvra is tested against PostgreSQL 14, 15, 16, 17, 18, and 19.

## Next Steps

- The [Getting Started](quick_start.md) document walks through
  installing pgVolvra and reverting a mistake.
- The [Architecture](architecture.md) document explains how pgVolvra
  captures and reverts changes.
- The [Installation](installation.md) document describes every
  supported installation method.
- The [Security](security.md) document describes the privilege model
  and the guarantees pgVolvra does and does not provide.
