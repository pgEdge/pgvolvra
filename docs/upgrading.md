# Upgrading pgVolvra

This document describes how pgVolvra upgrades an existing install. The
install file is a migration runner, so upgrading pgVolvra is the same
command as installing pgVolvra.

## Running an upgrade

Run the install file again against the same database:

```bash
psql "$DATABASE_URL" -f sql/volvra.sql
```

pgVolvra reads the version the database already has, applies only the
migrations the database is missing, and records each one. Running the
file twice changes nothing the second time.

## The version ledger

pgVolvra records every applied migration in `volvra.schema_version`:

```sql
SELECT version, applied_at, applied_by, note
FROM volvra.schema_version ORDER BY version;
```

The output shows the schema versions this database has been through:

```
 version |      note
---------+----------------
       1 | initial schema
```

Read the current version with `volvra.version()`. There is one schema
version today, because pgVolvra has not been released yet; a released
version numbers its migrations from 2 onwards. The ledger has no gaps,
so a missing number always means a migration that did not run rather
than an install that skipped ahead.

The number is internal. pgVolvra reports it as the internal schema
version deliberately, so nobody reads it as a release number; the
release number is separate and lives in `extension/volvra.control`.

## Migrations are forward only

pgVolvra provides no down migrations. History is the product, and a
downgrade that reshaped the history table would risk destroying the
history pgVolvra exists to hold.

Each release adds numbered migrations from where the previous release
left off, and never reshapes what an existing version already holds.
The install applies only the migrations a database is missing, which is
what makes reinstalling the current script over live history safe.

pgVolvra 1.0.0-beta1 is the first release, so it ships one schema
version. The
blocks that repaired databases created during pgVolvra's development
were removed at that release; they existed only because development
changed the shape of the history table several times without releasing
any of it.

## Version numbers

pgVolvra maintains two separate counters. The following table describes
each counter:

| Counter | Meaning |
|---|---|
| volvra.schema_version | Internal migration counter. The counter increments whenever the on-disk shape changes. |
| Product version | A release decision, recorded in extension/volvra.control. |

The two counters are deliberately independent. Coupling the counters
would let an internal refactor look like a product release.

## Upgrading an extension install

A database installed with `CREATE EXTENSION` upgrades through
`ALTER EXTENSION`, not by running the install script:

```sql
ALTER EXTENSION volvra UPDATE;
```

Do not run `sql/volvra.sql` against an extension install. The script
migrates the schema correctly, but PostgreSQL still records the old
extension version, and a later dump and restore then emits
`CREATE EXTENSION volvra` at that stale version and loses the changes.

`ALTER EXTENSION UPDATE` needs an upgrade script named for the version
being left behind. The packaging build produces one for every released
version, taking the list from the release snapshots in
`test/releases/`, so a released version always has a path forward.

Confirm which version PostgreSQL believes is installed:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'volvra';
```

## Verifying an upgrade

Confirm the version and the installed code after an upgrade:

```sql
SELECT volvra.version();
SELECT sha256 FROM volvra.fingerprint() WHERE scope = 'all';
```

Compare the fingerprint against the value published with the release.

## Next Steps

- The [Installation](installation.md) document describes every
  supported installation method.
- The [Verifying History Integrity](integrity.md) document explains
  the fingerprint and the seal chain.
