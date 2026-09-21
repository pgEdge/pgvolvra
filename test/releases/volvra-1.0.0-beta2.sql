-- =====================================================================
-- pgVolvra 1.0.0-beta2 -- FROZEN RELEASE SNAPSHOT. Do not edit.
--
-- Captured from sql/volvra.sql by tools/snapshot-schema.sh at release
-- time. Its only purpose is to let a later release prove that
-- upgrading from 1.0.0-beta2 preserves history and leaves a working
-- engine behind. Editing it makes that proof a fiction.
--
-- If 1.0.0-beta2 had a bug, the snapshot keeps the bug. That is correct:
-- the databases being upgraded have it too.
-- =====================================================================
-- =====================================================================
-- pgVolvra — undo for Postgres (v0, trigger tier)
--
-- Pure SQL / PL/pgSQL. No C, no superuser, no server filesystem access.
-- Tested on PostgreSQL 14 .. 19 (see test/run.sh).
--
-- Install:  psql -f sql/volvra.sql
--           ...or paste this file into any SQL client, including a managed
--           provider's browser console. It is one self-contained transaction.
-- =====================================================================

-- Wrapped in one transaction rather than relying on psql's ON_ERROR_STOP, so
-- that a failed install leaves nothing behind whatever client you run it from
-- -- including a provider's browser SQL console.  This file is pure SQL: no
-- psql meta-commands, no shell, no server filesystem access.
--
-- (extension/build.sh strips the two lines marked volvra:tx, because an
-- extension script may not contain transaction control.)
BEGIN;  -- volvra:tx

-- A clean install should print almost nothing.  The idempotent DDL below is
-- full of DROP IF EXISTS and CREATE IF NOT EXISTS, each of which emits a
-- NOTICE, and dozens of "does not exist, skipping" lines on a first install
-- read as failure when they mean the opposite.  WARNING and ERROR still show,
-- and the summary at the end of this file reports what was actually applied.
SET LOCAL client_min_messages = warning;

-- Whether this database already had volvra, recorded before anything is
-- created, so the summary at the end can tell a first install from an upgrade.
-- change_log is the indicator, not schema_version: an install predating the
-- ledger has the former and not the latter, and is still an upgrade.
CREATE TEMP TABLE volvra_install_state AS
  SELECT to_regclass('volvra.change_log') IS NOT NULL AS pre_existing;

CREATE SCHEMA IF NOT EXISTS volvra;

-- Signatures that changed shape across versions must be dropped, not replaced.
DROP FUNCTION IF EXISTS volvra.set_setting(text, text);
DROP FUNCTION IF EXISTS volvra.get_setting(text);
DROP FUNCTION IF EXISTS volvra.history(regclass, jsonb);
DROP FUNCTION IF EXISTS volvra.undo(regclass, timestamptz, timestamptz, boolean, integer);
DROP FUNCTION IF EXISTS volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean);
DROP FUNCTION IF EXISTS volvra.preview_undo(regclass, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS volvra._plan(regclass, timestamptz, timestamptz, boolean, boolean);
DROP FUNCTION IF EXISTS volvra.purge(interval);
DROP FUNCTION IF EXISTS volvra.verify();
-- renamed in v5: "armed" was jargon, and borrowed a connotation the product
-- does not want.  A table is covered or it is not.
DROP FUNCTION IF EXISTS volvra.status();
DROP FUNCTION IF EXISTS volvra.unarmed(text);
-- CASCADE: _plan, preview_undo and undo all return this type.
DROP TYPE IF EXISTS volvra.undo_step CASCADE;

-- One row of an undo plan: the change that happened, and the statement that
-- would put it back.
CREATE TYPE volvra.undo_step AS (
  seq         bigint,
  change_id   bigint,
  table_name  text,
  op          char(1),
  inverse_op  char(1),
  pk          jsonb,
  actor       text,
  db_user     text,
  ts          timestamptz,
  conflict    boolean,   -- the live row no longer matches what was captured
  status      text,      -- planned / applied / skipped
  stmt        text
);

COMMENT ON SCHEMA volvra IS
  'pgVolvra: row-level undo / time machine for PostgreSQL (trigger capture tier).';

-- ---------------------------------------------------------------------
-- Roles
--
-- Created only if the installing role has CREATEROLE (or is superuser).
-- If they cannot be created, the privilege checks below degrade to
-- "unrestricted" and a WARNING is emitted -- acceptable for a laptop
-- install, NOT acceptable for production.
-- ---------------------------------------------------------------------
DO $bootstrap$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['volvra_viewer','volvra_operator','volvra_admin'] LOOP
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE WARNING 'volvra: cannot create role % (no CREATEROLE); '
                    'privilege checks will be permissive -- set strict_roles=on '
                    'once the roles exist', r;
    END;
  END LOOP;
END
$bootstrap$;

-- Roles are cluster-wide, so on a second database in the same cluster they may
-- already exist and be administered by someone else.  Each grant therefore
-- stands on its own: one failure must not silently abandon the rest.
DO $hierarchy$
DECLARE
  g text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_admin') THEN
    RETURN;
  END IF;
  FOREACH g IN ARRAY ARRAY[
    'GRANT volvra_viewer TO volvra_operator',
    'GRANT volvra_operator TO volvra_admin',
    -- The installing role administers what it just installed.  Without this a
    -- non-superuser owner would create the roles and then be locked out of its
    -- own enable()/set_setting() -- superusers never notice, because
    -- pg_has_role always says yes for them.
    format('GRANT volvra_admin TO %I', current_user)
  ] LOOP
    BEGIN
      EXECUTE g;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'volvra: "%" failed: % -- grant it by hand as a role that '
                    'administers volvra_admin', g, SQLERRM;
    END;
  END LOOP;
END
$hierarchy$;

-- ---------------------------------------------------------------------
-- Schema version
--
-- Once a database holds history someone cares about, a reinstall that reshapes
-- a table is data loss.  So the install script is a migration runner: it reads
-- where this database is, applies only the steps it is missing, and records
-- them.  Forward only -- there is no down migration for history.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS volvra.schema_version (
  version    int PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now(),
  applied_by text        NOT NULL DEFAULT current_user,
  note       text
);

-- Release 1 ships one schema version: 1.  A second release adds a numbered
-- migration from 2 onwards, guarded by volvra._at_least(), and never reshapes
-- what an existing version already holds -- once a database carries history
-- someone cares about, a reinstall that reshapes a table is data loss.
--
-- The blocks that repaired databases created during development are gone as of
-- release 1.  They existed because development changed the shape of change_log
-- several times without releasing any of it; there is nothing left to repair.

CREATE OR REPLACE FUNCTION volvra.version() RETURNS int
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT coalesce(max(version), 0) FROM volvra.schema_version $$;

CREATE OR REPLACE FUNCTION volvra._at_least(v int) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT EXISTS (SELECT 1 FROM volvra.schema_version WHERE version >= v) $$;

-- ---------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------
-- The id sequence is standalone rather than owned by the column: a partitioned
-- table is built and rebuilt around it, and the ids must survive that.
CREATE SEQUENCE IF NOT EXISTS volvra.change_log_id_seq AS bigint;

-- Fresh install: partitioned from the start.  Range-partitioned by ts, monthly,
-- so retention is DROP TABLE rather than a mass DELETE through a guard trigger.
-- The primary key must carry the partition key, hence (id, ts).
DO $create_log$
BEGIN
  IF to_regclass('volvra.change_log') IS NULL THEN
    CREATE TABLE volvra.change_log (
      id          bigint      NOT NULL DEFAULT nextval('volvra.change_log_id_seq'),
      table_name  text        NOT NULL,          -- quoted, schema-qualified
      -- I/U/D are row images.  T marks a TRUNCATE whose rows were NOT
      -- captured: a hole in the history undo must refuse to step over.
      op          char(1)     NOT NULL CHECK (op IN ('I','U','D','T')),
      pk          jsonb       NOT NULL,
      old_row     jsonb,
      new_row     jsonb,
      actor       text        NOT NULL,   -- app-declared; SPOOFABLE by design
      db_user     text        NOT NULL DEFAULT session_user,  -- authoritative
      txid        bigint      NOT NULL,
      ts          timestamptz NOT NULL DEFAULT clock_timestamp(),
      -- set by volvra.forget(); the change survives, its content does not
      redacted_at timestamptz,
      redacted_by text,
      PRIMARY KEY (id, ts)
    ) PARTITION BY RANGE (ts);

    INSERT INTO volvra.schema_version (version, note)
    VALUES (1, 'initial schema')
    ON CONFLICT (version) DO NOTHING;
  END IF;
END
$create_log$;

COMMENT ON TABLE volvra.change_log IS
  'Append-only before/after images, range-partitioned by month. '
  'UPDATE and DELETE are blocked by a guard trigger.';

-- Tables currently under capture
CREATE TABLE IF NOT EXISTS volvra.enabled_tables (
  table_name       text PRIMARY KEY,
  pk_columns       text[]      NOT NULL,
  -- Columns never written to the history.  For data you are not allowed to
  -- keep a second copy of -- at the cost of not being able to restore it.
  excluded_columns text[]      NOT NULL DEFAULT '{}',
  -- NULL means "use the capture_updates setting".  Per table because the
  -- trade-off flips with row width: storing only the delta is a large saving on
  -- a wide row and a small tax on a narrow one.
  update_mode      text,
  -- The relation's OID, which survives ALTER TABLE ... RENAME and SET SCHEMA
  -- while table_name does not.  Without it, renaming a covered table left the
  -- ledger naming a table that no longer existed, and every subsequent write
  -- failed with "not registered" -- the rename made the table unusable.
  -- Nullable because a row may predate the column, and because a name that
  -- currently resolves to nothing still has history worth keeping.
  rel_oid          oid,
  enabled_at       timestamptz NOT NULL DEFAULT now(),
  enabled_by       text        NOT NULL DEFAULT current_user
);

ALTER TABLE volvra.enabled_tables
  ADD COLUMN IF NOT EXISTS excluded_columns text[] NOT NULL DEFAULT '{}';
ALTER TABLE volvra.enabled_tables
  ADD COLUMN IF NOT EXISTS update_mode text;
ALTER TABLE volvra.enabled_tables
  ADD COLUMN IF NOT EXISTS rel_oid oid;

-- Backfill for databases covered before rel_oid existed.  A catalog join
-- rather than volvra._resolve(), because the functions are not created yet at
-- this point in the install.  A name that matches nothing is left NULL: it has
-- history worth keeping and no relation to point at.
UPDATE volvra.enabled_tables e
   SET rel_oid = c.oid
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE e.rel_oid IS NULL
   AND e.table_name = format('%I.%I', n.nspname, c.relname);

-- Audit of every undo attempt, previewed or applied
CREATE TABLE IF NOT EXISTS volvra.undo_log (
  id          bigserial PRIMARY KEY,
  ts          timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor       text        NOT NULL,
  table_name  text        NOT NULL,
  from_ts     timestamptz,
  to_ts       timestamptz,
  db_user     text        NOT NULL DEFAULT current_user,
  row_count   bigint      NOT NULL,
  confirmed   boolean     NOT NULL,
  cap         bigint,
  cap_override boolean    NOT NULL DEFAULT false,
  -- 'undo' reverses changes; 'replay' reapplies them forward.  Both write
  -- here, because both change data and an auditor needs to tell them apart.
  operation   text        NOT NULL DEFAULT 'undo'
                          CHECK (operation IN ('undo', 'replay')),
  txid        bigint      NOT NULL DEFAULT txid_current()
);

ALTER TABLE volvra.undo_log
  ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'undo';

-- ---------------------------------------------------------------------
-- Tamper evidence (v3)
--
-- The history is tamper-*resistant* on its own: writes are blocked and the
-- guard applies to the owner too.  That is not the same as being able to
-- *prove* nothing was altered.
--
-- Chaining every row would mean serialising on the tail of the log, which would
-- undo everything phase 3 measured.  So the chain is over *ranges*: sealing is
-- a periodic, off-the-write-path operation that hashes a span of the log and
-- links it to the previous seal.  Anything altered or removed inside a sealed
-- span is detectable; changes after the last seal are not yet covered, and
-- volvra.health() says how wide that window is.
CREATE TABLE IF NOT EXISTS volvra.seal (
  id           bigserial PRIMARY KEY,
  sealed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  sealed_by    text        NOT NULL DEFAULT current_user,
  from_id      bigint      NOT NULL,      -- inclusive
  to_id        bigint      NOT NULL,      -- inclusive
  row_count    bigint      NOT NULL,
  content_hash text        NOT NULL,      -- over the rows in the span
  prev_hash    text,                      -- previous seal's chain_hash
  chain_hash   text        NOT NULL       -- binds this seal to the whole chain
);

CREATE INDEX IF NOT EXISTS seal_range_idx ON volvra.seal (from_id, to_id);

-- Legitimate reasons a sealed span no longer matches: retention dropped it, or
-- a subject exercised their right to erasure.  Both are recorded so that
-- verify() can tell a lawful gap from an unexplained one.
CREATE TABLE IF NOT EXISTS volvra.retention_log (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  by_user     text        NOT NULL DEFAULT current_user,
  cutoff      timestamptz,
  scope       text        NOT NULL,       -- 'partition' | 'rows'
  object      text,
  from_id     bigint,
  to_id       bigint,
  rows_removed bigint     NOT NULL
);

CREATE TABLE IF NOT EXISTS volvra.erasure_log (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  by_user     text        NOT NULL DEFAULT current_user,
  table_name  text        NOT NULL,
  subject_pk  jsonb       NOT NULL,
  mode        text        NOT NULL,       -- 'redact' | 'hard'
  from_id     bigint,
  to_id       bigint,
  rows_erased bigint      NOT NULL,
  reason      text
);

-- ---------------------------------------------------------------------
-- The durable tier (v6)
--
-- The trigger tier shares fate with the database: it is an oops button, not a
-- backup.  The companion is a separate process that reads a logical
-- replication slot and writes change data to storage the customer owns, so the
-- history survives the database dying.
--
-- These tables are the database's half of that: where the companion reports
-- its progress, and where gaps are recorded.  The archive itself is
-- self-describing and readable without any of this.
CREATE TABLE IF NOT EXISTS volvra.companion_checkpoint (
  slot_name     text PRIMARY KEY,
  archived_lsn  pg_lsn      NOT NULL,
  archived_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  segments      bigint      NOT NULL DEFAULT 0,
  changes       bigint      NOT NULL DEFAULT 0,
  archive_uri   text
);

-- A gap is history the companion could not archive.  Recorded rather than
-- silent, for the same reason retention and erasure are: an unexplained hole
-- must be distinguishable from a lawful one.
CREATE TABLE IF NOT EXISTS volvra.companion_gap (
  id         bigserial PRIMARY KEY,
  slot_name  text        NOT NULL,
  at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  from_lsn   pg_lsn,
  to_lsn     pg_lsn,
  reason     text        NOT NULL,
  detail     text
);

-- ---------------------------------------------------------------------
-- Restore points
--
-- A mark is a named moment, and undoing to a mark is undoing from that moment
-- to now.  The mechanism was always available -- from_ts is just a timestamp --
-- but hand-rolling it means writing the window by hand, and a window that
-- reaches back further than intended is the easiest way to revert more than
-- you meant to.  Naming the moment makes the safe version the easy one.
CREATE TABLE IF NOT EXISTS volvra.restore_point (
  name       text PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by text        NOT NULL DEFAULT current_user,
  note       text
);

-- Per-table retention.  A global default lives in settings as
-- retention_default; a row here overrides it for one table.
CREATE TABLE IF NOT EXISTS volvra.retention (
  table_name text PRIMARY KEY,
  keep_for   interval NOT NULL,
  set_at     timestamptz NOT NULL DEFAULT now(),
  set_by     text NOT NULL DEFAULT current_user
);

-- Configuration
CREATE TABLE IF NOT EXISTS volvra.settings (
  key   text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO volvra.settings(key, value) VALUES
  ('max_undo_rows', '10000'),
  -- 'on' => a missing volvra_* role is a hard error instead of a permissive
  --         no-op.  Turn this on for any deployment that matters.
  ('strict_roles',  'off'),
  -- What to do when a captured table is TRUNCATEd.  Row triggers do not fire on
  -- TRUNCATE, so the default is to capture every row first: silently losing a
  -- whole table is the one accident this tool must never miss.
  --   capture -- write a delete image per row, then allow the truncate
  --   block   -- refuse the truncate outright
  --   allow   -- let it through, recording only a T marker (history gap)
  ('on_truncate', 'capture'),
  -- Above this many rows, 'capture' refuses rather than quietly writing a copy
  -- of the whole table into the history.
  ('truncate_capture_max_rows', '100000'),
  -- How long history is kept when a table has no row in volvra.retention.
  -- Nothing is deleted until purge() is actually run -- volvra will not quietly
  -- discard the history it exists to hold.
  ('retention_default', '90 days'),
  -- What an UPDATE stores.
  --   changed -- only the columns whose value actually differs (default)
  --   full    -- complete before and after images, for audit regimes that
  --              require the whole row on every write
  ('capture_updates', 'changed'),
  -- 'on' records an UPDATE that changed nothing.  Off by default: ORMs that
  -- write every column on every save generate a great many of these, and an
  -- update with an identity inverse is not history anyone can use.
  ('capture_no_op_updates', 'off'),
  -- The largest span volvra.seal() will hash in one call.  Sealing walks the
  -- span row by row, so this bounds how long one seal can take.  A longer
  -- backlog is sealed in batches over successive calls, never refused: see
  -- volvra.seal().
  ('seal_max_rows', '1000000'),
  -- Name of the logical replication slot the companion reads.
  ('companion_slot', 'volvra_companion'),
  -- Publication the companion subscribes to.  pgoutput is the only decoding
  -- plugin built into Postgres, and therefore the only one available on
  -- managed providers -- which is why the companion speaks it rather than
  -- wal2json.
  ('companion_publication', 'volvra_pub'),
  -- Retained WAL at which the slot becomes a threat to the database rather
  -- than a safety net.  See volvra.companion_status().
  ('companion_lag_warn_bytes', '536870912'),      -- 512 MB
  ('companion_lag_max_bytes',  '5368709120'),     -- 5 GB
  -- Whether capture also records changes that arrive through replication.
  --
  --   off  (default)  ordinary triggers.  A node records what was written to
  --                   it and not what its peers sent.  On a single node there
  --                   is nothing else to record, so this is complete.
  --   on              ENABLE ALWAYS triggers.  Every node records every
  --                   change, its own and its peers'.  Needed for a multi-
  --                   master cluster to have usable history on each node.
  --
  -- Off by default because ENABLE ALWAYS also makes a trigger fire when
  -- session_replication_role is 'replica', which is how bulk loaders and
  -- migration tools suppress triggers.  Turning it on unconditionally would
  -- change behaviour for single-node users who rely on that.
  ('capture_replicated',       'off'),

  -- warn_changed_rows: raise a WARNING when one statement changes more rows
  -- than this on a covered table.  0 disables it.
  --
  -- volvra is otherwise entirely retrospective: it tells you what happened
  -- once you already know something is wrong.  This is the one place it can
  -- speak at the moment of the mistake, which is the difference between
  -- noticing a missing WHERE clause at 15:40 and at 16:10.
  --
  -- Off by default, and deliberately not merely inert when off: the statement
  -- triggers that implement it are attached only while it is on, so a user who
  -- does not want the feature pays nothing for it.  Use
  -- volvra.set_warn_changed_rows() to turn it on, which syncs the triggers.
  ('warn_changed_rows',        '0')
  ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Partitions
--
-- Monthly range partitions, plus a DEFAULT partition that exists purely as a
-- safety net: if a month is somehow missing, a capture must never fail, because
-- a failed capture fails the application's own write.  Rows landing in DEFAULT
-- are reported by volvra.health() and relocated by volvra.relocate_default().
--
-- These are SECURITY DEFINER so that a volvra_admin who does not own the schema
-- can still run retention; the admin check is inside.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._partition_name(p_month date) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT 'change_log_' || to_char(p_month, '"y"YYYY"m"MM') $$;

CREATE OR REPLACE FUNCTION volvra._create_partition(p_month date) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_name  text := volvra._partition_name(p_month);
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
BEGIN
  IF to_regclass('volvra.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN 'exists';
  END IF;

  EXECUTE format(
    'CREATE TABLE volvra.%I PARTITION OF volvra.change_log FOR VALUES FROM (%L) TO (%L)',
    v_name, v_start, v_end);

  -- Partitions do not inherit the parent's grants, and anything reading a
  -- partition by name needs its own SELECT.  Granting here is the only way
  -- this cannot drift as months are added.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    EXECUTE format('GRANT SELECT ON volvra.%I TO volvra_viewer', v_name);
  END IF;

  RETURN 'created';
EXCEPTION
  -- Postgres refuses to create a partition whose range already has rows sitting
  -- in DEFAULT.  That is recoverable, but only deliberately.
  WHEN check_violation OR invalid_table_definition THEN
    RETURN 'blocked by rows in the default partition: run volvra.relocate_default()';
END
$$;

-- Create this month and the next p_months_ahead.  Idempotent, so it is safe to
-- schedule; call it monthly (pg_cron, or whatever your provider gives you).
CREATE OR REPLACE FUNCTION volvra.ensure_partitions(p_months_ahead int DEFAULT 12)
RETURNS TABLE (partition_name text, status text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  m date;
BEGIN
  PERFORM volvra._require('volvra_admin');

  -- The default partition must exist before any month does, or a capture during
  -- a gap would fail the application's write.
  IF to_regclass('volvra.change_log_default') IS NULL THEN
    EXECUTE 'CREATE TABLE volvra.change_log_default '
            'PARTITION OF volvra.change_log DEFAULT';
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
      EXECUTE 'GRANT SELECT ON volvra.change_log_default TO volvra_viewer';
    END IF;
    partition_name := 'change_log_default';
    status := 'created';
    RETURN NEXT;
  END IF;

  FOR m IN
    SELECT (date_trunc('month', now()) + (n || ' months')::interval)::date
    FROM generate_series(0, greatest(p_months_ahead, 0)) AS n
  LOOP
    partition_name := volvra._partition_name(m);
    status := volvra._create_partition(m);
    RETURN NEXT;
  END LOOP;
END
$$;

-- Move anything that landed in DEFAULT into a real month partition.  Detaching
-- first is what makes the moves legal: while DEFAULT is attached, Postgres will
-- not let the new month be created underneath it.
CREATE OR REPLACE FUNCTION volvra.relocate_default()
RETURNS TABLE (partition_name text, rows_moved bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  m      date;
  v_rows bigint;
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF to_regclass('volvra.change_log_default') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM volvra.change_log_default) THEN
    RETURN;
  END IF;

  ALTER TABLE volvra.change_log DETACH PARTITION volvra.change_log_default;

  -- The guard trigger is cloned onto every partition; the detached table is
  -- ours alone for the duration, and it is dropped at the end regardless.
  DROP TRIGGER IF EXISTS volvra_append_only ON volvra.change_log_default;

  FOR m IN
    SELECT DISTINCT date_trunc('month', ts)::date
    FROM volvra.change_log_default ORDER BY 1
  LOOP
    PERFORM volvra._create_partition(m);
  END LOOP;

  INSERT INTO volvra.change_log
    (id, table_name, op, pk, old_row, new_row, actor, db_user, txid, ts)
  SELECT id, table_name, op, pk, old_row, new_row, actor, db_user, txid, ts
  FROM volvra.change_log_default;

  SELECT count(*) INTO v_rows FROM volvra.change_log_default;

  DROP TABLE volvra.change_log_default;
  EXECUTE 'CREATE TABLE volvra.change_log_default '
          'PARTITION OF volvra.change_log DEFAULT';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    EXECUTE 'GRANT SELECT ON volvra.change_log_default TO volvra_viewer';
  END IF;

  partition_name := 'change_log_default';
  rows_moved     := v_rows;
  RETURN NEXT;
END
$$;

-- Indexes live on the parent, so every partition inherits them.
CREATE INDEX IF NOT EXISTS change_log_table_ts_idx
  ON volvra.change_log (table_name, ts);
CREATE INDEX IF NOT EXISTS change_log_pk_idx
  ON volvra.change_log USING gin (pk jsonb_path_ops);
CREATE INDEX IF NOT EXISTS change_log_txid_idx
  ON volvra.change_log (txid);

-- Partitions have to exist before the first capture, not on a schedule: a
-- capture that cannot find a partition fails the application's own write.
-- DEFAULT is created first and is the reason that can never happen.
DO $seed_partitions$
DECLARE
  m date;
BEGIN
  IF to_regclass('volvra.change_log_default') IS NULL THEN
    EXECUTE 'CREATE TABLE volvra.change_log_default '
            'PARTITION OF volvra.change_log DEFAULT';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    EXECUTE 'GRANT SELECT ON volvra.change_log_default TO volvra_viewer';
  END IF;

  FOR m IN
    SELECT (date_trunc('month', now()) + (n || ' months')::interval)::date
    FROM generate_series(0, 12) AS n
  LOOP
    PERFORM volvra._create_partition(m);
  END LOOP;
END
$seed_partitions$;

-- ---------------------------------------------------------------------
-- Append-only guard
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._guard_append_only() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- The only legitimate ways past this guard are volvra.purge() and
  -- volvra.forget(), which open a transaction-local window.  The GUC alone is
  -- NOT sufficient -- any role can SET it -- so membership in volvra_admin is
  -- required as well.
  IF coalesce(current_setting('volvra.allow_purge', true), 'off') = 'on'
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_admin')
     AND pg_has_role(current_user, 'volvra_admin', 'USAGE')
  THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;

    -- An UPDATE is only ever allowed to *remove* content: erasure redacts, it
    -- never rewrites history into something that did not happen.
    IF TG_OP = 'UPDATE'
       AND NEW.id         = OLD.id
       AND NEW.table_name = OLD.table_name
       AND NEW.op         = OLD.op
       AND NEW.pk         = OLD.pk
       AND NEW.txid       = OLD.txid
       AND NEW.ts         = OLD.ts
       AND NEW.db_user    = OLD.db_user
       AND NEW.old_row    IS NULL
       AND NEW.new_row    IS NULL
       AND NEW.redacted_at IS NOT NULL
    THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'volvra.% is append-only (attempted %)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

DROP TRIGGER IF EXISTS volvra_append_only ON volvra.change_log;
CREATE TRIGGER volvra_append_only
  BEFORE UPDATE OR DELETE ON volvra.change_log
  FOR EACH ROW EXECUTE FUNCTION volvra._guard_append_only();

DROP TRIGGER IF EXISTS volvra_no_truncate ON volvra.change_log;
CREATE TRIGGER volvra_no_truncate
  BEFORE TRUNCATE ON volvra.change_log
  FOR EACH STATEMENT EXECUTE FUNCTION volvra._guard_append_only();

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

-- to_regclass() RAISES "permission denied for schema X" when the caller lacks
-- USAGE on an existing schema; it returns NULL only for a name that does not
-- resolve at all.  Every read that resolves a stored table_name therefore has
-- to go through this, or a viewer who cannot see one schema cannot run the
-- monitoring functions at all.
CREATE OR REPLACE FUNCTION volvra._resolve(p_name text) RETURNS regclass
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN to_regclass(p_name);
EXCEPTION WHEN OTHERS THEN
  -- Not resolvable *by this caller*, which is not the same as absent.
  RETURN NULL;
END
$$;

-- The covered tables the current caller may actually read.  Computed once per
-- query rather than per row, which is what makes it usable in a row-level
-- security policy over a large history.
CREATE OR REPLACE FUNCTION volvra._readable_tables()
RETURNS TABLE (table_name text)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT t.table_name
  FROM (SELECT DISTINCT e.table_name FROM volvra.enabled_tables e) AS t
  WHERE volvra._resolve(t.table_name) IS NOT NULL
    AND has_table_privilege(volvra._resolve(t.table_name), 'SELECT')
$$;

-- Fully-qualified, quoted name. Stable regardless of search_path.
CREATE OR REPLACE FUNCTION volvra._fqname(target regclass) RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format('%I.%I', n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = target
$$;

-- Insertable / updatable columns (excludes dropped and GENERATED columns).
CREATE OR REPLACE FUNCTION volvra._columns(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated = ''
$$;

-- Columns that may appear in an UPDATE ... SET.  GENERATED ALWAYS AS IDENTITY
-- columns are excluded: Postgres forbids updating them, and by the same rule
-- they can never have changed, so there is nothing to restore.
CREATE OR REPLACE FUNCTION volvra._setcols(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated = ''
    AND a.attidentity <> 'a'
$$;

-- Primary key columns, in index order.
CREATE OR REPLACE FUNCTION volvra._pkcols(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY k.ord), '{}')
  FROM pg_index i
  CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
  WHERE i.indrelid = target AND i.indisprimary
$$;

-- Does the table have a GENERATED ALWAYS AS IDENTITY column?
CREATE OR REPLACE FUNCTION volvra._has_system_identity(target regclass) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = target AND attnum > 0 AND NOT attisdropped AND attidentity = 'a'
  )
$$;

-- The authenticated principal, and the one place that decides what "who" means.
--
-- session_user alone is wrong: it ignores SET ROLE.  current_user alone is wrong
-- too: inside the SECURITY DEFINER capture trigger it is the function owner.
-- The `role` GUC survives the definer boundary and can only ever name a role the
-- caller is genuinely a member of, so it is both correct and unspoofable.
CREATE OR REPLACE FUNCTION volvra._db_user() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(nullif(current_setting('role', true), 'none'), session_user)
$$;

COMMENT ON FUNCTION volvra._db_user() IS
  'Authenticated principal: the SET ROLE target if one is active, else session_user. '
  'Never the SECURITY DEFINER owner.';

CREATE OR REPLACE FUNCTION volvra._actor() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(nullif(current_setting('volvra.actor', true), ''), volvra._db_user())
$$;

COMMENT ON FUNCTION volvra._actor() IS
  'Attributed actor: the volvra.actor GUC if the app sets one, else the '
  'authenticated principal. Spoofable by design -- db_user is the audit column.';

-- Extract the pk subset of a row image.
CREATE OR REPLACE FUNCTION volvra._extract_pk(row_img jsonb, pkcols text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(c, row_img -> c), '{}'::jsonb)
  FROM unnest(pkcols) AS c
$$;

-- Membership check. Permissive if the role was never created (see bootstrap).
CREATE OR REPLACE FUNCTION volvra._require(role_name text) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    -- Fail closed when the operator asked us to.
    IF coalesce((SELECT value FROM volvra.settings WHERE key = 'strict_roles'), 'off') = 'on'
    THEN
      RAISE EXCEPTION 'volvra: role % does not exist and strict_roles is on', role_name
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN;
  END IF;
  IF NOT pg_has_role(current_user, role_name, 'USAGE') THEN
    RAISE EXCEPTION 'volvra: % is required for this operation (current_user=%)',
      role_name, current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- change_log holds complete row images, so reading it must never be a way
-- around the base table's own grants.  Enforced twice: explicitly here, and
-- by row-level security on change_log itself.
CREATE OR REPLACE FUNCTION volvra._require_read(target regclass) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT has_table_privilege(target, 'SELECT') THEN
    RAISE EXCEPTION 'volvra: permission denied to read history of %', target::text
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.get_setting(p_key text) RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT s.value FROM volvra.settings s WHERE s.key = p_key $$;

-- Parameters are p_-prefixed: bare `key`/`value` would be ambiguous against the
-- settings columns inside ON CONFLICT.
CREATE OR REPLACE FUNCTION volvra.set_setting(p_key text, p_value text) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_admin');
  INSERT INTO volvra.settings AS s (key, value) VALUES (p_key, p_value)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END
$$;

-- ---------------------------------------------------------------------
-- Capture
--
-- SECURITY DEFINER so that arbitrary writers need no INSERT grant on
-- change_log -- that is what makes the history unforgeable by ordinary
-- application roles.  Install as a dedicated owner role, never as a
-- superuser, in production.
-- ---------------------------------------------------------------------
-- The nearest ancestor of a partition that volvra.enable() covers.
--
-- Returns nothing for an ordinary table, or for a partition whose ancestors
-- are all uncovered.  Walking the whole chain rather than one level up is
-- deliberate: partitions can be partitioned, and the covered table may be the
-- root rather than the immediate parent.
CREATE OR REPLACE FUNCTION volvra._covered_ancestor(p_relid oid)
RETURNS TABLE (table_name text, excluded_columns text[], update_mode text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  -- Partition links only.  pg_inherits also records legacy INHERITS, where
  -- coverage does NOT propagate: a row trigger on the parent never fires for
  -- a child's rows.  Treating those alike made enable() refuse to cover an
  -- inheritance child, telling the user it was "already covered through" the
  -- parent while nothing captured its writes at all.
  WITH RECURSIVE up AS (
    SELECT i.inhparent AS relid, 1 AS lvl
    FROM pg_inherits i
    JOIN pg_class pc ON pc.oid = i.inhparent AND pc.relkind = 'p'
    WHERE i.inhrelid = p_relid
    UNION ALL
    SELECT i.inhparent, u.lvl + 1
    FROM up u
    JOIN pg_inherits i ON i.inhrelid = u.relid
    JOIN pg_class pc   ON pc.oid = i.inhparent AND pc.relkind = 'p'
    WHERE u.lvl < 32
  )
  SELECT e.table_name, e.excluded_columns, e.update_mode
  FROM up
  JOIN pg_class c  ON c.oid = up.relid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN volvra.enabled_tables e
    ON e.table_name = format('%I.%I', n.nspname, c.relname)
  ORDER BY up.lvl
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION volvra.capture() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_op      char(1);
  v_old     jsonb;
  v_new     jsonb;
  v_pk_src  jsonb;
  v_changed text[];
  v_excl    text[];
  v_mode    text;
  v_tbl     text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
  v_stale   text;
BEGIN
  -- Refuse to write history for a table volvra.enable() does not cover.  Without
  -- this, anyone able to attach this trigger to a table of their own could
  -- forge change_log entries or fill the history table at will.
  -- One lookup does triple duty: the registration check, the exclusion list,
  -- and this table's capture mode.
  SELECT e.excluded_columns, e.update_mode INTO v_excl, v_mode
  FROM volvra.enabled_tables e WHERE e.table_name = v_tbl;

  -- A row trigger on a partitioned table is propagated to every partition,
  -- including partitions attached later, and it fires with TG_RELID set to the
  -- partition the row landed in -- which is not what was registered.  Walk up
  -- to the covered ancestor and record the change under that name, so a
  -- partitioned table behaves as the one table the caller covered.
  -- ALTER TABLE ... RENAME and SET SCHEMA move the trigger with the table but
  -- leave table_name in the ledger pointing at a name that no longer exists.
  -- The OID survives both, so it is what identifies the table here; finding
  -- the row this way and correcting the name is what keeps a rename from
  -- making a covered table unwritable.
  IF NOT FOUND AND TG_RELID IS NOT NULL THEN
    SELECT e.table_name, e.excluded_columns, e.update_mode
      INTO v_stale, v_excl, v_mode
    FROM volvra.enabled_tables e WHERE e.rel_oid = TG_RELID;

    IF FOUND THEN
      UPDATE volvra.enabled_tables SET table_name = v_tbl
       WHERE rel_oid = TG_RELID AND table_name = v_stale;
      RAISE NOTICE 'volvra: % was renamed to %; the coverage ledger has been '
                   'updated. History recorded under the old name is still '
                   'readable under that name.', v_stale, v_tbl;
    ELSE
      SELECT a.table_name, a.excluded_columns, a.update_mode
        INTO v_tbl, v_excl, v_mode
      FROM volvra._covered_ancestor(TG_RELID) AS a;
    END IF;
  END IF;

  IF v_tbl IS NULL OR NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e
                                  WHERE e.table_name = v_tbl) THEN
    RAISE EXCEPTION 'volvra.capture: % is not registered via volvra.enable()',
                    coalesce(v_tbl, format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME))
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_op := 'I'; v_new := to_jsonb(NEW); v_pk_src := v_new;

  ELSIF TG_OP = 'UPDATE' THEN
    v_op := 'U';
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_pk_src := v_new;

    -- Excluded columns are stripped *before* the diff, so a change confined to
    -- one of them records nothing at all -- which is the point: we are not
    -- permitted to keep a second copy of it, not even the fact of its value.
    IF v_excl <> '{}' THEN
      v_old := v_old - v_excl;
      v_new := v_new - v_excl;
    END IF;

    -- Which columns actually moved.  The pk is carried in its own column, so
    -- nothing here is needed to locate the row.
    v_changed := ARRAY(
      SELECT k FROM jsonb_object_keys(v_new) AS k
      WHERE (v_old -> k) IS DISTINCT FROM (v_new -> k));

    IF cardinality(v_changed) = 0 THEN
      -- An update that changed nothing has an identity inverse: recording it
      -- costs a row and buys nothing.
      IF coalesce(volvra.get_setting('capture_no_op_updates'), 'off') <> 'on' THEN
        RETURN NULL;
      END IF;

    ELSIF coalesce(v_mode, volvra.get_setting('capture_updates'), 'changed') <> 'full' THEN
      -- Store the delta, not two copies of the row.  On a wide row where one
      -- narrow column changed this is the difference between a few dozen bytes
      -- and twice the row.
      SELECT jsonb_object_agg(k, v_old -> k),
             jsonb_object_agg(k, v_new -> k)
        INTO v_old, v_new
      FROM unnest(v_changed) AS k;
    END IF;

  ELSE
    -- A delete image must stay complete: the whole row has to be rebuildable.
    -- If a column is excluded it cannot be, and volvra.exclude_columns() warns
    -- about exactly that when the column is required.
    v_op := 'D'; v_old := to_jsonb(OLD); v_pk_src := v_old;
    IF v_excl <> '{}' THEN
      v_old := v_old - v_excl;
    END IF;
  END IF;

  IF v_op = 'I' AND v_excl <> '{}' THEN
    v_new := v_new - v_excl;
  END IF;

  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid)
  VALUES (
    v_tbl,
    v_op,
    volvra._extract_pk(v_pk_src, TG_ARGV),
    v_old,
    v_new,
    volvra._actor(),
    volvra._db_user(),
    txid_current()
  );

  RETURN NULL;  -- AFTER trigger; return value ignored
END
$$;

-- ---------------------------------------------------------------------
-- TRUNCATE capture
--
-- Row triggers do not fire on TRUNCATE, so without this a captured table can be
-- emptied with no history and no warning -- the largest possible accident being
-- the one the tool cannot see.  A statement trigger closes it.
--
-- Behaviour is set by the on_truncate setting: capture (default), block, allow.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.capture_truncate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl   text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
  -- The relation this trigger fired for, which for a partition is not v_tbl.
  v_src   text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
  v_mode  text := coalesce(volvra.get_setting('on_truncate'), 'capture');
  v_cap   bigint := coalesce(volvra.get_setting('truncate_capture_max_rows')::bigint, 100000);
  v_pk    text[];
  v_rows  bigint;
BEGIN
  SELECT e.pk_columns INTO v_pk
  FROM volvra.enabled_tables e WHERE e.table_name = v_tbl;

  -- As in capture(): a truncate trigger reached through a partition has to be
  -- attributed to the covered ancestor, or truncating a covered partitioned
  -- table would fail on a table the caller never registered directly.
  --
  -- The name recorded and the rows read are two different things.  v_tbl is
  -- the covered table, so the history reads as one table and one undo of it
  -- covers every partition.  v_src is the relation this trigger actually
  -- fired for, and it is the only place the rows may be read from: reading
  -- the parent from a partition's trigger captured every row once per
  -- partition.
  IF v_pk IS NULL AND TG_RELID IS NOT NULL THEN
    SELECT a.table_name INTO v_tbl FROM volvra._covered_ancestor(TG_RELID) AS a;
    IF v_tbl IS NOT NULL THEN
      SELECT e.pk_columns INTO v_pk
      FROM volvra.enabled_tables e WHERE e.table_name = v_tbl;
    END IF;
  END IF;

  IF v_pk IS NULL THEN
    RAISE EXCEPTION 'volvra.capture_truncate: % is not registered via volvra.enable()',
                    coalesce(v_tbl, format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME))
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- TRUNCATE of a partitioned parent fires this trigger on the parent AND on
  -- every partition.  The parent holds no rows of its own, so capturing there
  -- would duplicate what the partitions capture; leave the rows to them.
  IF TG_RELID IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_class WHERE oid = TG_RELID AND relkind = 'p')
  THEN
    RETURN NULL;
  END IF;

  IF v_mode = 'block' THEN
    RAISE EXCEPTION 'volvra: TRUNCATE of % is blocked', v_tbl
      USING HINT = 'DELETE is captured and reversible. To allow truncates, set '
                   'on_truncate to capture or allow.',
            ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_mode = 'capture' THEN
    EXECUTE format('SELECT count(*) FROM %s', v_src) INTO v_rows;

    IF v_rows > v_cap THEN
      RAISE EXCEPTION 'volvra: refusing to capture % rows before truncating %',
        v_rows, v_tbl
        USING HINT = 'Raise truncate_capture_max_rows to copy them into the '
                     'history anyway, or set on_truncate to allow and accept '
                     'that these rows will be unrecoverable.',
              ERRCODE = 'program_limit_exceeded';
    END IF;

    EXECUTE format(
      'INSERT INTO volvra.change_log '
      '  (table_name, op, pk, old_row, new_row, actor, db_user, txid) '
      -- The alias is quoted and deliberately unusable as a column name.
      -- With a bare alias, a covered table owning a column of the same name
      -- wins the reference: to_jsonb(t) then yields that column instead of
      -- the row, and TRUNCATE records a scalar where a row image belongs.
      -- The data is unrecoverable at that point, and nothing says so.
      'SELECT %L, ''D'', volvra._extract_pk(to_jsonb("volvra$row"), %L::text[]), '
      '       to_jsonb("volvra$row"), '
      '       NULL, volvra._actor(), volvra._db_user(), txid_current() '
      'FROM %s AS "volvra$row"', v_tbl, v_pk, v_src);

    RETURN NULL;
  END IF;

  -- 'allow': leave a marker so the gap is visible in history and undo refuses
  -- to step over it rather than silently half-restoring the table.
  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid)
  VALUES (v_tbl, 'T', '{}'::jsonb, NULL, NULL,
          volvra._actor(), volvra._db_user(), txid_current());

  RETURN NULL;
END
$$;

-- ---------------------------------------------------------------------
-- enable / disable
-- ---------------------------------------------------------------------
-- Add a newly covered table to the companion publication, if one exists.
--
-- Deliberately best-effort: ALTER PUBLICATION needs publication ownership,
-- which the caller of enable() may not have, and a database with no companion
-- has no publication to maintain.  Failing enable() over the durable tier
-- would be the wrong trade -- the trigger tier is what the caller asked for.
-- A WARNING is loud enough to act on, and companion_status() reports the drift
-- for anyone who missed it.
CREATE OR REPLACE FUNCTION volvra._publish(p_table text) RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_pub text := coalesce(volvra.get_setting('companion_publication'), 'volvra_pub');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = v_pub) THEN
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_publication_tables t
             WHERE t.pubname = v_pub
               AND format('%I.%I', t.schemaname, t.tablename) = p_table) THEN
    RETURN true;
  END IF;
  EXECUTE format('ALTER PUBLICATION %I ADD TABLE %s', v_pub, p_table);
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'volvra: % is covered but could not be added to publication % '
                '(%). The companion will not archive it until you run '
                'volvra.companion_setup() as the publication owner.',
                p_table, v_pub, SQLERRM;
  RETURN false;
END
$$;

-- Attach the statement-level TRUNCATE trigger to every partition of a covered
-- partitioned table, and report how many needed it.
--
-- PostgreSQL propagates ROW triggers from a partitioned parent to its
-- partitions, including partitions attached later, but it does NOT propagate
-- statement-level TRUNCATE triggers.  Without this, TRUNCATE on the parent is
-- captured and reversible while TRUNCATE on one partition destroys rows with
-- no history at all -- the same statement, two different guarantees, which is
-- the worst kind of gap.
--
-- A partition attached after this runs is again uncovered for TRUNCATE, so
-- maintain() calls this to reconcile, and status() reports the shortfall.
-- Turn capture of replicated changes on or off, across every covered table.
--
--   SELECT * FROM volvra.set_capture_replicated('on');
--
-- On a multi-master cluster, 'on' is what gives each node history of its
-- peers' changes rather than only its own. The cost is that every change is
-- stored once per node, and an undo applied on one node replicates to the
-- others and is captured there too.
--
-- 'off' restores the default firing mode, which is also what a bulk loader
-- setting session_replication_role = 'replica' expects: an ALWAYS trigger
-- fires under that setting and an ordinary one does not.
-- ---------------------------------------------------------------------
-- Noticing a mistake as it is made
--
-- A row trigger cannot see how large a statement is: it fires once per row
-- and knows nothing of its siblings.  Counting needs statement-level
-- triggers, and the obvious way to do that -- REFERENCING NEW TABLE -- makes
-- PostgreSQL materialise every changed row into a tuplestore, which is a real
-- cost imposed on every covered write.
--
-- These use the change_log sequence instead.  A BEFORE STATEMENT trigger
-- notes where the sequence stands; an AFTER STATEMENT trigger counts the rows
-- this transaction wrote past that point.  The count is filtered by txid, so
-- a concurrent session writing at the same time cannot inflate it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._stmt_begin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM set_config('volvra.stmt_mark',
                     coalesce(pg_sequence_last_value('volvra.change_log_id_seq'), 0)::text,
                     true);   -- transaction-local
  RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION volvra._stmt_end() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_limit bigint := coalesce(volvra.get_setting('warn_changed_rows'), '0')::bigint;
  v_mark  bigint := nullif(current_setting('volvra.stmt_mark', true), '')::bigint;
  v_rows  bigint;
BEGIN
  IF v_limit <= 0 OR v_mark IS NULL THEN
    RETURN NULL;
  END IF;

  -- How far the sequence moved is an upper bound on what this statement
  -- wrote: concurrent sessions consume ids too, so the delta can only
  -- overstate.  That makes it a safe cheap filter -- a statement under the
  -- limit by this measure is certainly under it -- and it keeps the common
  -- case, a small statement, to two sequence reads and no index scan.
  --
  -- Counting properly on every statement cost 8x on a workload of many
  -- single-row updates, because the id range has to be probed in every
  -- monthly partition.
  IF coalesce(pg_sequence_last_value('volvra.change_log_id_seq'), 0) - v_mark
     <= v_limit THEN
    RETURN NULL;
  END IF;

  -- Only now is an exact answer worth paying for: the delta says this
  -- statement may have crossed the line, and other sessions must not be
  -- allowed to raise a warning about this one.  Stop at the limit; the exact
  -- size of a runaway statement is not worth scanning a million rows for.
  SELECT count(*) INTO v_rows
  FROM (SELECT 1 FROM volvra.change_log c
        WHERE c.id > v_mark AND c.txid = txid_current()
        LIMIT v_limit + 1) AS counted;

  IF v_rows > v_limit THEN
    RAISE WARNING 'volvra: one statement changed more than % row(s) of %',
      v_limit, format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME)
      USING HINT = 'If that was not intended, volvra.preview_undo() will show '
                   'exactly what it did while the rows are still recoverable.';
  END IF;
  RETURN NULL;
END
$$;

-- Attach or remove the statement triggers on one table, to match the setting.
-- Kept separate so enable() and set_warn_changed_rows() cannot drift apart.
CREATE OR REPLACE FUNCTION volvra._apply_stmt_triggers(target regclass)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl text := volvra._fqname(target);
  v_on  boolean := coalesce(volvra.get_setting('warn_changed_rows'), '0')::bigint > 0;
BEGIN
  IF v_on THEN
    EXECUTE format(
      'CREATE OR REPLACE TRIGGER volvra_stmt_begin '
      'BEFORE INSERT OR UPDATE OR DELETE ON %s '
      'FOR EACH STATEMENT EXECUTE FUNCTION volvra._stmt_begin()', v_tbl);
    EXECUTE format(
      'CREATE OR REPLACE TRIGGER volvra_stmt_end '
      'AFTER INSERT OR UPDATE OR DELETE ON %s '
      'FOR EACH STATEMENT EXECUTE FUNCTION volvra._stmt_end()', v_tbl);
  ELSIF EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgrelid = target AND tgname IN ('volvra_stmt_begin',
                                                      'volvra_stmt_end')) THEN
    -- Guarded rather than IF EXISTS: enable() calls this on every covered
    -- table, and a bare DROP ... IF EXISTS emits a NOTICE per trigger per
    -- call.  The install is deliberately quiet, and noise that looks like a
    -- problem is worse than no message at all.
    EXECUTE format('DROP TRIGGER volvra_stmt_begin ON %s', v_tbl);
    EXECUTE format('DROP TRIGGER volvra_stmt_end ON %s', v_tbl);
  END IF;
END
$$;

-- Turning the warning on or off has to reach every covered table, or the
-- setting would describe a state the triggers do not implement.
CREATE OR REPLACE FUNCTION volvra.set_warn_changed_rows(p_rows bigint)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r       record;
  v_n     bigint := 0;
  v_fail  text[] := '{}';
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF p_rows < 0 THEN
    RAISE EXCEPTION 'volvra.set_warn_changed_rows: % is negative', p_rows
      USING HINT = '0 disables the warning; any positive number is a row limit.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  PERFORM volvra.set_setting('warn_changed_rows', p_rows::text);

  FOR r IN SELECT e.table_name FROM volvra.enabled_tables e ORDER BY e.table_name
  LOOP
    -- Best effort per table: altering a table needs ownership, and one table
    -- owned by someone else must not stop the rest from being synced.
    BEGIN
      PERFORM volvra._apply_stmt_triggers(r.table_name::regclass);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      v_fail := v_fail || r.table_name;
    END;
  END LOOP;

  IF cardinality(v_fail) > 0 THEN
    RAISE WARNING 'volvra: could not update statement triggers on %',
      array_to_string(v_fail, ', ')
      USING HINT = 'Altering a table requires ownership. Those tables keep '
                   'their previous behaviour.';
  END IF;

  RETURN CASE WHEN p_rows = 0
    THEN format('volvra: large-statement warning off (%s table(s) updated)', v_n)
    ELSE format('volvra: warn when one statement changes more than %s row(s) '
                '(%s table(s) updated)', p_rows, v_n)
  END;
END
$$;

CREATE OR REPLACE FUNCTION volvra.set_capture_replicated(p_value text)
RETURNS TABLE (table_name text, captures_replicated boolean)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r record;
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF p_value NOT IN ('on', 'off') THEN
    RAISE EXCEPTION 'volvra.set_capture_replicated: expected on or off, got %',
      p_value USING ERRCODE = 'invalid_parameter_value';
  END IF;

  PERFORM volvra.set_setting('capture_replicated', p_value);

  FOR r IN SELECT e.table_name AS t FROM volvra.enabled_tables e
            WHERE volvra._resolve(e.table_name) IS NOT NULL
            ORDER BY e.table_name
  LOOP
    table_name := r.t;
    captures_replicated := volvra._apply_trigger_mode(r.t);
    RETURN NEXT;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION volvra.cover_partitions(target regclass DEFAULT NULL)
RETURNS TABLE (partition_name text, action text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');

  FOR r IN
    WITH RECURSIVE covered AS (
      SELECT volvra._resolve(e.table_name) AS relid
      FROM volvra.enabled_tables e
      WHERE volvra._resolve(e.table_name) IS NOT NULL
        AND (target IS NULL OR volvra._resolve(e.table_name) = target)
    ), down AS (
      SELECT i.inhrelid AS relid, 1 AS lvl
      FROM pg_inherits i JOIN covered c ON c.relid = i.inhparent
      UNION ALL
      SELECT i.inhrelid, d.lvl + 1
      FROM down d JOIN pg_inherits i ON i.inhparent = d.relid
      WHERE d.lvl < 32
    )
    SELECT format('%I.%I', n.nspname, c.relname) AS name, c.oid
    FROM down
    JOIN pg_class c ON c.oid = down.relid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = c.oid
                        AND t.tgname = 'volvra_capture_truncate')
    ORDER BY 1
  LOOP
    EXECUTE format(
      'CREATE TRIGGER volvra_capture_truncate '
      'BEFORE TRUNCATE ON %s '
      'FOR EACH STATEMENT EXECUTE FUNCTION volvra.capture_truncate()', r.name);
    partition_name := r.name;
    action := 'truncate trigger added';
    RETURN NEXT;
  END LOOP;
END
$$;

-- Is this database receiving changes from somewhere else?
--
-- True when a native logical replication subscription exists, or when Spock
-- has a subscription. Either means changes arrive that an ordinary trigger
-- will not see, which is the whole reason capture_replicated exists.
CREATE OR REPLACE FUNCTION volvra._is_subscriber() RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_n bigint := 0;
BEGIN
  SELECT count(*) INTO v_n FROM pg_subscription;
  IF v_n > 0 THEN RETURN true; END IF;

  -- Spock keeps its own subscription catalogue, and querying it has to be
  -- guarded: the extension is absent on most installs.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
    BEGIN
      EXECUTE 'SELECT count(*) FROM spock.subscription' INTO v_n;
      IF v_n > 0 THEN RETURN true; END IF;
    EXCEPTION WHEN OTHERS THEN
      RETURN false;
    END;
  END IF;
  RETURN false;
END
$$;

-- The trigger firing mode capture should use, from the setting.
CREATE OR REPLACE FUNCTION volvra._trigger_mode() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE WHEN coalesce(volvra.get_setting('capture_replicated'), 'off') = 'on'
              THEN 'ALWAYS' ELSE 'ORIGIN' END
$$;

-- Put one covered table's triggers into the configured firing mode.
--
-- Separate from enable() because the setting can change after a table is
-- covered, and because maintain() reconciles tables that were covered under a
-- previous setting. ALTER TABLE ... ENABLE ALWAYS/REPLICA TRIGGER is the only
-- way to change a trigger's firing mode; it cannot be set at CREATE time.
CREATE OR REPLACE FUNCTION volvra._apply_trigger_mode(p_table text)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_mode text := volvra._trigger_mode();
  v_trg  text;
BEGIN
  FOREACH v_trg IN ARRAY ARRAY['volvra_capture', 'volvra_capture_truncate'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %s ENABLE %s TRIGGER %I',
                     p_table,
                     CASE WHEN v_mode = 'ALWAYS' THEN 'ALWAYS' ELSE 'REPLICA' END,
                     v_trg);
      -- ENABLE REPLICA is not the same as the default. Restore the default
      -- firing mode explicitly when the setting is off.
      IF v_mode <> 'ALWAYS' THEN
        EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I', p_table, v_trg);
      END IF;
    EXCEPTION
      WHEN undefined_object THEN
        NULL;    -- a partitioned parent has no truncate trigger of its own
      WHEN insufficient_privilege THEN
        -- ALTER TABLE needs table ownership, which a volvra_admin need not
        -- have. Best-effort rather than fatal, for the same reason
        -- volvra._publish() is: refusing the whole operation over a table
        -- this caller cannot alter would be the wrong trade. The warning
        -- names the table, and preflight reports the resulting mismatch.
        RAISE WARNING 'volvra: cannot set the firing mode of % on %, which '
                      'this role does not own. Run volvra.set_capture_'
                      'replicated as the table owner.', v_trg, p_table;
        RETURN false;
    END;
  END LOOP;
  RETURN v_mode = 'ALWAYS';
END
$$;

CREATE OR REPLACE FUNCTION volvra.enable(target regclass) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl    text   := volvra._fqname(target);
  v_pkcols text[] := volvra._pkcols(target);
  v_args   text;
  v_parent text;
BEGIN
  -- Covering a partition whose ancestor is already covered would fail deep
  -- inside CREATE TRIGGER with "internal or a child trigger", which explains
  -- nothing.  The ancestor's trigger already fires for this partition's rows,
  -- so there is nothing to do and saying so is more useful than either the
  -- catalog error or silent success.
  SELECT a.table_name INTO v_parent FROM volvra._covered_ancestor(target) AS a;
  IF v_parent IS NOT NULL THEN
    RETURN format('volvra: %s is already covered through %s, which volvra.enable() '
                  'covers as one table -- nothing to do', v_tbl, v_parent);
  END IF;
  PERFORM volvra._require('volvra_admin');

  IF split_part(v_tbl, '.', 1) = 'volvra' THEN
    RAISE EXCEPTION 'volvra.enable(%): volvra''s own tables cannot be captured', v_tbl;
  END IF;

  IF cardinality(v_pkcols) = 0 THEN
    RAISE EXCEPTION 'volvra.enable(%): table has no PRIMARY KEY; '
                    'v0 identifies rows by primary key', v_tbl;
  END IF;

  SELECT string_agg(quote_literal(c), ', ') INTO v_args FROM unnest(v_pkcols) AS c;

  EXECUTE format(
    'CREATE OR REPLACE TRIGGER volvra_capture '
    'AFTER INSERT OR UPDATE OR DELETE ON %s '
    'FOR EACH ROW EXECUTE FUNCTION volvra.capture(%s)', v_tbl, v_args);

  -- Registered first, then covered: capture_truncate() refuses tables it does
  -- not find in enabled_tables, so the row below must land before the trigger
  -- fires.
  INSERT INTO volvra.enabled_tables AS e (table_name, pk_columns, rel_oid)
  VALUES (v_tbl, v_pkcols, target)
  ON CONFLICT (table_name) DO UPDATE
    SET pk_columns = EXCLUDED.pk_columns,
        -- Refreshed, not preserved: a table dropped and recreated under the
        -- same name is a different relation with a different OID.
        rel_oid    = EXCLUDED.rel_oid,
        enabled_at = now(),
        enabled_by = current_user;

  EXECUTE format(
    'CREATE OR REPLACE TRIGGER volvra_capture_truncate '
    'BEFORE TRUNCATE ON %s '
    'FOR EACH STATEMENT EXECUTE FUNCTION volvra.capture_truncate()', v_tbl);

  -- ORIGIN or ALWAYS, from capture_replicated. An ALWAYS trigger also fires
  -- for rows applied by replication, which is what a node in a multi-master
  -- cluster needs in order to hold history of its peers' changes.
  PERFORM volvra._apply_trigger_mode(v_tbl);

  -- Keep the durable tier in step.  companion_setup() builds the publication
  -- from the tables covered when it runs, so a table covered afterwards would
  -- sit outside it and be archived by nothing at all -- silently, because the
  -- companion streams the publication and never sees what is missing from it.
  -- Adding it here is the difference between coverage and the appearance of
  -- coverage.
  PERFORM volvra._publish(v_tbl);

  -- A table covered while the large-statement warning is on gets it too,
  -- otherwise the setting would silently not apply to new tables.
  PERFORM volvra._apply_stmt_triggers(target);

  -- Statement-level TRUNCATE triggers do not propagate to partitions the way
  -- row triggers do, so a partitioned table needs them attached explicitly.
  IF EXISTS (SELECT 1 FROM pg_class WHERE oid = target AND relkind = 'p') THEN
    PERFORM count(*) FROM volvra.cover_partitions(target);
  END IF;

  -- Legacy inheritance is the quiet version of the partition problem above.
  -- A row trigger is not inherited, so UPDATE on the parent rewrites child
  -- rows that nothing captures, while status() still reports the table as
  -- covered.  Partitions are excluded here: cover_partitions() handles those.
  DECLARE v_kids text;
  BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', '
                      ORDER BY n.nspname, c.relname)
      INTO v_kids
    FROM pg_inherits i
    JOIN pg_class c     ON c.oid = i.inhrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_class pc    ON pc.oid = i.inhparent
    WHERE i.inhparent = target
      AND pc.relkind = 'r'                      -- not a partitioned table
      AND NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e
                      WHERE e.rel_oid = c.oid);

    IF v_kids IS NOT NULL THEN
      RAISE WARNING 'volvra: % has inheritance children that are not covered: %',
        v_tbl, v_kids
        USING HINT = 'A row trigger is not inherited, so writes that reach '
                     'those rows are not captured and cannot be undone. '
                     'Call volvra.enable() on each child as well.';
    END IF;
  END;

  RETURN format('volvra: capture enabled on %s (pk: %s)',
                v_tbl, array_to_string(v_pkcols, ', '));
END
$$;

CREATE OR REPLACE FUNCTION volvra.disable(target regclass) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl text := volvra._fqname(target);
BEGIN
  PERFORM volvra._require('volvra_admin');
  EXECUTE format('DROP TRIGGER IF EXISTS volvra_capture ON %s', v_tbl);
  EXECUTE format('DROP TRIGGER IF EXISTS volvra_capture_truncate ON %s', v_tbl);
  DELETE FROM volvra.enabled_tables WHERE table_name = v_tbl;
  RETURN format('volvra: capture disabled on %s (history retained)', v_tbl);
END
$$;

-- ---------------------------------------------------------------------
-- Covering a whole schema
--
-- enable() is per table, so a table created next month has no coverage at all
-- -- and "coverage starts at setup" only holds if setup stays exhaustive.  These are idempotent, so the same call doubles as a sync after
-- a migration adds tables.
--
-- Deliberately not an event trigger: CREATE EVENT TRIGGER is superuser-only,
-- and the whole point of volvra is that it installs without one.  Call
-- enable_all() from your migration tooling instead.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.enable_all(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, status text, detail text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF p_schema = 'volvra' THEN
    RAISE EXCEPTION 'volvra: volvra''s own schema cannot be captured';
  END IF;

  FOR r IN
    SELECT c.oid::regclass AS rel, format('%I.%I', n.nspname, c.relname) AS fq,
           cardinality(volvra._pkcols(c.oid)) AS npk,
           EXISTS (SELECT 1 FROM volvra.enabled_tables e
                   WHERE e.table_name = format('%I.%I', n.nspname, c.relname)) AS covered
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema
      AND c.relkind IN ('r', 'p')          -- ordinary and partitioned tables
      AND c.relpersistence = 'p'           -- not temp, not unlogged
    ORDER BY c.relname
  LOOP
    table_name := r.fq;

    IF r.npk = 0 THEN
      status := 'skipped';
      detail := 'no primary key: volvra identifies rows by pk';
    ELSE
      BEGIN
        PERFORM volvra.enable(r.rel);
        status := CASE WHEN r.covered THEN 'already covered' ELSE 'covered' END;
        detail := NULL;
      EXCEPTION WHEN OTHERS THEN
        status := 'failed';
        detail := SQLERRM;
      END;
    END IF;

    RETURN NEXT;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION volvra.disable_all(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, status text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');
  FOR r IN
    SELECT e.table_name AS fq FROM volvra.enabled_tables e
    WHERE split_part(e.table_name, '.', 1) = quote_ident(p_schema)
       OR split_part(e.table_name, '.', 1) = p_schema
    ORDER BY e.table_name
  LOOP
    table_name := r.fq;
    IF volvra._resolve(r.fq) IS NULL THEN
      DELETE FROM volvra.enabled_tables WHERE enabled_tables.table_name = r.fq;
      status := 'table gone: registration removed';
    ELSE
      PERFORM volvra.disable(volvra._resolve(r.fq));
      status := 'no longer covered (history retained)';
    END IF;
    RETURN NEXT;
  END LOOP;
END
$$;

-- Tables that exist, could be covered, and are not.  This is the coverage gap:
-- an uncovered table is a table with no undo.
CREATE OR REPLACE FUNCTION volvra.uncovered(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, reason text)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT format('%I.%I', n.nspname, c.relname),
           CASE WHEN cardinality(volvra._pkcols(c.oid)) = 0
                THEN 'no primary key'
                ELSE 'never covered' END
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema
      AND c.relkind IN ('r', 'p')
      AND c.relpersistence = 'p'
      AND NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e
                      WHERE e.table_name = format('%I.%I', n.nspname, c.relname))
    ORDER BY c.relname;
END
$$;

-- ---------------------------------------------------------------------
-- make_fks_deferrable
--
-- A one-time setup step that makes multi-table undo possible without
-- dependency-ordering every plan.  DEFERRABLE INITIALLY IMMEDIATE changes
-- nothing about day-to-day behaviour -- constraints are still checked at the
-- end of each statement -- it only grants undo the right to defer them to
-- COMMIT inside its own transaction.
--
-- Takes a brief ACCESS EXCLUSIVE lock per table, so run it in a maintenance
-- window like any other ALTER TABLE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.make_fks_deferrable(p_schema text DEFAULT 'public')
RETURNS TABLE (constraint_name text, table_name text, status text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');
  FOR r IN
    SELECT con.conname, format('%I.%I', n.nspname, c.relname) AS fq
    FROM pg_constraint con
    JOIN pg_class c     ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE con.contype = 'f'
      AND n.nspname = p_schema
      AND NOT con.condeferrable
    ORDER BY c.relname, con.conname
  LOOP
    constraint_name := r.conname;
    table_name      := r.fq;
    BEGIN
      EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE',
                     r.fq, r.conname);
      status := 'now deferrable';
    EXCEPTION WHEN OTHERS THEN
      status := 'failed: ' || SQLERRM;
    END;
    RETURN NEXT;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- status -- one query that answers "is volvra doing its job?"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.status()
RETURNS TABLE (
  table_name       text,
  covered          boolean,
  truncate_covered boolean,
  changes       bigint,
  oldest_change timestamptz,
  newest_change timestamptz
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT e.table_name,
           -- registered *and* the trigger is really still attached: an owner
           -- can disable a trigger behind volvra's back, and a table that
           -- looks covered and is not is the worst state to be in.
           EXISTS (SELECT 1 FROM pg_trigger t
                   WHERE t.tgrelid = volvra._resolve(e.table_name)
                     AND t.tgname = 'volvra_capture' AND t.tgenabled <> 'D'),
           EXISTS (SELECT 1 FROM pg_trigger t
                   WHERE t.tgrelid = volvra._resolve(e.table_name)
                     AND t.tgname = 'volvra_capture_truncate' AND t.tgenabled <> 'D'),
           count(c.id),
           min(c.ts), max(c.ts)
    FROM volvra.enabled_tables e
    LEFT JOIN volvra.change_log c ON c.table_name = e.table_name
    GROUP BY e.table_name
    ORDER BY e.table_name;
END
$$;

-- ---------------------------------------------------------------------
-- history
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.history(target regclass, pk jsonb)
RETURNS TABLE (
  change_id bigint,
  ts        timestamptz,
  actor     text,
  db_user   text,
  op        char(1),
  txid      bigint,
  old_row   jsonb,
  new_row   jsonb
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_read(target);
  RETURN QUERY
    SELECT c.id, c.ts, c.actor, c.db_user, c.op, c.txid, c.old_row, c.new_row
    FROM volvra.change_log c
    WHERE c.table_name = volvra._fqname(history.target)
      AND c.pk @> history.pk
    ORDER BY c.id;
END
$$;

-- ---------------------------------------------------------------------
-- Time travel: the table as it was, read-only.
--
-- undo() reverses history by writing.  as_of() answers the question people
-- actually ask first -- "what did this look like before?" -- without touching
-- a single row.  It is the half of Oracle Flashback that volvra did not have.
--
-- The reconstruction is not a lookup, because an UPDATE stores only the
-- columns that changed.  A row at time T is therefore the row as it stands
-- now, overlaid with the old values of every change since T, applied newest
-- first so that the oldest overlay -- the one closest to T -- wins.
--
-- Three cases fall out of that one rule:
--   * untouched since T  -- no changes in the window, so the current row is
--                           already the answer.
--   * deleted since T    -- absent now, but the DELETE carries a complete old
--                           image, which the overlay restores.
--   * inserted since T   -- the oldest change in the window is an INSERT, so
--                           the row did not exist at T and is dropped.
-- ---------------------------------------------------------------------
-- No custom aggregate here, deliberately.  volvra.fingerprint() hashes every
-- function in the schema with pg_get_functiondef(), which raises on an
-- aggregate, so adding one silently breaks tamper evidence.  The fold is
-- expressed below as a per-column pick instead, which is clearer anyway.
DROP AGGREGATE IF EXISTS volvra._rewind(jsonb);
DROP FUNCTION IF EXISTS volvra._overlay(jsonb, jsonb);

CREATE OR REPLACE FUNCTION volvra.as_of(target regclass, at_ts timestamptz)
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl  text := volvra._fqname(target);
  v_pk   text[];
  v_cov  boolean;
  v_anc  text;
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_read(target);

  -- disable() keeps the history and drops the registration, so the ledger is
  -- not the only place to look for a key.  history() still answers for such a
  -- table and as_of() must too.
  SELECT e.pk_columns INTO v_pk
  FROM volvra.enabled_tables e WHERE e.table_name = v_tbl;
  IF v_pk IS NULL THEN
    v_pk := volvra._pkcols(target);
  END IF;

  IF coalesce(cardinality(v_pk), 0) = 0 THEN
    RAISE EXCEPTION 'volvra.as_of(%): table has no PRIMARY KEY', v_tbl
      USING HINT = 'Rows are identified by primary key, as they are for undo.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Answering from no history at all would return the table as it stands now
  -- and call it the past, which is the one answer worse than refusing.
  IF NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e WHERE e.table_name = v_tbl)
     AND NOT EXISTS (SELECT 1 FROM volvra.change_log c WHERE c.table_name = v_tbl)
  THEN
    -- A partition's history is recorded under the covered ancestor, so it has
    -- none of its own.  Telling the caller to enable() it would be a dead end:
    -- enable() refuses a partition as already covered through its parent.
    SELECT a.table_name INTO v_anc FROM volvra._covered_ancestor(target) AS a;
    IF v_anc IS NOT NULL THEN
      RAISE EXCEPTION 'volvra.as_of(%): history is recorded under %', v_tbl, v_anc
        USING HINT = format('This table is covered through %s, which volvra '
                            'treats as one table. Call volvra.as_of(%L, ...) '
                            'instead.', v_anc, v_anc),
              ERRCODE = 'invalid_parameter_value';
    END IF;

    RAISE EXCEPTION 'volvra.as_of(%): no history for this table', v_tbl
      USING HINT = 'Cover it with volvra.enable() first. Nothing before that '
                   'moment was recorded.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Registered but not capturing, or no longer registered: changes made in the
  -- gap are missing, and a silently incomplete answer is worse than a noisy one.
  SELECT s.covered INTO v_cov FROM volvra.status() s WHERE s.table_name = v_tbl;
  IF NOT coalesce(v_cov, false) THEN
    RAISE WARNING 'volvra.as_of(%): the table is not capturing, so any change '
                  'made while it was uncovered is missing from this answer', v_tbl;
  END IF;

  RETURN QUERY EXECUTE format($q$
    WITH cur AS (
      -- Quoted alias, for the reason given in volvra.capture_truncate().
      SELECT volvra._extract_pk(to_jsonb("volvra$row"), %2$L::text[]) AS pk,
             to_jsonb("volvra$row") AS img
      FROM %1$s AS "volvra$row"
    ),
    win AS (
      SELECT c.pk, c.id, c.op, c.old_row
      FROM volvra.change_log c
      WHERE c.table_name = %3$L AND c.ts > %4$L::timestamptz
    ),
    -- For each column, the value at T is the one carried by the OLDEST
    -- change after T, because that change recorded what the column held
    -- immediately before it.  DISTINCT ON picks exactly that.
    kv AS (
      SELECT DISTINCT ON (w.pk, e.key) w.pk, e.key, e.value
      FROM win w
      CROSS JOIN LATERAL jsonb_each(coalesce(w.old_row, '{}'::jsonb)) AS e
      ORDER BY w.pk, e.key, w.id
    ),
    overlay AS (
      SELECT kv.pk, jsonb_object_agg(kv.key, kv.value) AS obj
      FROM kv GROUP BY kv.pk
    ),
    -- The oldest change decides whether the row existed at all: an INSERT
    -- there means it did not.
    oldest AS (
      SELECT DISTINCT ON (w.pk) w.pk, w.op FROM win w ORDER BY w.pk, w.id
    )
    SELECT coalesce(c.img, '{}'::jsonb) || coalesce(o.obj, '{}'::jsonb)
    FROM cur c
    FULL JOIN overlay o ON o.pk = c.pk
    LEFT JOIN oldest od ON od.pk = coalesce(c.pk, o.pk)
    WHERE od.op IS DISTINCT FROM 'I'
  $q$, v_tbl, v_pk, v_tbl, at_ts);
END
$$;


-- ---------------------------------------------------------------------
-- Schema drift
--
-- A row image captured before an ALTER TABLE may no longer fit the table it
-- came from.  Rather than carry a schema fingerprint on every captured row --
-- which would cost a catalog lookup per write -- the image is validated at
-- plan time, when it actually matters, against the columns that exist now.
-- ---------------------------------------------------------------------
-- p_require_complete: an image that will be re-INSERTed (the inverse of a
-- DELETE) has to supply every required column.  An image that will drive an
-- UPDATE is a delta by design, and missing columns simply are not touched.
CREATE OR REPLACE FUNCTION volvra._validate_image(
  target regclass, row_img jsonb, p_require_complete boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_gone    text[];
  v_missing text[];
BEGIN
  IF row_img IS NULL THEN
    RETURN;
  END IF;

  -- columns the image carries that the table no longer has
  SELECT array_agg(k ORDER BY k) INTO v_gone
  FROM jsonb_object_keys(row_img) AS k
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = target AND a.attname = k
      AND a.attnum > 0 AND NOT a.attisdropped);

  -- columns the table now requires that the image cannot supply
  SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO v_missing
  FROM pg_attribute a
  WHERE p_require_complete
    AND a.attrelid = target
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attgenerated = '' AND a.attidentity = ''
    AND a.attnotnull
    AND NOT a.atthasdef
    AND NOT (row_img ? a.attname::text);

  IF v_gone IS NOT NULL OR v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'volvra: % has changed shape since this row was captured', target::text
      USING DETAIL = format('captured columns no longer present: %s; '
                            'required columns not in the captured row: %s',
                            coalesce(array_to_string(v_gone, ', '), 'none'),
                            coalesce(array_to_string(v_missing, ', '), 'none')),
            HINT = 'Restore these rows by hand, or narrow the window to changes '
                   'captured under the current schema.',
            ERRCODE = 'datatype_mismatch';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- Compensating-SQL generation
--
-- Statements embed their row image as a jsonb literal, so the text returned by
-- preview_undo is byte-identical to what undo executes.
--
-- Each statement also carries its own optimistic-concurrency guard: it only
-- matches if the live row is still exactly what was captured.  That turns
-- "someone changed this row after the accident" from silent data loss into a
-- statement that affects zero rows, which undo then reports as a conflict.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._stmt_insert(
  v_tbl text, v_cols text[], v_identity boolean, row_img jsonb, guarded boolean)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'INSERT INTO %s (%s)%s SELECT %s FROM jsonb_populate_record(NULL::%s, %L::jsonb)%s',
    v_tbl,
    (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_cols) AS c),
    CASE WHEN v_identity THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END,
    (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_cols) AS c),
    v_tbl,
    row_img,
    -- guard: the row must still be absent, or this is a conflict
    CASE WHEN guarded THEN ' ON CONFLICT DO NOTHING' ELSE '' END)
$$;

-- Why the key comparisons in these builders are `=` and not
-- `IS NOT DISTINCT FROM`
--
-- IS NOT DISTINCT FROM is NULL-safe, which looks like the careful choice, and
-- it is not indexable: PostgreSQL cannot use a btree index for it, so every
-- statement built here degraded to a sequential scan of the target table.
-- The conflict probe runs one statement per row, so that is quadratic in table
-- size -- invisible on the thousands of rows the other suites use, and fatal
-- on real data.  A 200,000-row preview was still running after two minutes at
-- full CPU, having done 200,000 sequential scans.
--
-- Plain equality is correct here because these columns are a PRIMARY KEY, and
-- a primary key column cannot be NULL.  The NULL-safety bought nothing and
-- cost the index.
--
-- This applies to the key only.  The guard that compares captured values
-- against live ones still uses jsonb containment, which is NULL-correct.
CREATE OR REPLACE FUNCTION volvra._stmt_delete(
  v_tbl text, v_pkcols text[], pk_img jsonb, expected jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'DELETE FROM %s AS "volvra$tgt" USING jsonb_populate_record(NULL::%s, %L::jsonb) AS k WHERE %s%s',
    v_tbl, v_tbl, pk_img,
    (SELECT string_agg(format('"volvra$tgt".%1$I = k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c),
    -- Containment, not equality: the guard asserts that the values this
    -- statement is about to revert are still the ones that were captured.  A
    -- change to some *other* column is not a conflict, because reverting these
    -- columns cannot destroy it.
    CASE WHEN expected IS NULL THEN ''
         ELSE format(' AND to_jsonb("volvra$tgt") @> %L::jsonb', expected) END)
$$;

-- Locate the row by its *current* (post-change) pk and restore the columns the
-- captured image carries -- which is the changed columns only, unless
-- capture_updates is 'full'.  An UPDATE that changed the pk still reverts,
-- because a changed pk is by definition part of the delta.
--
-- v_cols must therefore be the image's own keys, never the table's full column
-- list: populating a record from a partial image would null out everything the
-- update never touched.
CREATE OR REPLACE FUNCTION volvra._stmt_update(
  v_tbl text, v_cols text[], v_pkcols text[],
  old_img jsonb, key_img jsonb, expected jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'UPDATE %s AS "volvra$tgt" SET %s FROM jsonb_populate_record(NULL::%s, %L::jsonb) AS src, '
    'jsonb_populate_record(NULL::%s, %L::jsonb) AS k WHERE %s%s',
    v_tbl,
    (SELECT string_agg(format('%1$I = src.%1$I', c), ', ') FROM unnest(v_cols) AS c),
    v_tbl, old_img,
    v_tbl, key_img,
    (SELECT string_agg(format('"volvra$tgt".%1$I = k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c),
    CASE WHEN expected IS NULL THEN ''
         ELSE format(' AND to_jsonb("volvra$tgt") @> %L::jsonb', expected) END)
$$;

-- Read the live row image for a pk, or NULL if the row is gone.
CREATE OR REPLACE FUNCTION volvra._stmt_probe(
  v_tbl text, v_pkcols text[], pk_img jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'SELECT to_jsonb("volvra$tgt") FROM %s AS "volvra$tgt", '
    'jsonb_populate_record(NULL::%s, %L::jsonb) AS k '
    'WHERE %s',
    v_tbl, v_tbl, pk_img,
    (SELECT string_agg(format('"volvra$tgt".%1$I = k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c))
$$;

-- ---------------------------------------------------------------------
-- The selector
--
-- Phase 1 could only answer "what happened to this table between these two
-- timestamps".  Real accidents are not shaped like that: a bad migration is one
-- transaction across several tables, and a misbehaving service is an actor.  So
-- every public entry point funnels through one selector, and the callers differ
-- only in which criteria they fill in.
--
-- p_predicate is a SQL fragment over the captured row (`old_row`, `new_row`,
-- `pk`, `actor`, `db_user`, `ts`, `txid`).  It is parenthesised before it is
-- spliced in, so it cannot chain a second statement, and it runs with the
-- caller's own privileges -- it is a WHERE clause, not an escalation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._where(
  p_tables    regclass[],
  p_from_ts   timestamptz,
  p_to_ts     timestamptz,
  p_txids     bigint[],
  p_actors    text[],
  p_db_users  text[],
  p_predicate text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_parts text[] := '{}';
  v_names text[];
BEGIN
  IF p_tables IS NOT NULL AND cardinality(p_tables) > 0 THEN
    SELECT array_agg(volvra._fqname(t)) INTO v_names FROM unnest(p_tables) AS t;
    v_parts := v_parts || format('c.table_name = ANY (%L::text[])', v_names);
  ELSE
    -- Never plan over tables volvra is not responsible for.
    -- ::text matters: an untyped literal makes Postgres pick array||array.
    v_parts := v_parts ||
      'c.table_name IN (SELECT e.table_name FROM volvra.enabled_tables e)'::text;
  END IF;

  IF p_from_ts  IS NOT NULL THEN v_parts := v_parts || format('c.ts > %L', p_from_ts); END IF;
  IF p_to_ts    IS NOT NULL THEN v_parts := v_parts || format('c.ts <= %L', p_to_ts); END IF;
  IF p_txids    IS NOT NULL THEN v_parts := v_parts || format('c.txid = ANY (%L::bigint[])', p_txids); END IF;
  IF p_actors   IS NOT NULL THEN v_parts := v_parts || format('c.actor = ANY (%L::text[])', p_actors); END IF;
  IF p_db_users IS NOT NULL THEN v_parts := v_parts || format('c.db_user = ANY (%L::text[])', p_db_users); END IF;

  IF p_predicate IS NOT NULL AND btrim(p_predicate) <> '' THEN
    -- The predicate is a WHERE fragment, not a statement.  Parenthesising it
    -- already stops it opening a second statement, but a semicolon or a comment
    -- opener has no legitimate use in an expression, so refuse them outright
    -- rather than rely on the parser to make the attempt fail.
    IF p_predicate ~ '(;|--|/\*)' THEN
      RAISE EXCEPTION 'volvra: predicate may not contain '';'', ''--'' or ''/*'''
        USING DETAIL = 'A predicate is a boolean expression over old_row, new_row, '
                       'pk, actor, db_user, ts and txid.',
              ERRCODE = 'syntax_error';
    END IF;
    v_parts := v_parts || format('(%s)', p_predicate);
  END IF;

  RETURN array_to_string(v_parts, ' AND ');
END
$$;

-- Per-table metadata, memoised for the life of one plan.  Without this a plan
-- spanning tables would re-read the catalog for every row.
-- Columns whose value PostgreSQL derives, and which a conflict guard must
-- therefore ignore.
--
-- A generated column is a function of other columns, so comparing it tells you
-- nothing the source columns have not already told you.  Worse, it breaks:
-- PostgreSQL's logical replication does not send generated columns, so an
-- image restored from a companion archive carries an explicit null where the
-- live row holds a computed value, and `to_jsonb(tgt) @> expected` fails on
-- every row of such a table.  That made archive-restored history unusable for
-- both undo and replay on any table with a generated column.
CREATE OR REPLACE FUNCTION volvra._derived_cols(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated <> ''
$$;

CREATE OR REPLACE FUNCTION volvra._meta(target regclass) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_build_object(
    'fq',       volvra._fqname(target),
    'cols',     to_jsonb(volvra._columns(target)),
    'setcols',  to_jsonb(volvra._setcols(target)),
    'pkcols',   to_jsonb(volvra._pkcols(target)),
    'derived',  to_jsonb(volvra._derived_cols(target)),
    'identity', volvra._has_system_identity(target))
$$;

-- ---------------------------------------------------------------------
-- Plan: the selected change set in reverse chronological order, each row
-- paired with the statement that puts it back.
--
-- Reverse chronological across every selected table, not per table: undoing a
-- transaction means walking it backwards as a whole.
--
-- p_guard   -- emit statements carrying the optimistic-concurrency guard
-- p_probe   -- additionally read each live row to report conflicts up front
--              (preview does this; undo relies on the guard instead, so it
--              costs one statement per row rather than two)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._plan(
  p_tables    regclass[]  DEFAULT NULL,
  p_from_ts   timestamptz DEFAULT NULL,
  p_to_ts     timestamptz DEFAULT NULL,
  p_txids     bigint[]    DEFAULT NULL,
  p_actors    text[]      DEFAULT NULL,
  p_db_users  text[]      DEFAULT NULL,
  p_predicate text        DEFAULT NULL,
  p_guard     boolean     DEFAULT true,
  p_probe     boolean     DEFAULT false,
  -- false builds the inverse of each change, newest first, which is an undo.
  -- true builds each change again in its original direction, oldest first,
  -- which is a replay.  The two are mirror images and share every part of
  -- this function deliberately: one plan builder, one guard, one apply loop,
  -- so a safety property cannot hold for one direction and not the other.
  p_replay    boolean     DEFAULT false)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_where    text := volvra._where(p_tables, p_from_ts, p_to_ts, p_txids,
                                   p_actors, p_db_users, p_predicate);
  v_cache    jsonb := '{}'::jsonb;   -- table_name -> metadata
  v_m        jsonb;
  v_rel      regclass;
  v_i        bigint := 0;
  v_step     volvra.undo_step;
  v_live     jsonb;
  v_cols     text[];
  v_setcols  text[];
  v_upcols   text[];
  v_pkcols   text[];
  v_derived  text[];
  -- The images a guard compares, with derived columns removed.
  v_gold     jsonb;
  v_gnew     jsonb;
  -- Undo walks backwards through history; replay walks forwards. Everything
  -- else about the two is identical.
  v_dir      text := CASE WHEN p_replay THEN 'ASC' ELSE 'DESC' END;
  v_img      jsonb;
  r          record;
BEGIN
  -- `newest` marks the most recent change to each row within this selection,
  -- which is the only change whose captured values can be compared against the
  -- live row.  It is computed here rather than accumulated in a loop variable:
  -- the previous version kept a jsonb object of every row it had seen and grew
  -- it by concatenation, one key per change.  jsonb concatenation copies the
  -- whole object, so that was quadratic in bytes copied -- around 500 GB of
  -- memcpy for a 200,000-row plan, which took over twenty minutes and looked
  -- like a hang.  A window function costs one sort.
  FOR r IN EXECUTE format(
    'SELECT c.id, c.table_name, c.op, c.pk, c.old_row, c.new_row, '
    '       c.actor, c.db_user, c.ts, '
    '       (row_number() OVER (PARTITION BY c.table_name, c.pk '
    '                           ORDER BY c.id %1$s) = 1) AS first_seen '
    'FROM volvra.change_log c WHERE %2$s ORDER BY c.id %1$s',
    v_dir, v_where)
  LOOP
    -- A TRUNCATE whose rows were never captured cannot be inverted, and
    -- stepping over it would produce a half-restored table that looks whole.
    IF r.op = 'T' THEN
      RAISE EXCEPTION 'volvra: this selection contains a TRUNCATE of % that was not captured',
        r.table_name
        USING DETAIL = format('change %s at %s', r.id, r.ts),
              HINT = 'The rows are unrecoverable from history. Select either side '
                     'of the truncate, or restore it from a backup.',
              ERRCODE = 'data_exception';
    END IF;

    IF NOT (v_cache ? r.table_name) THEN
      v_rel := to_regclass(r.table_name);
      IF v_rel IS NULL THEN
        RAISE EXCEPTION 'volvra: % no longer exists, so its history cannot be replayed',
          r.table_name
          USING ERRCODE = 'undefined_table';
      END IF;
      v_cache := v_cache || jsonb_build_object(r.table_name, volvra._meta(v_rel));
    END IF;

    v_m       := v_cache -> r.table_name;
    v_rel     := to_regclass(r.table_name);
    v_cols    := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'cols'));
    v_setcols := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'setcols'));
    v_pkcols  := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'pkcols'));
    v_derived := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'derived'));

    -- A guard never compares a derived column. Stripping here rather than in
    -- each builder means undo and replay cannot diverge on it.
    v_gold := CASE WHEN r.old_row IS NULL THEN NULL
                   WHEN v_derived = '{}' THEN r.old_row
                   ELSE r.old_row - v_derived END;
    v_gnew := CASE WHEN r.new_row IS NULL THEN NULL
                   WHEN v_derived = '{}' THEN r.new_row
                   ELSE r.new_row - v_derived END;

    IF cardinality(v_pkcols) = 0 THEN
      RAISE EXCEPTION 'volvra: % has no PRIMARY KEY', r.table_name;
    END IF;

    v_i := v_i + 1;
    v_step.seq        := v_i;
    v_step.change_id  := r.id;
    v_step.table_name := r.table_name;
    v_step.op         := r.op;
    v_step.pk         := r.pk;
    v_step.actor      := r.actor;
    v_step.db_user    := r.db_user;
    v_step.ts         := r.ts;
    v_step.status     := 'planned';
    v_step.conflict   := NULL;

    -- The statement is built from the table's CURRENT key, while the
    -- captured pk holds the key as it was.  Redefining the primary key
    -- therefore leaves the lookup with a NULL for the new column, no row
    -- matches, and the guard reports a conflict -- blaming a later change
    -- that never happened.  Say what actually changed instead.
    IF NOT (r.pk ?& v_pkcols) THEN
      RAISE EXCEPTION
        'volvra: the primary key of % has changed since this row was captured',
        r.table_name
        USING DETAIL = format(
                'captured key: %s; the key is now (%s)',
                r.pk::text, array_to_string(v_pkcols, ', ')),
              HINT = 'Rows captured under the old key cannot be located by the '
                     'new one. Restore them by hand, or narrow the window to '
                     'changes captured under the current key.',
              ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Validate the image this step will apply, which differs by direction:
    -- an undo writes the "before" image back, a replay writes the "after"
    -- image again.
    IF p_replay THEN
      v_img := CASE WHEN r.op = 'D' THEN r.old_row ELSE r.new_row END;
      IF v_img IS NULL THEN
        RAISE EXCEPTION 'volvra: change % on % carries no image to replay',
          r.id, r.table_name
          USING DETAIL = format('op %s has no %s image', r.op,
                                CASE WHEN r.op = 'D' THEN 'old_row' ELSE 'new_row' END),
                HINT = 'Redacted history cannot be replayed. Narrow the selection.',
                ERRCODE = 'data_exception';
      END IF;
      PERFORM volvra._validate_image(v_rel, v_img, r.op <> 'U');
    ELSIF r.op = 'U' THEN
      -- a delta drives an UPDATE, so it need not be complete
      PERFORM volvra._validate_image(v_rel, r.old_row, false);
    ELSE
      PERFORM volvra._validate_image(v_rel, coalesce(r.old_row, r.new_row), true);
    END IF;

    IF p_replay THEN
      -- The same three builders, with the images mirrored. An undo asserts
      -- the row still holds what was captured *after* the change and writes
      -- back what was there *before*; a replay asserts it still holds the
      -- *before* image and writes the *after* one. Neither can be built
      -- without a guard, which is what keeps a misapplied replay impossible
      -- rather than merely unlikely.
      v_step.inverse_op := r.op;
      IF r.op = 'I' THEN
        v_step.stmt := volvra._stmt_insert(
          r.table_name, v_cols, (v_m ->> 'identity')::boolean, r.new_row, p_guard);
      ELSIF r.op = 'D' THEN
        v_step.stmt := volvra._stmt_delete(
          r.table_name, v_pkcols, r.pk, CASE WHEN p_guard THEN v_gold END);
      ELSE
        v_upcols := ARRAY(
          SELECT k FROM jsonb_object_keys(r.new_row) AS k WHERE k = ANY (v_setcols));
        IF cardinality(v_upcols) = 0 THEN
          RAISE EXCEPTION 'volvra: change % on % carries no replayable column',
            r.id, r.table_name
            USING DETAIL = format('captured columns: %s', r.new_row),
                  ERRCODE = 'data_exception';
        END IF;
        v_step.stmt := volvra._stmt_update(
          r.table_name, v_upcols, v_pkcols, r.new_row, r.pk,
          CASE WHEN p_guard THEN v_gold END);
      END IF;

    ELSIF r.op = 'I' THEN
      v_step.inverse_op := 'D';
      v_step.stmt := volvra._stmt_delete(
        r.table_name, v_pkcols, r.pk, CASE WHEN p_guard THEN v_gnew END);
    ELSIF r.op = 'D' THEN
      v_step.inverse_op := 'I';
      v_step.stmt := volvra._stmt_insert(
        r.table_name, v_cols, (v_m ->> 'identity')::boolean, r.old_row, p_guard);
    ELSE
      v_step.inverse_op := 'U';

      -- The image's own keys, restricted to columns Postgres will let us
      -- assign.  For a pre-projection (full-image) row this is every updatable
      -- column, so migrated history keeps working unchanged.
      v_upcols := ARRAY(
        SELECT k FROM jsonb_object_keys(r.old_row) AS k WHERE k = ANY (v_setcols));

      IF cardinality(v_upcols) = 0 THEN
        RAISE EXCEPTION 'volvra: change % on % carries no restorable column',
          r.id, r.table_name
          USING DETAIL = format('captured columns: %s', r.old_row),
                ERRCODE = 'data_exception';
      END IF;

      v_step.stmt := volvra._stmt_update(
        r.table_name, v_upcols, v_pkcols, r.old_row, r.pk,
        CASE WHEN p_guard THEN v_gnew END);
    END IF;

    IF p_probe THEN
      -- Only the first change to a row *in application order* can be
      -- compared against the live row: for an undo that is the newest, for a
      -- replay the oldest. Later steps are reached only once the earlier ones
      -- have been applied, at which point the state matches by construction,
      -- so probing them against the *current* row reports conflicts that will
      -- not happen.
      IF NOT r.first_seen THEN
        v_step.conflict := false;
      ELSE
        EXECUTE volvra._stmt_probe(r.table_name, v_pkcols, r.pk) INTO v_live;
        v_step.conflict := CASE
          WHEN p_replay THEN CASE
            -- replaying an insert: the row must not be there yet
            WHEN r.op = 'I' THEN v_live IS NOT NULL
            -- replaying an update or a delete: the row must be there, still
            -- holding the image captured before the change
            WHEN v_live IS NULL THEN true
            ELSE NOT (v_live @> v_gold)
          END
          WHEN r.op = 'D' THEN v_live IS NOT NULL        -- should still be gone
          WHEN v_live IS NULL THEN true                  -- row vanished
          -- the captured columns must still hold their captured values; other
          -- columns having moved on is not a conflict
          ELSE NOT (v_live @> v_gnew)
        END;
      END IF;
    END IF;

    RETURN NEXT v_step;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- Scoping shared by preview_undo and undo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._resolve_tables(
  target regclass, tables regclass[]) RETURNS regclass[]
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN tables IS NOT NULL AND cardinality(tables) > 0 THEN
      CASE WHEN target IS NULL THEN tables ELSE tables || target END
    WHEN target IS NOT NULL THEN ARRAY[target]
    ELSE NULL
  END
$$;

-- Reading any plan means reading full row images, so the caller must be able to
-- read every table the plan touches -- checked per table, not once.
CREATE OR REPLACE FUNCTION volvra._require_read_all(p_tables regclass[])
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  t regclass;
BEGIN
  IF p_tables IS NOT NULL AND cardinality(p_tables) > 0 THEN
    FOREACH t IN ARRAY p_tables LOOP
      PERFORM volvra._require_read(t);
    END LOOP;
    RETURN;
  END IF;

  -- Unscoped: the caller must be able to read every covered table, or they
  -- would learn about the ones they cannot.
  FOR t IN SELECT volvra._resolve(e.table_name) FROM volvra.enabled_tables e
           WHERE volvra._resolve(e.table_name) IS NOT NULL
  LOOP
    PERFORM volvra._require_read(t);
  END LOOP;
END
$$;

-- An undo that finds nothing must say *why*.  "0 changes reverted" reads as
-- "nothing to undo, we are fine", when it may mean "I have no record of this
-- table at all" -- which during an incident is the opposite conclusion.
--
-- Three cases, deliberately distinguished: never covered (nothing exists, so
-- refuse), covered once but not now (history exists and undo is legitimate, but
-- the window may be short), and registered while the trigger is disabled (the
-- dangerous state).
CREATE OR REPLACE FUNCTION volvra._require_coverage(p_tables regclass[])
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  t             regclass;
  v_fq          text;
  v_registered  boolean;
  v_last        timestamptz;
  v_live        boolean;
BEGIN
  IF p_tables IS NULL OR cardinality(p_tables) = 0 THEN
    RETURN;   -- an unscoped selection is already restricted to covered tables
  END IF;

  FOREACH t IN ARRAY p_tables LOOP
    v_fq := volvra._fqname(t);

    SELECT EXISTS (SELECT 1 FROM volvra.enabled_tables e WHERE e.table_name = v_fq)
      INTO v_registered;

    SELECT max(c.ts) INTO v_last
    FROM volvra.change_log c WHERE c.table_name = v_fq;

    IF NOT v_registered AND v_last IS NULL THEN
      RAISE EXCEPTION 'volvra: % has never been covered, so there is nothing to undo',
        v_fq
        USING DETAIL = 'No changes to this table were ever captured. This is not '
                       'the same as finding no changes in the window.',
              HINT = 'volvra covers changes from the moment volvra.enable() runs. '
                     'See volvra.uncovered() for what else has no coverage.',
              ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT v_registered THEN
      RAISE NOTICE 'volvra: % is no longer covered -- history ends at %, and any '
                   'change since then was not captured', v_fq, v_last;
      CONTINUE;
    END IF;

    SELECT EXISTS (SELECT 1 FROM pg_trigger tg
                   WHERE tg.tgrelid = t AND tg.tgname = 'volvra_capture'
                     AND tg.tgenabled <> 'D')
      INTO v_live;

    IF NOT v_live THEN
      RAISE WARNING 'volvra: % is registered but its capture trigger is disabled '
                    '-- history ends at % and this undo may be incomplete',
        v_fq, v_last;
    END IF;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION volvra._require_scope(
  p_tables regclass[], p_from_ts timestamptz, p_to_ts timestamptz,
  p_txids bigint[], p_actors text[], p_db_users text[], p_predicate text)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_tables IS NULL AND p_from_ts IS NULL AND p_to_ts IS NULL
     AND p_txids IS NULL AND p_actors IS NULL AND p_db_users IS NULL
     AND (p_predicate IS NULL OR btrim(p_predicate) = '') THEN
    RAISE EXCEPTION 'volvra: refusing to plan an undo with no scope at all'
      USING HINT = 'Name a table, a time window, a txid, an actor, or a predicate.',
            ERRCODE = 'null_value_not_allowed';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- preview_undo -- never executes anything
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.preview_undo(
  target      regclass    DEFAULT NULL,
  from_ts     timestamptz DEFAULT NULL,
  to_ts       timestamptz DEFAULT NULL,
  txid        bigint      DEFAULT NULL,
  actor       text        DEFAULT NULL,
  db_user     text        DEFAULT NULL,
  predicate   text        DEFAULT NULL,
  tables      regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables    regclass[] := volvra._resolve_tables(target, tables);
  v_txids     bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors    text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers   text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_count     bigint;
  v_conflicts bigint;
  v_tabcount  bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);
  PERFORM volvra._require_coverage(v_tables);

  SELECT count(*), count(*) FILTER (WHERE p.conflict), count(DISTINCT p.table_name)
    INTO v_count, v_conflicts, v_tabcount
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, true) p;

  IF v_conflicts > 0 THEN
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be reverted, but % row(s) '
                 'have changed since -- undo will refuse unless you pass skip_conflicts => true',
      v_count, v_tabcount, v_conflicts;
  ELSE
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be reverted '
                 '(preview only, nothing executed)', v_count, v_tabcount;
  END IF;

  RETURN QUERY
    SELECT * FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors,
                               v_dbusers, predicate, true, true);
END
$$;

-- ---------------------------------------------------------------------
-- undo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.undo(
  target         regclass    DEFAULT NULL,
  from_ts        timestamptz DEFAULT NULL,
  to_ts          timestamptz DEFAULT NULL,
  confirm        boolean     DEFAULT false,
  max_rows       integer     DEFAULT NULL,
  -- On a row that has moved on since it was captured: refuse the whole undo
  -- (default), or revert everything else and leave that row alone.  There is
  -- deliberately no "overwrite anyway" option -- that is the data loss the
  -- conflict guard exists to prevent.
  skip_conflicts boolean     DEFAULT false,
  txid           bigint      DEFAULT NULL,
  actor          text        DEFAULT NULL,
  db_user        text        DEFAULT NULL,
  predicate      text        DEFAULT NULL,
  tables         regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables  regclass[] := volvra._resolve_tables(target, tables);
  v_txids   bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors  text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_cap     bigint := coalesce(max_rows, volvra.get_setting('max_undo_rows')::bigint, 10000);
  v_plan    volvra.undo_step[];
  v_step    volvra.undo_step;
  v_count   bigint;
  v_tabs    text[];
  v_skipped bigint := 0;
  v_rc      bigint;
  v_lock    text;
BEGIN
  IF confirm THEN
    PERFORM volvra._require('volvra_operator');
  ELSE
    PERFORM volvra._require('volvra_viewer');
  END IF;
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);
  PERFORM volvra._require_coverage(v_tables);

  IF from_ts IS NOT NULL AND to_ts IS NOT NULL AND from_ts >= to_ts THEN
    RAISE EXCEPTION 'volvra.undo: empty window (from_ts % >= to_ts %)', from_ts, to_ts;
  END IF;

  -- Build the plan exactly once.  The blast-radius cap has to be checked before
  -- anything is applied, which is why this is materialised rather than streamed.
  SELECT coalesce(array_agg(p ORDER BY p.seq), '{}')
    INTO v_plan
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, NOT confirm) p;

  v_count := cardinality(v_plan);

  SELECT array_agg(DISTINCT s.table_name ORDER BY s.table_name)
    INTO v_tabs FROM unnest(v_plan) AS s;

  IF v_count > v_cap THEN
    RAISE EXCEPTION 'volvra.undo: % rows exceeds cap of %', v_count, v_cap
      USING HINT = 'Narrow the selection, or pass max_rows => N to override deliberately.',
            ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO volvra.undo_log
    (actor, table_name, from_ts, to_ts, row_count, confirmed, cap, cap_override, db_user)
  VALUES (volvra._actor(),
          coalesce(array_to_string(v_tabs, ', '), '(none)'),
          from_ts, to_ts, v_count, confirm, v_cap,
          max_rows IS NOT NULL, volvra._db_user());

  IF NOT confirm THEN
    RAISE NOTICE 'volvra: % change(s) would be reverted. '
                 'Nothing executed -- re-run with confirm => true.', v_count;
    RETURN QUERY SELECT * FROM unnest(v_plan);
    RETURN;
  END IF;

  -- Serialise undos table by table, in a stable order so two concurrent undos
  -- of overlapping selections queue rather than deadlock.  Concurrent *writers*
  -- need no lock: the per-statement guard turns them into conflicts, not races.
  IF v_tabs IS NOT NULL THEN
    FOREACH v_lock IN ARRAY v_tabs LOOP
      PERFORM pg_advisory_xact_lock(hashtextextended('volvra:' || v_lock, 0));
    END LOOP;
  END IF;

  -- Reverse-chronological order is right for the data but can trip a foreign
  -- key when a plan spans related tables -- undoing a cascade wants the parent
  -- back before its children.  Deferring the checks to COMMIT sidesteps the
  -- ordering entirely, but only works for constraints declared DEFERRABLE,
  -- which is what volvra.make_fks_deferrable() is for.
  BEGIN
    SET CONSTRAINTS ALL DEFERRED;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  FOREACH v_step IN ARRAY v_plan LOOP
    BEGIN
      EXECUTE v_step.stmt;
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'volvra.undo: a foreign key blocked reverting %', v_step.table_name
        USING DETAIL = format('row %s (change %s): %s', v_step.pk, v_step.change_id, SQLERRM),
              HINT = 'This plan spans related tables and the constraint is not '
                     'DEFERRABLE. Run volvra.make_fks_deferrable() once as an '
                     'admin, or undo one table at a time in dependency order.',
              ERRCODE = 'foreign_key_violation';
    END;
    GET DIAGNOSTICS v_rc = ROW_COUNT;

    IF v_rc = 1 THEN
      v_step.status   := 'applied';
      v_step.conflict := false;
    ELSIF skip_conflicts THEN
      -- apply what can still be applied; a row that moved on is left alone,
      -- never guessed at.
      v_step.status   := 'skipped';
      v_step.conflict := true;
      v_skipped       := v_skipped + 1;
    ELSE
      RAISE EXCEPTION 'volvra.undo: % has changed since it was captured', v_step.table_name
        USING DETAIL = format('row %s (change %s, %s by %s) no longer matches the '
                              'captured image, so reverting it would destroy a '
                              'later change',
                              v_step.pk, v_step.change_id, v_step.ts, v_step.db_user),
              HINT = 'Run preview_undo to see every conflicting row, narrow the '
                     'selection, or pass skip_conflicts => true to revert the rest '
                     'and leave these alone.',
              ERRCODE = 'serialization_failure';
    END IF;

    RETURN NEXT v_step;
  END LOOP;

  IF v_skipped > 0 THEN
    RAISE NOTICE 'volvra: reverted % change(s) across %, skipped % that had moved on',
      v_count - v_skipped, coalesce(array_to_string(v_tabs, ', '), 'nothing'), v_skipped;
  ELSE
    RAISE NOTICE 'volvra: reverted % change(s) across %',
      v_count, coalesce(array_to_string(v_tabs, ', '), 'nothing');
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- Replay: the mirror of undo
--
-- undo() walks history backwards and applies the inverse of each change.
-- replay() walks it forwards and applies each change again.  They share
-- volvra._plan(), the conflict guard, the blast-radius cap, the advisory
-- locks and the apply loop, because a safety property that held for one
-- direction and not the other would be worse than no property at all.
--
-- What replay is for: a database recovered from a backup that predates
-- changes you still hold history for.  Restore the archive, then replay the
-- window forward to carry the database past the backup.  It is not
-- point-in-time recovery and does not pretend to be: it reapplies changes to
-- covered tables only, and refuses any change it cannot apply exactly.
--
-- The guard is the whole safety argument.  Every statement asserts that the
-- row still holds the image captured *before* the change, by jsonb
-- containment, and a statement that matches no row is a conflict rather than
-- a silent no-op.  A replay therefore cannot write over a row that has moved
-- on, cannot apply a change twice, and cannot apply half of a selection: the
-- whole thing is one transaction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.replay(
  target         regclass    DEFAULT NULL,
  from_ts        timestamptz DEFAULT NULL,
  to_ts          timestamptz DEFAULT NULL,
  confirm        boolean     DEFAULT false,
  max_rows       integer     DEFAULT NULL,
  -- On a row that does not hold the image captured before the change: refuse
  -- the whole replay (default), or apply everything else and leave that row
  -- alone.  There is deliberately no "apply anyway" option -- reapplying a
  -- change over a row that has moved on is precisely how a replay would
  -- corrupt data.
  skip_conflicts boolean     DEFAULT false,
  txid           bigint      DEFAULT NULL,
  actor          text        DEFAULT NULL,
  db_user        text        DEFAULT NULL,
  predicate      text        DEFAULT NULL,
  tables         regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables  regclass[] := volvra._resolve_tables(target, tables);
  v_txids   bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors  text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_cap     bigint := coalesce(max_rows, volvra.get_setting('max_undo_rows')::bigint, 10000);
  v_plan    volvra.undo_step[];
  v_step    volvra.undo_step;
  v_count   bigint;
  v_tabs    text[];
  v_skipped bigint := 0;
  v_rc      bigint;
  v_lock    text;
  v_live    jsonb;
BEGIN
  IF confirm THEN
    PERFORM volvra._require('volvra_operator');
  ELSE
    PERFORM volvra._require('volvra_viewer');
  END IF;
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);
  PERFORM volvra._require_coverage(v_tables);

  IF from_ts IS NOT NULL AND to_ts IS NOT NULL AND from_ts >= to_ts THEN
    RAISE EXCEPTION 'volvra.replay: empty window (from_ts % >= to_ts %)', from_ts, to_ts;
  END IF;

  -- Build the plan exactly once.  The blast-radius cap has to be checked before
  -- anything is applied, which is why this is materialised rather than streamed.
  SELECT coalesce(array_agg(p ORDER BY p.seq), '{}')
    INTO v_plan
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, NOT confirm, p_replay => true) p;

  v_count := cardinality(v_plan);

  SELECT array_agg(DISTINCT s.table_name ORDER BY s.table_name)
    INTO v_tabs FROM unnest(v_plan) AS s;

  IF v_count > v_cap THEN
    RAISE EXCEPTION 'volvra.replay: % rows exceeds cap of %', v_count, v_cap
      USING HINT = 'Narrow the selection, or pass max_rows => N to override deliberately.',
            ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO volvra.undo_log
    (actor, table_name, from_ts, to_ts, row_count, confirmed, cap, cap_override,
     db_user, operation)
  VALUES (volvra._actor(),
          coalesce(array_to_string(v_tabs, ', '), '(none)'),
          from_ts, to_ts, v_count, confirm, v_cap,
          max_rows IS NOT NULL, volvra._db_user(), 'replay');

  IF NOT confirm THEN
    RAISE NOTICE 'volvra: % change(s) would be replayed. '
                 'Nothing executed -- re-run with confirm => true.', v_count;
    RETURN QUERY SELECT * FROM unnest(v_plan);
    RETURN;
  END IF;

  -- Serialise replays table by table, in a stable order so two concurrent replays
  -- of overlapping selections queue rather than deadlock.  Concurrent *writers*
  -- need no lock: the per-statement guard turns them into conflicts, not races.
  IF v_tabs IS NOT NULL THEN
    FOREACH v_lock IN ARRAY v_tabs LOOP
      PERFORM pg_advisory_xact_lock(hashtextextended('volvra:' || v_lock, 0));
    END LOOP;
  END IF;

  -- Reverse-chronological order is right for the data but can trip a foreign
  -- key when a plan spans related tables -- replaying a cascade wants the parent
  -- back before its children.  Deferring the checks to COMMIT sidesteps the
  -- ordering entirely, but only works for constraints declared DEFERRABLE,
  -- which is what volvra.make_fks_deferrable() is for.
  BEGIN
    SET CONSTRAINTS ALL DEFERRED;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  FOREACH v_step IN ARRAY v_plan LOOP
    BEGIN
      EXECUTE v_step.stmt;
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'volvra.replay: a foreign key blocked replaying %', v_step.table_name
        USING DETAIL = format('row %s (change %s): %s', v_step.pk, v_step.change_id, SQLERRM),
              HINT = 'This plan spans related tables and the constraint is not '
                     'DEFERRABLE. Run volvra.make_fks_deferrable() once as an '
                     'admin, or replay one table at a time in dependency order.',
              ERRCODE = 'foreign_key_violation';
    END;
    GET DIAGNOSTICS v_rc = ROW_COUNT;

    -- A delete that matched nothing needs one more question asked before it is
    -- called a conflict: is the row absent, or present but different?
    --
    -- Absent means the delete's goal is already met, and the commonest way
    -- that happens is a cascade. PostgreSQL records the parent delete before
    -- the child deletes it triggered, so replaying the parent re-fires the
    -- cascade and the recorded child deletes find nothing left to do. Calling
    -- those conflicts would make every cascade unreplayable without weakening
    -- the guard for the whole operation.
    --
    -- Present but different is a real conflict: something else is living at
    -- that key, and deleting it would destroy data this replay knows nothing
    -- about. Only absence is treated as satisfied.
    IF v_rc = 0 AND v_step.inverse_op = 'D' THEN
      EXECUTE volvra._stmt_probe(v_step.table_name,
                ARRAY(SELECT jsonb_object_keys(v_step.pk)), v_step.pk)
        INTO v_live;
      IF v_live IS NULL THEN
        v_step.status   := 'satisfied';
        v_step.conflict := false;
        RETURN NEXT v_step;
        CONTINUE;
      END IF;
    END IF;

    IF v_rc = 1 THEN
      v_step.status   := 'applied';
      v_step.conflict := false;
    ELSIF skip_conflicts THEN
      -- apply what can still be applied; a row that moved on is left alone,
      -- never guessed at.
      v_step.status   := 'skipped';
      v_step.conflict := true;
      v_skipped       := v_skipped + 1;
    ELSE
      RAISE EXCEPTION 'volvra.replay: % has moved on since this change was captured',
        v_step.table_name
        USING DETAIL = format('row %s (change %s, %s by %s) does not hold the image '
                              'captured before that change, so replaying it would '
                              'overwrite whatever is there now',
                              v_step.pk, v_step.change_id, v_step.ts, v_step.db_user),
              HINT = 'Run preview_replay to see every conflicting row, narrow '
                     'the selection, or pass skip_conflicts => true to apply the '
                     'rest and leave these alone.',
              ERRCODE = 'serialization_failure';
    END IF;

    RETURN NEXT v_step;
  END LOOP;

  IF v_skipped > 0 THEN
    RAISE NOTICE 'volvra: replayed % change(s) across %, skipped % that had moved on',
      v_count - v_skipped, coalesce(array_to_string(v_tabs, ', '), 'nothing'), v_skipped;
  ELSE
    RAISE NOTICE 'volvra: replayed % change(s) across %',
      v_count, coalesce(array_to_string(v_tabs, ', '), 'nothing');
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION volvra.preview_replay(
  target      regclass    DEFAULT NULL,
  from_ts     timestamptz DEFAULT NULL,
  to_ts       timestamptz DEFAULT NULL,
  txid        bigint      DEFAULT NULL,
  actor       text        DEFAULT NULL,
  db_user     text        DEFAULT NULL,
  predicate   text        DEFAULT NULL,
  tables      regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables    regclass[] := volvra._resolve_tables(target, tables);
  v_txids     bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors    text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers   text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_count     bigint;
  v_conflicts bigint;
  v_tabcount  bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);
  PERFORM volvra._require_coverage(v_tables);

  SELECT count(*), count(*) FILTER (WHERE p.conflict), count(DISTINCT p.table_name)
    INTO v_count, v_conflicts, v_tabcount
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, true, p_replay => true) p;

  IF v_conflicts > 0 THEN
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be replayed, but % row(s) '
                 'do not hold the image captured before the change -- replay will '
                 'refuse unless you pass skip_conflicts => true',
      v_count, v_tabcount, v_conflicts;
  ELSE
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be replayed '
                 '(preview only, nothing executed)', v_count, v_tabcount;
  END IF;

  RETURN QUERY
    SELECT * FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors,
                               v_dbusers, predicate, true, true, p_replay => true);
END
$$;

-- ---------------------------------------------------------------------
-- Marks: naming a moment you might want to come back to
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.mark(
  p_name    text,
  p_note    text    DEFAULT NULL,
  p_replace boolean DEFAULT false)
RETURNS timestamptz
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_at timestamptz := clock_timestamp();
BEGIN
  PERFORM volvra._require('volvra_operator');

  IF p_replace THEN
    INSERT INTO volvra.restore_point AS r (name, at, note)
    VALUES (p_name, v_at, p_note)
    ON CONFLICT (name) DO UPDATE
      SET at = EXCLUDED.at, created_by = current_user, note = EXCLUDED.note;
    RETURN v_at;
  END IF;

  -- Refuse rather than silently move an existing mark: a restore point people
  -- believe in, quietly relocated, is worse than an error.
  BEGIN
    INSERT INTO volvra.restore_point (name, at, note) VALUES (p_name, v_at, p_note);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'volvra: a mark named % already exists, taken at %',
      p_name, (SELECT at FROM volvra.restore_point WHERE name = p_name)
      USING HINT = 'Use a different name, pass p_replace => true to move it, '
                   'or volvra.unmark() to remove it.',
            ERRCODE = 'unique_violation';
  END;

  RETURN v_at;
END
$$;

CREATE OR REPLACE FUNCTION volvra.unmark(p_name text) RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_found boolean;
BEGIN
  PERFORM volvra._require('volvra_operator');
  DELETE FROM volvra.restore_point WHERE name = p_name;
  v_found := FOUND;
  -- Removing a mark removes a pointer, never history.
  RETURN v_found;
END
$$;

-- Every mark, and what undoing to it would cost.  The count is the point: it
-- answers "how much am I about to touch" before anyone commits to it, rather
-- than leaving each caller to remember to run a preview.
CREATE OR REPLACE FUNCTION volvra.marks()
RETURNS TABLE (
  name          text,
  at            timestamptz,
  age           interval,
  created_by    text,
  changes_since bigint,
  tables_since  bigint,
  note          text
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT r.name,
           r.at,
           clock_timestamp() - r.at,
           r.created_by,
           -- Restricted to tables the caller may read, like every other read.
           (SELECT count(*) FROM volvra.change_log c
            WHERE c.ts > r.at
              AND c.table_name IN (SELECT t.table_name
                                   FROM volvra._readable_tables() t)),
           (SELECT count(DISTINCT c.table_name) FROM volvra.change_log c
            WHERE c.ts > r.at
              AND c.table_name IN (SELECT t.table_name
                                   FROM volvra._readable_tables() t)),
           r.note
    FROM volvra.restore_point r
    ORDER BY r.at DESC;
END
$$;

-- Undo from a mark to now.  Everything undo() offers applies, including the
-- conflict guard, the blast-radius cap and preview-by-default.
CREATE OR REPLACE FUNCTION volvra.undo_to(
  p_name         text,
  target         regclass   DEFAULT NULL,
  confirm        boolean    DEFAULT false,
  max_rows       integer    DEFAULT NULL,
  skip_conflicts boolean    DEFAULT false,
  tables         regclass[] DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_at timestamptz;
BEGIN
  SELECT r.at INTO v_at FROM volvra.restore_point r WHERE r.name = p_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'volvra: no mark named %', p_name
      USING HINT = 'See volvra.marks() for the marks that exist.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  RETURN QUERY
    SELECT * FROM volvra.undo(target => target, from_ts => v_at, to_ts => now(),
                              confirm => confirm, max_rows => max_rows,
                              skip_conflicts => skip_conflicts, tables => tables);
END
$$;

CREATE OR REPLACE FUNCTION volvra.preview_undo_to(
  p_name text,
  target regclass   DEFAULT NULL,
  tables regclass[] DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_at timestamptz;
BEGIN
  SELECT r.at INTO v_at FROM volvra.restore_point r WHERE r.name = p_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'volvra: no mark named %', p_name
      USING HINT = 'See volvra.marks() for the marks that exist.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  RETURN QUERY
    SELECT * FROM volvra.preview_undo(target => target, from_ts => v_at,
                                      to_ts => now(), tables => tables);
END
$$;

-- ---------------------------------------------------------------------
-- undo_txid -- "undo that migration"
--
-- The whole point of phase 2: one transaction is the unit a person actually
-- remembers, and it spans every table the migration touched.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.undo_txid(
  p_txid         bigint,
  confirm        boolean DEFAULT false,
  max_rows       integer DEFAULT NULL,
  skip_conflicts boolean DEFAULT false)
RETURNS SETOF volvra.undo_step
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT * FROM volvra.undo(txid => p_txid, confirm => confirm,
                            max_rows => max_rows, skip_conflicts => skip_conflicts)
$$;

CREATE OR REPLACE FUNCTION volvra.preview_undo_txid(p_txid bigint)
RETURNS SETOF volvra.undo_step
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT * FROM volvra.preview_undo(txid => p_txid)
$$;

-- ---------------------------------------------------------------------
-- transactions -- find the mistake before you undo it
--
-- Transaction-scoped undo is only usable if you can see which transaction was
-- the bad one.  This is that list.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.transactions(
  from_ts timestamptz DEFAULT NULL,
  to_ts   timestamptz DEFAULT NULL,
  p_limit integer     DEFAULT 25)
RETURNS TABLE (
  txid        bigint,
  started     timestamptz,
  ended       timestamptz,
  actors      text[],
  db_users    text[],
  tables      text[],
  inserts     bigint,
  updates     bigint,
  deletes     bigint,
  changes     bigint
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT c.txid,
           min(c.ts), max(c.ts),
           array_agg(DISTINCT c.actor   ORDER BY c.actor),
           array_agg(DISTINCT c.db_user ORDER BY c.db_user),
           array_agg(DISTINCT c.table_name ORDER BY c.table_name),
           count(*) FILTER (WHERE c.op = 'I'),
           count(*) FILTER (WHERE c.op = 'U'),
           count(*) FILTER (WHERE c.op = 'D'),
           count(*)
    FROM volvra.change_log c
    WHERE (from_ts IS NULL OR c.ts >  from_ts)
      AND (to_ts   IS NULL OR c.ts <= to_ts)
    GROUP BY c.txid
    ORDER BY max(c.ts) DESC
    LIMIT p_limit;
END
$$;

-- ---------------------------------------------------------------------
-- Retention
--
-- Dropping a whole partition is the only way to reclaim history at scale; a
-- mass DELETE through the append-only guard is the slowest path there is.  So
-- purge() drops every partition that lies entirely behind the cutoff, and only
-- falls back to DELETE for the partition that straddles it and for anything in
-- the default partition.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.set_retention(target regclass, keep_for interval)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl text := volvra._fqname(target);
BEGIN
  PERFORM volvra._require('volvra_admin');
  INSERT INTO volvra.retention AS r (table_name, keep_for)
  VALUES (v_tbl, keep_for)
  ON CONFLICT (table_name) DO UPDATE
    SET keep_for = EXCLUDED.keep_for, set_at = now(), set_by = current_user;
  RETURN format('volvra: keeping %s of history for %s', keep_for, v_tbl);
END
$$;

-- Time-window purge.  Kept as the primary entry point because "forget
-- everything older than X" is the request people actually have.
CREATE OR REPLACE FUNCTION volvra.purge(older_than interval)
RETURNS TABLE (action text, object text, rows_removed bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_cutoff timestamptz := now() - older_than;
  r        record;
  v_n      bigint;
  v_lo     bigint;
  v_hi     bigint;
BEGIN
  PERFORM volvra._require('volvra_admin');

  -- Whole partitions first: metadata-only, no row scan, no bloat.
  FOR r IN
    SELECT c.relname,
           -- the partition's exclusive upper bound
           (regexp_match(pg_get_expr(c.relpartbound, c.oid),
                         'TO \(''([^'']+)''\)'))[1] AS upper_bound
    FROM pg_class c
    JOIN pg_inherits i ON i.inhrelid = c.oid
    WHERE i.inhparent = 'volvra.change_log'::regclass
      AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE 'DEFAULT%'
    ORDER BY c.relname
  LOOP
    IF r.upper_bound IS NOT NULL
       AND r.upper_bound::timestamptz <= v_cutoff THEN
      EXECUTE format('SELECT count(*), min(id), max(id) FROM volvra.%I', r.relname)
        INTO v_n, v_lo, v_hi;
      EXECUTE format('DROP TABLE volvra.%I', r.relname);

      INSERT INTO volvra.retention_log
        (cutoff, scope, object, from_id, to_id, rows_removed)
      VALUES (v_cutoff, 'partition', r.relname, v_lo, v_hi, v_n);

      action := 'dropped partition'; object := r.relname; rows_removed := v_n;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- Then the straddling partition and the default one, row by row.
  PERFORM set_config('volvra.allow_purge', 'on', true);
  WITH gone AS (
    DELETE FROM volvra.change_log WHERE ts < v_cutoff RETURNING id
  ) SELECT count(*), min(id), max(id) INTO v_n, v_lo, v_hi FROM gone;
  PERFORM set_config('volvra.allow_purge', 'off', true);

  IF v_n > 0 THEN
    INSERT INTO volvra.retention_log
      (cutoff, scope, object, from_id, to_id, rows_removed)
    VALUES (v_cutoff, 'rows', 'volvra.change_log', v_lo, v_hi, v_n);

    action := 'deleted rows'; object := 'volvra.change_log'; rows_removed := v_n;
    RETURN NEXT;
  END IF;

  -- The audit trail is small but not immortal.
  PERFORM set_config('volvra.allow_purge', 'on', true);
  WITH gone AS (
    DELETE FROM volvra.undo_log WHERE ts < v_cutoff RETURNING 1
  ) SELECT count(*) INTO v_n FROM gone;
  PERFORM set_config('volvra.allow_purge', 'off', true);

  IF v_n > 0 THEN
    action := 'deleted rows'; object := 'volvra.undo_log'; rows_removed := v_n;
    RETURN NEXT;
  END IF;
END
$$;

-- Policy-driven purge: apply volvra.retention per table, and
-- settings.retention_default to everything else.  This is what you schedule.
CREATE OR REPLACE FUNCTION volvra.purge()
RETURNS TABLE (table_name text, keep_for interval, rows_removed bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_default interval := coalesce(volvra.get_setting('retention_default')::interval,
                                 '90 days'::interval);
  r    record;
  v_n  bigint;
  v_lo bigint;
  v_hi bigint;
BEGIN
  PERFORM volvra._require('volvra_admin');
  PERFORM set_config('volvra.allow_purge', 'on', true);

  FOR r IN
    SELECT e.table_name AS tbl,
           coalesce(ret.keep_for, v_default) AS keep
    FROM volvra.enabled_tables e
    LEFT JOIN volvra.retention ret ON ret.table_name = e.table_name
    ORDER BY e.table_name
  LOOP
    WITH gone AS (
      DELETE FROM volvra.change_log c
      WHERE c.table_name = r.tbl AND c.ts < now() - r.keep
      RETURNING id
    ) SELECT count(*), min(id), max(id) INTO v_n, v_lo, v_hi FROM gone;

    IF v_n > 0 THEN
      INSERT INTO volvra.retention_log
        (cutoff, scope, object, from_id, to_id, rows_removed)
      VALUES (now() - r.keep, 'rows', r.tbl, v_lo, v_hi, v_n);
    END IF;

    table_name := r.tbl; keep_for := r.keep; rows_removed := v_n;
    RETURN NEXT;
  END LOOP;

  PERFORM set_config('volvra.allow_purge', 'off', true);

  -- Any partition left completely empty is now pure overhead.
  PERFORM volvra._drop_empty_partitions();
END
$$;

CREATE OR REPLACE FUNCTION volvra._drop_empty_partitions() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r        record;
  v_any    boolean;
  v_count  bigint := 0;
  v_thismo text := volvra._partition_name(now()::date);
BEGIN
  FOR r IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_inherits i ON i.inhrelid = c.oid
    WHERE i.inhparent = 'volvra.change_log'::regclass
      AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE 'DEFAULT%'
      AND c.relname <> v_thismo          -- never drop the month being written
      AND c.relname < v_thismo           -- nor any future month
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM volvra.%I)', r.relname) INTO v_any;
    IF NOT v_any THEN
      EXECUTE format('DROP TABLE volvra.%I', r.relname);
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END
$$;

-- ---------------------------------------------------------------------
-- Right to erasure
--
-- Retention answers "forget everything older than X".  A subject access or
-- deletion request names a *person*, which is a different question, and one
-- that time-based retention cannot answer at all.
--
-- Redaction is the default: the row stays, its content goes.  That keeps the
-- fact that a change happened -- usually what an audit regime requires -- while
-- removing the personal data.  Use hard => true when the primary key is itself
-- personal data, because a redacted row still carries its pk.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.forget(
  target regclass,
  subject_pk jsonb,
  hard boolean DEFAULT false,
  reason text DEFAULT NULL)
RETURNS TABLE (mode text, rows_erased bigint, from_id bigint, to_id bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl  text := volvra._fqname(target);
  v_from bigint;
  v_to   bigint;
  v_n    bigint;
BEGIN
  PERFORM volvra._require('volvra_admin');

  SELECT min(c.id), max(c.id), count(*)
    INTO v_from, v_to, v_n
  FROM volvra.change_log c
  WHERE c.table_name = v_tbl AND c.pk @> subject_pk;

  IF coalesce(v_n, 0) = 0 THEN
    mode := CASE WHEN hard THEN 'hard' ELSE 'redact' END;
    rows_erased := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Recorded before the change, so an erasure that fails midway still leaves a
  -- ledger entry explaining the attempt.
  INSERT INTO volvra.erasure_log
    (table_name, subject_pk, mode, from_id, to_id, rows_erased, reason)
  VALUES (v_tbl, subject_pk, CASE WHEN hard THEN 'hard' ELSE 'redact' END,
          v_from, v_to, v_n, reason);

  PERFORM set_config('volvra.allow_purge', 'on', true);

  IF hard THEN
    DELETE FROM volvra.change_log c
    WHERE c.table_name = v_tbl AND c.pk @> subject_pk;
  ELSE
    UPDATE volvra.change_log c
       SET old_row = NULL,
           new_row = NULL,
           actor   = 'erased',
           redacted_at = clock_timestamp(),
           redacted_by = current_user
     WHERE c.table_name = v_tbl AND c.pk @> subject_pk
       AND c.redacted_at IS NULL;
  END IF;

  PERFORM set_config('volvra.allow_purge', 'off', true);

  mode        := CASE WHEN hard THEN 'hard' ELSE 'redact' END;
  rows_erased := v_n;
  from_id     := v_from;
  to_id       := v_to;
  RETURN NEXT;
END
$$;

-- Per-table override for capture_updates.  The trade-off flips with row width:
-- storing only the delta saves a lot on a wide row and costs a little on a
-- narrow one, so a narrow write-hot table can opt into full images while
-- everything else stays lean.
CREATE OR REPLACE FUNCTION volvra.set_capture_mode(
  target regclass, p_mode text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl text := volvra._fqname(target);
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF p_mode IS NOT NULL AND p_mode NOT IN ('changed', 'full') THEN
    RAISE EXCEPTION 'volvra: capture mode must be ''changed'', ''full'' or NULL, got %',
      p_mode
      USING HINT = 'NULL means fall back to the capture_updates setting.',
            ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE volvra.enabled_tables e SET update_mode = p_mode
   WHERE e.table_name = v_tbl;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'volvra: % is not covered; call volvra.enable() first', v_tbl;
  END IF;

  RETURN format('volvra: %s captures %s', v_tbl,
                coalesce(p_mode || ' images',
                         'whatever capture_updates says ('
                         || coalesce(volvra.get_setting('capture_updates'), 'changed')
                         || ')'));
END
$$;

-- ---------------------------------------------------------------------
-- Column exclusion
--
-- For data you are not permitted to keep a second copy of.  The cost is
-- honest and unavoidable: a column that is never captured cannot be restored,
-- and if it is NOT NULL then undoing a DELETE on that table becomes
-- impossible -- which this refuses to let you discover later.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.exclude_columns(
  target regclass, p_columns text[])
RETURNS TABLE (table_name text, excluded text[], warning text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl     text := volvra._fqname(target);
  v_pkcols  text[] := volvra._pkcols(target);
  v_unknown text[];
  v_pkclash text[];
  v_required text[];
BEGIN
  PERFORM volvra._require('volvra_admin');

  SELECT array_agg(c) INTO v_unknown
  FROM unnest(p_columns) AS c
  WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = target AND a.attname = c
                      AND a.attnum > 0 AND NOT a.attisdropped);
  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION 'volvra: % has no column(s) %', v_tbl,
      array_to_string(v_unknown, ', ')
      USING ERRCODE = 'undefined_column';
  END IF;

  SELECT array_agg(c) INTO v_pkclash
  FROM unnest(p_columns) AS c WHERE c = ANY (v_pkcols);
  IF v_pkclash IS NOT NULL THEN
    RAISE EXCEPTION 'volvra: cannot exclude primary key column(s) % from %',
      array_to_string(v_pkclash, ', '), v_tbl
      USING HINT = 'The pk is how a row is identified. If the key itself is '
                   'personal data, use volvra.forget(..., hard => true).',
            ERRCODE = 'invalid_column_reference';
  END IF;

  UPDATE volvra.enabled_tables e
     SET excluded_columns = p_columns
   WHERE e.table_name = v_tbl;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'volvra: % is not covered; call volvra.enable() first', v_tbl;
  END IF;

  -- Say the cost out loud, now, rather than at the moment someone needs the
  -- row back.
  SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO v_required
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attname::text = ANY (p_columns)
    AND a.attnotnull AND NOT a.atthasdef
    AND a.attgenerated = '' AND a.attidentity = '';

  table_name := v_tbl;
  excluded   := p_columns;
  warning    := CASE
    WHEN v_required IS NOT NULL THEN
      format('%s is NOT NULL with no default, so a DELETE on %s can no longer '
             'be undone -- the row cannot be rebuilt without it',
             array_to_string(v_required, ', '), v_tbl)
    ELSE NULL END;

  IF warning IS NOT NULL THEN
    RAISE WARNING 'volvra: %', warning;
  END IF;

  RETURN NEXT;
END
$$;

-- ---------------------------------------------------------------------
-- Tamper evidence: sealing and verification
--
-- SECURITY DEFINER because a verifier has to hash *every* row, including those
-- row-level security would hide from the caller -- and it returns verdicts,
-- never content.
-- ---------------------------------------------------------------------

-- The canonical byte string for one change.  Everything in it is
-- timezone- and locale-independent: jsonb renders canonically, and ts becomes
-- an epoch rather than a formatted timestamp.
CREATE OR REPLACE FUNCTION volvra._row_repr(
  p_id bigint, p_table text, p_op char(1), p_pk jsonb,
  p_old jsonb, p_new jsonb, p_actor text, p_db_user text,
  p_txid bigint, p_ts timestamptz, p_redacted_at timestamptz)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT concat_ws('|',
    p_id, p_table, p_op, p_pk::text,
    coalesce(p_old::text, ''), coalesce(p_new::text, ''),
    p_actor, p_db_user, p_txid,
    extract(epoch FROM p_ts)::numeric,
    coalesce(extract(epoch FROM p_redacted_at)::numeric::text, ''))
$$;

CREATE OR REPLACE FUNCTION volvra._sha(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT encode(sha256(convert_to(coalesce(p_text, ''), 'UTF8')), 'hex') $$;

-- Hash a span of the log.  Folded row by row so that memory does not grow with
-- the span -- sealing a month of history must not need a month of history in
-- memory.
CREATE OR REPLACE FUNCTION volvra._hash_span(p_from bigint, p_to bigint)
RETURNS TABLE (content_hash text, row_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_hash text := '';
  v_n    bigint := 0;
  r      record;
BEGIN
  FOR r IN
    SELECT c.id, c.table_name, c.op, c.pk, c.old_row, c.new_row,
           c.actor, c.db_user, c.txid, c.ts, c.redacted_at
    FROM volvra.change_log c
    WHERE c.id BETWEEN p_from AND p_to
    ORDER BY c.id
  LOOP
    v_hash := volvra._sha(v_hash || volvra._row_repr(
      r.id, r.table_name, r.op, r.pk, r.old_row, r.new_row,
      r.actor, r.db_user, r.txid, r.ts, r.redacted_at));
    v_n := v_n + 1;
  END LOOP;

  content_hash := v_hash;
  row_count    := v_n;
  RETURN NEXT;
END
$$;

-- Seal everything captured since the last seal.  Schedule it: the unsealed
-- window is exactly the part of the history you cannot yet prove.
CREATE OR REPLACE FUNCTION volvra.seal()
RETURNS TABLE (seal_id bigint, from_id bigint, to_id bigint,
               row_count bigint, chain_hash text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_from  bigint;
  v_to    bigint;
  v_prev  text;
  v_span  record;
  v_chain text;
  v_cap   bigint := coalesce(volvra.get_setting('seal_max_rows')::bigint, 1000000);
BEGIN
  PERFORM volvra._require('volvra_admin');

  -- One sealer at a time, or two could claim overlapping spans.
  PERFORM pg_advisory_xact_lock(hashtextextended('volvra:seal', 0));

  SELECT coalesce(max(s.to_id), 0) + 1, (SELECT s2.chain_hash FROM volvra.seal s2
                                         ORDER BY s2.to_id DESC LIMIT 1)
    INTO v_from, v_prev
  FROM volvra.seal s;

  SELECT max(c.id) INTO v_to FROM volvra.change_log c WHERE c.id >= v_from;

  IF v_to IS NULL THEN
    RETURN;                       -- nothing new to seal
  END IF;

  -- seal_max_rows bounds how long ONE call may take, so a span longer than it
  -- is sealed in batches rather than refused.  Refusing was the original
  -- behaviour and it was a trap: once a database accumulated more than
  -- seal_max_rows of unsealed history -- a million changes by default -- every
  -- seal() raised, and because maintain() calls seal() inside a single
  -- transaction, the whole maintenance run aborted.  Partition creation and
  -- retention were rolled back with it, so disk grew without bound and the
  -- cause was a limit on sealing.  Sealing now always makes progress, and
  -- repeated calls catch up.
  IF v_to - v_from + 1 > v_cap THEN
    v_to := v_from + v_cap - 1;
    RAISE NOTICE 'volvra.seal: sealing % change(s) up to id %; more remain, '
                 'call seal() again to continue',
                 v_cap, v_to;
  END IF;

  SELECT * INTO v_span FROM volvra._hash_span(v_from, v_to);

  v_chain := volvra._sha(concat_ws('|', coalesce(v_prev, ''),
                                   v_span.content_hash, v_from, v_to,
                                   v_span.row_count));

  INSERT INTO volvra.seal (from_id, to_id, row_count, content_hash,
                           prev_hash, chain_hash)
  VALUES (v_from, v_to, v_span.row_count, v_span.content_hash, v_prev, v_chain)
  RETURNING volvra.seal.id, volvra.seal.from_id, volvra.seal.to_id,
            volvra.seal.row_count, volvra.seal.chain_hash
  INTO seal_id, from_id, to_id, row_count, chain_hash;

  RETURN NEXT;
END
$$;

-- Re-hash every sealed span and re-walk the chain.  A verdict of anything but
-- 'ok' on every row means the history no longer matches what was sealed.
--
-- A span whose rows are gone is only reported as tampering if nothing in the
-- retention or erasure ledgers accounts for it: lawful deletion is recorded,
-- and recorded deletion is not tampering.
CREATE OR REPLACE FUNCTION volvra.verify()
RETURNS TABLE (
  seal_id     bigint,
  from_id     bigint,
  to_id       bigint,
  sealed_at   timestamptz,
  rows_sealed bigint,
  rows_found  bigint,      -- not "found": FOUND is a PL/pgSQL boolean
  verdict     text,
  kind        text,        -- what was done to the span, when it was touched
  detail      text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  s        record;
  v_span   record;
  v_prev   text := NULL;
  v_chain  text;
  v_lawful bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  FOR s IN SELECT sl.id, sl.from_id, sl.to_id, sl.sealed_at, sl.row_count,
                  sl.content_hash, sl.prev_hash, sl.chain_hash
           FROM volvra.seal sl ORDER BY sl.to_id
  LOOP
    seal_id   := s.id;
    from_id   := s.from_id;
    to_id     := s.to_id;
    sealed_at := s.sealed_at;
    rows_sealed := s.row_count;

    SELECT * INTO v_span FROM volvra._hash_span(s.from_id, s.to_id);
    rows_found := v_span.row_count;

    v_chain := volvra._sha(concat_ws('|', coalesce(s.prev_hash, ''),
                                     s.content_hash, s.from_id, s.to_id,
                                     s.row_count));

    -- The row counts say which kind of interference it was, which is the first
    -- thing anyone investigating needs to know.
    kind := CASE
      WHEN v_span.row_count < s.row_count THEN 'rows removed'
      WHEN v_span.row_count > s.row_count THEN 'rows inserted'
      WHEN v_span.content_hash <> s.content_hash THEN 'content altered in place'
      ELSE NULL
    END;

    IF s.prev_hash IS DISTINCT FROM v_prev THEN
      verdict := 'CHAIN BROKEN';
      detail  := 'this seal does not follow the previous one -- a seal was '
                 'removed, reordered or inserted';
    ELSIF v_chain <> s.chain_hash THEN
      verdict := 'SEAL FORGED';
      detail  := 'the seal row itself has been altered';
    ELSIF v_span.content_hash = s.content_hash THEN
      verdict := 'ok';
      kind    := NULL;
      detail  := NULL;
    ELSE
      -- Content differs.  Was the difference recorded as lawful?
      -- Only a deletion recorded *after* this seal can explain it: anything
      -- earlier was already reflected in the content that was sealed, so it
      -- cannot account for the content having changed since.
      SELECT count(*) INTO v_lawful
      FROM (
        SELECT r.at, r.from_id, r.to_id FROM volvra.retention_log r
        UNION ALL
        SELECT e.at, e.from_id, e.to_id FROM volvra.erasure_log e
      ) AS l
      WHERE l.from_id IS NOT NULL
        AND l.to_id   IS NOT NULL
        AND l.at      >  s.sealed_at
        AND l.from_id <= s.to_id
        AND l.to_id   >= s.from_id;

      IF v_lawful > 0 THEN
        verdict := 'changed by recorded erasure or retention';
        detail  := format('%s ledger entr(y/ies) overlap this span; '
                          're-seal to restore provable coverage', v_lawful);
      ELSE
        verdict := 'TAMPERED';
        detail  := format('sealed %s row(s), %s present, and no retention or '
                          'erasure was recorded for this span',
                          s.row_count, v_span.row_count);
      END IF;
    END IF;

    v_prev := s.chain_hash;
    RETURN NEXT;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- Observability
--
-- What a DBA needs to answer three questions: how much disk is this costing,
-- how fast is it growing, and is anything wrong.
-- ---------------------------------------------------------------------
-- pg_total_relation_size() on a PARTITIONED table reports the parent's own
-- storage, which is nothing -- the data lives in the partitions.  Summing the
-- partition tree is the only figure that means anything, and it works for
-- ordinary tables too (the tree is just the table itself).
-- Two cases, because neither function covers both: pg_partition_tree() returns
-- NO rows for an ordinary table, and pg_total_relation_size() returns nothing
-- useful for a partitioned parent.
CREATE OR REPLACE FUNCTION volvra._total_bytes(rel regclass) RETURNS bigint
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN c.relkind = 'p' THEN
      coalesce((SELECT sum(pg_total_relation_size(t.relid))
                FROM pg_partition_tree(rel) AS t
                WHERE t.isleaf), 0)
    ELSE pg_total_relation_size(rel)
  END
  FROM pg_class c WHERE c.oid = rel
$$;

CREATE OR REPLACE FUNCTION volvra.storage()
RETURNS TABLE (
  table_name    text,
  table_bytes   bigint,
  history_rows  bigint,
  history_bytes bigint,
  ratio         numeric,
  oldest_change timestamptz
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_total bigint;
  v_rows  bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  SELECT volvra._total_bytes('volvra.change_log'::regclass), count(*)
    INTO v_total, v_rows
  FROM volvra.change_log;

  RETURN QUERY
    SELECT e.table_name,
           coalesce(volvra._total_bytes(volvra._resolve(e.table_name)), 0),
           count(c.id),
           -- change_log size is shared, so apportion it by row share rather
           -- than pretend a per-table figure can be measured exactly.
           CASE WHEN v_rows = 0 THEN 0
                ELSE (v_total * count(c.id) / v_rows)::bigint END,
           CASE WHEN coalesce(volvra._total_bytes(volvra._resolve(e.table_name)), 0) = 0
                  OR v_rows = 0 THEN NULL
                ELSE round((v_total::numeric * count(c.id) / v_rows)
                           / volvra._total_bytes(volvra._resolve(e.table_name)), 2) END,
           min(c.ts)
    FROM volvra.enabled_tables e
    LEFT JOIN volvra.change_log c ON c.table_name = e.table_name
    GROUP BY e.table_name
    ORDER BY 4 DESC;
END
$$;

CREATE OR REPLACE FUNCTION volvra.activity(
  p_window interval DEFAULT '24 hours',
  p_bucket interval DEFAULT '1 hour')
RETURNS TABLE (
  bucket   timestamptz,
  inserts  bigint,
  updates  bigint,
  deletes  bigint,
  changes  bigint
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT date_bin(p_bucket, c.ts, date_trunc('day', now() - p_window)),
           count(*) FILTER (WHERE c.op = 'I'),
           count(*) FILTER (WHERE c.op = 'U'),
           count(*) FILTER (WHERE c.op = 'D'),
           count(*)
    FROM volvra.change_log c
    WHERE c.ts > now() - p_window
    GROUP BY 1
    ORDER BY 1;
END
$$;

-- ---------------------------------------------------------------------
-- maintain -- the one thing to schedule
--
-- Three separate jobs is three chances to forget one, and managed providers
-- differ in what scheduling they even offer.  So this is a single idempotent
-- call: extend partitions, rescue anything that fell into DEFAULT, apply
-- retention, and seal.  Run it hourly or daily -- the interval you pick is
-- also the width of the window in which tampering would go undetected.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.maintain(
  p_months_ahead int     DEFAULT 12,
  p_purge        boolean DEFAULT true,
  p_seal         boolean DEFAULT true)
RETURNS TABLE (step text, detail text, affected bigint)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_n   bigint;
  r     record;
BEGIN
  PERFORM volvra._require('volvra_admin');

  SELECT count(*) FILTER (WHERE p.status = 'created') INTO v_n
  FROM volvra.ensure_partitions(p_months_ahead) p;
  step := 'partitions'; detail := format('%s month(s) ahead', p_months_ahead);
  affected := v_n; RETURN NEXT;

  IF EXISTS (SELECT 1 FROM volvra.change_log_default) THEN
    SELECT coalesce(sum(d.rows_moved), 0) INTO v_n FROM volvra.relocate_default() d;
    step := 'relocated from default'; detail := 'rows rescued into month partitions';
    affected := v_n; RETURN NEXT;
  END IF;

  -- A partition attached since the last run inherits the parent's row trigger
  -- but not its TRUNCATE trigger, so reconciling here is what keeps TRUNCATE
  -- of a partition as safe as TRUNCATE of its parent.
  SELECT count(*) INTO v_n FROM volvra.cover_partitions() c;
  IF v_n > 0 THEN
    step := 'partitions covered';
    detail := 'truncate trigger attached to new partitions';
    affected := v_n; RETURN NEXT;
  END IF;


  IF p_purge THEN
    SELECT coalesce(sum(x.rows_removed), 0) INTO v_n FROM volvra.purge() x;
    step := 'retention'; detail := 'per-table policy applied';
    affected := v_n; RETURN NEXT;
  END IF;

  IF p_seal THEN
    SELECT coalesce(sum(z.row_count), 0) INTO v_n FROM volvra.seal() z;
    step := 'sealed'; detail := 'changes now provable';
    affected := v_n; RETURN NEXT;
  END IF;

  SELECT count(*) INTO v_n FROM volvra.health() h WHERE h.severity = 'critical';
  step := 'critical findings'; affected := v_n;
  detail := CASE WHEN v_n > 0 THEN 'run volvra.health()' ELSE 'none' END;
  RETURN NEXT;
END
$$;

-- ---------------------------------------------------------------------
-- The durable tier: preparing the database for the companion
--
-- Two things the trigger tier does NOT need and the companion cannot work
-- without:
--
--   wal_level = logical      a server setting, needs a restart (on a managed
--                            provider, a parameter-group change)
--   REPLICA IDENTITY FULL    per table, so the WAL carries the *before* image.
--                            Row triggers see OLD directly and never needed
--                            this -- do not let the requirement leak back into
--                            the trigger tier's documentation.
--
-- The companion decodes with pgoutput, which is built into Postgres and needs
-- no server-side extension -- the only choice consistent with installing on a
-- managed provider.  pgoutput streams a PUBLICATION, so one is maintained here.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.companion_setup(
  p_schema      text DEFAULT 'public',
  p_publication text DEFAULT NULL)
RETURNS TABLE (step text, object text, detail text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_pub  text := coalesce(p_publication,
                          volvra.get_setting('companion_publication'), 'volvra_pub');
  v_wal  text := current_setting('wal_level');
  r      record;
  v_n    bigint := 0;
BEGIN
  PERFORM volvra._require('volvra_admin');

  step := 'wal_level'; object := v_wal;
  detail := CASE WHEN v_wal = 'logical' THEN 'ready'
                 ELSE 'MUST be logical for the companion; this needs a server '
                      'restart, or a parameter-group change on a managed provider' END;
  RETURN NEXT;

  -- Full before-images, on covered tables only.  Anything not covered is not
  -- the companion's business either.
  FOR r IN
    SELECT volvra._resolve(e.table_name) AS rel, e.table_name AS fq
    FROM volvra.enabled_tables e
    WHERE volvra._resolve(e.table_name) IS NOT NULL
      AND split_part(e.table_name, '.', 1) IN (p_schema, quote_ident(p_schema))
    ORDER BY e.table_name
  LOOP
    IF (SELECT c.relreplident FROM pg_class c WHERE c.oid = r.rel) <> 'f' THEN
      EXECUTE format('ALTER TABLE %s REPLICA IDENTITY FULL', r.fq);
      step := 'replica identity'; object := r.fq; detail := 'set to FULL';
      RETURN NEXT;
    END IF;
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 THEN
    step := 'publication'; object := v_pub;
    detail := format('no covered tables in %s -- run volvra.enable_all(%L) first',
                     p_schema, p_schema);
    RETURN NEXT;
    RETURN;
  END IF;

  -- Rebuilt rather than patched: the set of covered tables is the source of
  -- truth, and reconciling additions and removals by hand is how a table ends
  -- up silently outside the publication.
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = v_pub) THEN
    EXECUTE format('DROP PUBLICATION %I', v_pub);
  END IF;

  -- publish_generated_columns exists from PostgreSQL 18 and is required here,
  -- not merely useful.  REPLICA IDENTITY FULL, which this function sets so the
  -- WAL carries before images, makes generated columns part of the replica
  -- identity.  From 18 onwards PostgreSQL refuses to UPDATE a table whose
  -- replica identity contains generated columns the publication does not
  -- publish -- so without this option, covering a table with a generated
  -- column and then running companion_setup() makes that table impossible to
  -- update at all. That breaks the application, not just the archive.
  --
  -- It also makes the archive better on 18+: generated columns arrive with
  -- their values instead of as nulls.
  EXECUTE format('CREATE PUBLICATION %I FOR TABLE %s%s',
                 v_pub,
                 (SELECT string_agg(e.table_name, ', ' ORDER BY e.table_name)
                  FROM volvra.enabled_tables e
                  WHERE volvra._resolve(e.table_name) IS NOT NULL
                    AND split_part(e.table_name, '.', 1)
                        IN (p_schema, quote_ident(p_schema))),
                 CASE WHEN current_setting('server_version_num')::int >= 180000
                      THEN ' WITH (publish_generated_columns = stored)'
                      ELSE '' END);

  step := 'publication'; object := v_pub;
  detail := format('%s covered table(s)', v_n);
  RETURN NEXT;

  step := 'next'; object := 'volvra-companion';
  detail := format('run: volvra-companion run --slot %s --publication %s --archive <dir>',
                   coalesce(volvra.get_setting('companion_slot'), 'volvra_companion'),
                   v_pub);
  RETURN NEXT;
END
$$;

-- Is the durable tier healthy, and is its slot a danger to the database?
--
-- An abandoned replication slot retains WAL until the disk fills and the
-- server stops.  That failure mode is worse than the problem the companion
-- solves, so the numbers that predict it come first.
CREATE OR REPLACE FUNCTION volvra.companion_status()
RETURNS TABLE (
  item   text,
  value  text,
  status text
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_slot  text := coalesce(volvra.get_setting('companion_slot'), 'volvra_companion');
  v_pub   text := coalesce(volvra.get_setting('companion_publication'), 'volvra_pub');
  v_warn  bigint := coalesce(volvra.get_setting('companion_lag_warn_bytes')::bigint,
                             536870912);
  v_max   bigint := coalesce(volvra.get_setting('companion_lag_max_bytes')::bigint,
                             5368709120);
  r       record;
  v_ret   bigint;
  v_ck    record;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  item := 'wal_level'; value := current_setting('wal_level');
  status := CASE WHEN value = 'logical' THEN 'ok'
                 ELSE 'BLOCKED: the companion cannot run' END;
  RETURN NEXT;

  item := 'publication'; value := v_pub;
  SELECT count(*) INTO v_ret FROM pg_publication_tables WHERE pubname = v_pub;
  status := CASE WHEN v_ret > 0 THEN format('%s table(s)', v_ret)
                 ELSE 'MISSING: run volvra.companion_setup()' END;
  RETURN NEXT;

  -- A covered table outside the publication is archived by nothing, and
  -- nothing else reports it: the companion streams what the publication says
  -- and cannot know what was left out.  This is the one drift that looks like
  -- working coverage right up to the day the archive is needed.
  IF v_ret > 0 THEN
    SELECT count(*) INTO v_ret
    FROM volvra.enabled_tables e
    WHERE volvra._resolve(e.table_name) IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM pg_publication_tables t
        WHERE t.pubname = v_pub
          AND format('%I.%I', t.schemaname, t.tablename) = e.table_name);
    item := 'publication drift';
    value := format('%s covered table(s) not published', v_ret);
    status := CASE WHEN v_ret = 0 THEN 'ok'
                   ELSE 'INCOMPLETE: those tables are archived by nothing -- '
                        'run volvra.companion_setup()' END;
    RETURN NEXT;
  END IF;

  -- Covered tables missing FULL identity would be archived without a before
  -- image, which makes the archive unable to drive an undo.
  SELECT count(*) INTO v_ret
  FROM volvra.enabled_tables e
  JOIN pg_class c ON c.oid = volvra._resolve(e.table_name)
  WHERE c.relreplident <> 'f';
  item := 'replica identity'; value := format('%s covered table(s) not FULL', v_ret);
  status := CASE WHEN v_ret = 0 THEN 'ok'
                 ELSE 'INCOMPLETE: those tables archive without a before image' END;
  RETURN NEXT;

  SELECT * INTO r FROM pg_replication_slots WHERE slot_name = v_slot;
  IF NOT FOUND THEN
    item := 'slot'; value := v_slot;
    status := 'ABSENT: nothing is archiving; the trigger tier is your only copy';
    RETURN NEXT;
    RETURN;
  END IF;

  item := 'slot'; value := v_slot;
  status := CASE WHEN r.active THEN 'active' ELSE 'INACTIVE: no companion connected' END;
  RETURN NEXT;

  v_ret := pg_wal_lsn_diff(pg_current_wal_lsn(), r.confirmed_flush_lsn)::bigint;
  item  := 'retained WAL';
  value := pg_size_pretty(v_ret);
  status := CASE
    WHEN v_ret >= v_max  THEN format('CRITICAL: past the %s ceiling -- the slot '
                                     'is now a threat to the database',
                                     pg_size_pretty(v_max))
    WHEN v_ret >= v_warn THEN format('WARNING: over %s and growing',
                                     pg_size_pretty(v_warn))
    ELSE 'ok' END;
  RETURN NEXT;

  SELECT * INTO v_ck FROM volvra.companion_checkpoint WHERE slot_name = v_slot;
  IF FOUND THEN
    item := 'archived'; value := v_ck.archived_lsn::text;
    status := format('%s change(s) in %s segment(s), last at %s',
                     v_ck.changes, v_ck.segments, v_ck.archived_at);
    RETURN NEXT;
    IF v_ck.archive_uri IS NOT NULL THEN
      item := 'archive'; value := v_ck.archive_uri; status := 'ok'; RETURN NEXT;
    END IF;
  END IF;

  SELECT count(*) INTO v_ret FROM volvra.companion_gap WHERE slot_name = v_slot;
  IF v_ret > 0 THEN
    item := 'gaps'; value := v_ret::text;
    status := 'history the companion could not archive -- see volvra.companion_gap';
    RETURN NEXT;
  END IF;
END
$$;

-- Called by the companion.  SECURITY DEFINER so the companion can run as a
-- role with replication rights and nothing else.
CREATE OR REPLACE FUNCTION volvra.companion_report(
  p_slot     text,
  p_lsn      pg_lsn,
  p_segments bigint,
  p_changes  bigint,
  p_uri      text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  INSERT INTO volvra.companion_checkpoint AS c
    (slot_name, archived_lsn, segments, changes, archive_uri)
  VALUES (p_slot, p_lsn, p_segments, p_changes, p_uri)
  ON CONFLICT (slot_name) DO UPDATE
    SET archived_lsn = EXCLUDED.archived_lsn,
        archived_at  = clock_timestamp(),
        segments     = EXCLUDED.segments,
        changes      = EXCLUDED.changes,
        archive_uri  = coalesce(EXCLUDED.archive_uri, c.archive_uri);
END
$$;

CREATE OR REPLACE FUNCTION volvra.companion_record_gap(
  p_slot text, p_from pg_lsn, p_to pg_lsn, p_reason text, p_detail text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO volvra.companion_gap (slot_name, from_lsn, to_lsn, reason, detail)
  VALUES (p_slot, p_from, p_to, p_reason, p_detail)
  RETURNING id INTO v_id;

  RAISE WARNING 'volvra: recorded an archive gap on slot % (%): %',
    p_slot, p_reason, coalesce(p_detail, 'no detail');
  RETURN v_id;
END
$$;

-- ---------------------------------------------------------------------
-- fingerprint -- is the code running in this database the code you audited?
--
-- pgVolvra installs as a SQL file, which means the integrity question is real:
-- a tampered file installs tampered functions, and several of them are
-- SECURITY DEFINER.  Verifying the *artifact* before you run it (checksum,
-- signature) is necessary but only covers install time.
--
-- This covers the rest: it hashes what is actually installed, so you can
-- compare against a published value -- and detect a function altered *after*
-- install, which no signature or package manager can see.
--
-- Partitions and their cloned triggers are excluded deliberately: their names
-- contain the month, so including them would make the value change on its own.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.fingerprint()
RETURNS TABLE (scope text, objects bigint, sha256 text)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_fn    text;
  v_tab   text;
  v_trg   text;
  v_nfn   bigint;
  v_ntab  bigint;
  v_ntrg  bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  -- Function bodies, including their SECURITY DEFINER flag and search_path,
  -- which is what makes this worth hashing at all.
  SELECT count(*),
         volvra._sha(string_agg(pg_get_functiondef(p.oid), E'\n'
                     ORDER BY p.proname, p.oid::regprocedure::text))
    INTO v_nfn, v_fn
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'volvra';

  SELECT count(*),
         volvra._sha(string_agg(
           format('%s.%s %s%s', c.relname, a.attname,
                  format_type(a.atttypid, a.atttypmod),
                  CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END),
           E'\n' ORDER BY c.relname, a.attnum))
    INTO v_ntab, v_tab
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
  WHERE n.nspname = 'volvra'
    AND c.relkind IN ('r', 'p')
    AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
    AND a.attnum > 0 AND NOT a.attisdropped;

  SELECT count(*),
         volvra._sha(string_agg(format('%s on %s -> %s',
                                       tg.tgname, c.relname, tg.tgfoid::regproc),
                     E'\n' ORDER BY c.relname, tg.tgname))
    INTO v_ntrg, v_trg
  FROM pg_trigger tg
  JOIN pg_class c ON c.oid = tg.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'volvra'
    AND NOT tg.tgisinternal
    AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid);

  scope := 'functions'; objects := v_nfn;  sha256 := v_fn;  RETURN NEXT;
  scope := 'tables';    objects := v_ntab; sha256 := v_tab; RETURN NEXT;
  scope := 'triggers';  objects := v_ntrg; sha256 := v_trg; RETURN NEXT;

  scope   := 'all';
  objects := v_nfn + v_ntab + v_ntrg;
  sha256  := volvra._sha(concat_ws('|', v_fn, v_tab, v_trg));
  RETURN NEXT;
END
$$;

-- ---------------------------------------------------------------------
-- preflight -- is this database configured the way the docs assume?
--
-- health() answers "is volvra working right now".  This answers the different
-- question of whether the install itself is production-shaped: the things the
-- README asks you to do and that nothing otherwise checks.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.preflight()
RETURNS TABLE (severity text, finding text, detail text)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_repl  boolean := false;
  v_owner    text;
  v_n        bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  -- The capture trigger is SECURITY DEFINER, so its owner's rights are what
  -- every captured write briefly runs with.  A superuser owner turns every
  -- INSERT on a covered table into superuser-owned code.
  SELECT r.rolname INTO v_owner
  FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
  WHERE p.oid = 'volvra.capture()'::regprocedure;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_owner AND rolsuper) THEN
    severity := 'critical';
    finding  := format('volvra.capture() is owned by the superuser %s', v_owner);
    detail   := 'It is SECURITY DEFINER, so captured writes run with superuser '
                'rights. Reinstall as a dedicated non-superuser owner before '
                'production.';
    RETURN NEXT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    severity := 'critical';
    finding  := 'the volvra_* roles do not exist';
    detail   := 'Privilege checks are permissive without them. Create them and '
                'set strict_roles = on.';
    RETURN NEXT;
  ELSIF coalesce(volvra.get_setting('strict_roles'), 'off') <> 'on' THEN
    severity := 'warning';
    finding  := 'strict_roles is off';
    detail   := 'A missing volvra_* role would silently degrade to permissive '
                'instead of failing closed.';
    RETURN NEXT;
  END IF;

  -- Nothing in the engine can schedule itself.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    severity := 'warning';
    finding  := 'pg_cron is not installed';
    detail   := 'volvra.maintain() has to be scheduled from outside the '
                'database -- your provider''s scheduler, or cron.';
    RETURN NEXT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM volvra.enabled_tables) THEN
    severity := 'warning';
    finding  := 'no tables are covered';
    detail   := 'volvra covers changes made from now on, so nothing is '
                'recoverable yet. See volvra.uncovered().';
    RETURN NEXT;
  END IF;

  -- Non-deferrable foreign keys constrain multi-table undo.
  SELECT count(*) INTO v_n
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE con.contype = 'f' AND NOT con.condeferrable
    AND format('%I.%I', n.nspname, c.relname)
        IN (SELECT e.table_name FROM volvra.enabled_tables e);
  IF v_n > 0 THEN
    severity := 'warning';
    finding  := format('%s foreign key(s) on covered tables are not deferrable', v_n);
    detail   := 'A multi-table undo that trips one will refuse. Run '
                'volvra.make_fks_deferrable() once.';
    RETURN NEXT;
  END IF;

  -- Every SECURITY DEFINER function runs with its owner's rights, so one
  -- owned by a superuser is a standing escalation, not just capture().
  SELECT count(*) INTO v_n
  FROM pg_proc p
  JOIN pg_namespace ns ON ns.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE ns.nspname = 'volvra' AND p.prosecdef AND r.rolsuper;
  IF v_n > 1 THEN
    severity := 'critical';
    finding  := format('%s SECURITY DEFINER function(s) in volvra are owned by a superuser',
                       v_n);
    detail   := 'Each runs with superuser rights when called. Reinstall as a '
                'dedicated non-superuser owner.';
    RETURN NEXT;
  END IF;

  -- Only relevant once someone wants the durable tier, so a warning.
  IF current_setting('wal_level') <> 'logical'
     AND EXISTS (SELECT 1 FROM pg_replication_slots
                 WHERE slot_name = coalesce(volvra.get_setting('companion_slot'),
                                            'volvra_companion')) THEN
    severity := 'critical';
    finding  := 'a companion slot exists but wal_level is not logical';
    detail   := 'The slot retains WAL and archives nothing. Drop it, or set '
                'wal_level = logical and restart.';
    RETURN NEXT;
  END IF;

  -- Not a problem, but the number an operator needs in order to check that the
  -- installed code is the code that was published.
  severity := 'info';
  finding  := 'installed code fingerprint';
  SELECT format('%s (compare with the release notes; run volvra.fingerprint() '
                'for the breakdown)', f.sha256)
    INTO detail
  FROM volvra.fingerprint() f WHERE f.scope = 'all';
  RETURN NEXT;

  -- Retention has to be run, not merely configured.
  IF NOT EXISTS (SELECT 1 FROM volvra.retention_log) THEN
    severity := 'warning';
    -- A subscriber with ordinary triggers records only what was written to it.
  -- That is the correct default for a single node and silently wrong for a
  -- cluster, so say so where it can be seen rather than leaving it to be
  -- discovered during an incident.
  IF volvra._is_subscriber()
     AND coalesce(volvra.get_setting('capture_replicated'), 'off') <> 'on' THEN
    severity := 'warning';
    finding  := 'this database receives replicated changes but does not capture them';
    detail   := 'Ordinary triggers do not fire for rows applied by '
                'replication, so history here covers only changes written to '
                'this node. Run volvra.set_capture_replicated(''on'') to '
                'capture peers'' changes too, at the cost of storing every '
                'change once per node.';
    RETURN NEXT;
  END IF;

  -- Replicating volvra's own tables would be a disaster: two nodes writing
  -- the same change_log id, and every captured change applied twice. It is
  -- easy to do by accident with a repset that adds all tables.
  -- Checked through two catalogues because the two replication systems keep
  -- separate ones: pg_publication_tables for native logical replication, and
  -- spock.tables for Spock, which is queried dynamically because the
  -- extension is absent on most installs.
  v_repl := EXISTS (SELECT 1 FROM pg_publication_tables WHERE schemaname = 'volvra');
  IF NOT v_repl AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
    BEGIN
      EXECUTE 'SELECT count(*) > 0 FROM spock.tables '
              'WHERE nspname = ''volvra'' AND set_name IS NOT NULL'
        INTO v_repl;
    EXCEPTION WHEN OTHERS THEN
      v_repl := false;
    END;
  END IF;

  -- volvra restores a row by writing it back, so the table's own BEFORE row
  -- triggers fire on the way in and may rewrite what they are handed.  An
  -- updated_at stamp is harmless; a trigger that normalises or overwrites
  -- business data means the restored row is not the captured one, and the
  -- undo still reports success.  A trigger that suppresses the write is
  -- caught by the guard, so only the rewriting kind needs saying out loud.
  SELECT count(DISTINCT e.table_name) INTO v_n
  FROM volvra.enabled_tables e
  JOIN pg_trigger tg ON tg.tgrelid = e.rel_oid
  WHERE NOT tg.tgisinternal
    AND tg.tgname NOT LIKE 'volvra\_%'
    AND (tg.tgtype & 1) = 1          -- FOR EACH ROW
    AND (tg.tgtype & 2) = 2;         -- BEFORE
  IF v_n > 0 THEN
    severity := 'warning';
    finding  := format('%s covered table(s) have their own BEFORE row triggers', v_n);
    detail   := 'An undo writes the captured row back, so those triggers fire '
                'and may rewrite it. The undo reports success either way, and '
                'the restored row can differ from what was captured.';
    RETURN NEXT;
  END IF;

  -- A covered parent with uncovered inheritance children reports as healthy
  -- while half its rows have no history: the trigger is not inherited, so
  -- writes reaching child rows are captured by nothing.  Partitions are
  -- excluded; cover_partitions() handles those.
  SELECT count(*) INTO v_n
  FROM volvra.enabled_tables e
  JOIN pg_inherits i  ON i.inhparent = e.rel_oid
  JOIN pg_class pc    ON pc.oid = i.inhparent AND pc.relkind = 'r'
  WHERE NOT EXISTS (SELECT 1 FROM volvra.enabled_tables c
                    WHERE c.rel_oid = i.inhrelid);
  IF v_n > 0 THEN
    severity := 'critical';
    finding  := format('%s covered table(s) have uncovered inheritance children', v_n);
    detail   := 'A row trigger is not inherited, so writes that reach those '
                'child rows are never captured and cannot be undone, while '
                'volvra.status() still reports the parent as covered. Call '
                'volvra.enable() on each child.';
    RETURN NEXT;
  END IF;

  IF v_repl THEN
    severity := 'critical';
    finding  := 'volvra tables are in a publication';
    detail   := 'The history must not replicate. Two nodes would write the '
                'same change_log ids, and every captured change would be '
                'applied twice. Remove the volvra schema from the '
                'publication or replication set.';
    RETURN NEXT;
  END IF;

  finding  := 'retention has never run';
    detail   := format('History grows without bound until volvra.maintain() or '
                       'volvra.purge() runs. Default horizon: %s.',
                       coalesce(volvra.get_setting('retention_default'), 'unset'));
    RETURN NEXT;
  END IF;
END
$$;

-- One call that says whether volvra is doing its job.  Empty result = healthy.
--
-- SECURITY DEFINER for the same reason verify() is: the check reads the
-- default partition directly, and partitions do not inherit the parent's
-- grants.  It returns verdicts and counts, never row content, and an
-- operational check should see the whole picture rather than the caller's
-- row-level-security view of it.
CREATE OR REPLACE FUNCTION volvra.health()
RETURNS TABLE (severity text, problem text, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_n     bigint;
  v_names text;
BEGIN
  PERFORM volvra._require('volvra_viewer');

  -- Registered but not actually capturing: the worst state to be in silently.
  SELECT count(*), string_agg(s.table_name, ', ' ORDER BY s.table_name)
    INTO v_n, v_names
  FROM volvra.status() s WHERE NOT s.covered;
  IF v_n > 0 THEN
    severity := 'critical';
    problem  := format('%s registered table(s) are not capturing', v_n);
    detail   := format('%s -- the trigger is disabled or missing; these have no undo', v_names);
    RETURN NEXT;
  END IF;

  SELECT count(*), string_agg(s.table_name, ', ' ORDER BY s.table_name)
    INTO v_n, v_names
  FROM volvra.status() s WHERE s.covered AND NOT s.truncate_covered;
  IF v_n > 0 THEN
    severity := 'warning';
    problem  := format('%s table(s) capture rows but not TRUNCATE', v_n);
    detail   := format('%s -- re-run volvra.enable() to attach the truncate trigger', v_names);
    RETURN NEXT;
  END IF;

  -- Rows in DEFAULT mean a month partition was missing when they were written.
  SELECT count(*) INTO v_n FROM volvra.change_log_default;
  IF v_n > 0 THEN
    severity := 'warning';
    problem  := format('%s history row(s) are in the default partition', v_n);
    detail   := 'Retention cannot drop these by month. '
                'Run volvra.relocate_default(), then schedule volvra.ensure_partitions().';
    RETURN NEXT;
  END IF;

  -- No partition for next month means DEFAULT is about to start collecting.
  IF to_regclass('volvra.' ||
       quote_ident(volvra._partition_name((now() + interval '1 month')::date))) IS NULL THEN
    severity := 'warning';
    problem  := 'no partition exists for next month';
    detail   := 'Schedule volvra.ensure_partitions() monthly.';
    RETURN NEXT;
  END IF;

  -- Tamper evidence only covers what has been sealed.
  SELECT count(*) INTO v_n
  FROM volvra.change_log c
  WHERE c.id > coalesce((SELECT max(s.to_id) FROM volvra.seal s), 0);
  IF v_n > 0 AND EXISTS (SELECT 1 FROM volvra.seal) THEN
    severity := 'warning';
    problem  := format('%s change(s) are not covered by a seal', v_n);
    detail   := 'Alteration of these rows would not be detectable. '
                'Schedule volvra.seal().';
    RETURN NEXT;
  ELSIF NOT EXISTS (SELECT 1 FROM volvra.seal) THEN
    severity := 'warning';
    problem  := 'the history has never been sealed';
    detail   := 'History is tamper-resistant but not yet tamper-evident. '
                'Run volvra.seal(), then schedule it.';
    RETURN NEXT;
  END IF;

  SELECT count(*) INTO v_n FROM volvra.verify() v
  WHERE v.verdict IN ('TAMPERED', 'CHAIN BROKEN', 'SEAL FORGED');
  IF v_n > 0 THEN
    severity := 'critical';
    problem  := format('%s sealed span(s) no longer match the history', v_n);
    detail   := 'Run volvra.verify() for the verdicts. Nothing lawful explains '
                'these -- treat as an integrity incident.';
    RETURN NEXT;
  END IF;

  SELECT count(*) INTO v_n FROM volvra.uncovered('public') WHERE reason = 'never covered';
  IF v_n > 0 THEN
    severity := 'warning';
    problem  := format('%s table(s) in public have no undo coverage', v_n);
    detail   := 'Run volvra.enable_all(''public''). An uncovered table cannot '
                'be undone, however small the mistake.';
    RETURN NEXT;
  END IF;
END
$$;

-- The audit trail is writable by any caller (every undo attempt must be able to
-- record itself) but never editable, and its identity column is stamped by the
-- server rather than trusted from the INSERT.
CREATE OR REPLACE FUNCTION volvra._stamp_audit() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  NEW.db_user := volvra._db_user();
  NEW.ts      := clock_timestamp();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS volvra_stamp_audit ON volvra.undo_log;
CREATE TRIGGER volvra_stamp_audit
  BEFORE INSERT ON volvra.undo_log
  FOR EACH ROW EXECUTE FUNCTION volvra._stamp_audit();

DROP TRIGGER IF EXISTS volvra_audit_append_only ON volvra.undo_log;
CREATE TRIGGER volvra_audit_append_only
  BEFORE UPDATE OR DELETE ON volvra.undo_log
  FOR EACH ROW EXECUTE FUNCTION volvra._guard_append_only();


-- ---------------------------------------------------------------------
-- Row-level security on the history
--
-- change_log holds complete before/after row images.  Without RLS it would be
-- a side channel around every base table's own SELECT grants.  Policy: you may
-- read a history row only if you may read the table it came from.
--
-- ENABLE (not FORCE) is deliberate: the schema owner bypasses it, which is
-- what lets the SECURITY DEFINER capture trigger write.
-- ---------------------------------------------------------------------
ALTER TABLE volvra.change_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE volvra.undo_log       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS change_log_read ON volvra.change_log;
-- Membership of a set computed once per query, rather than a per-row
-- to_regclass() that would raise for any schema the caller cannot use.
CREATE POLICY change_log_read ON volvra.change_log FOR SELECT
  USING (table_name IN (SELECT r.table_name FROM volvra._readable_tables() r));

-- The audit trail carries no row data, so it is readable by any viewer, and
-- appendable by any caller -- an undo attempt that could suppress its own audit
-- record would be worse than one that cannot.  The stamp trigger fixes the
-- identity, and the append-only guard makes the trail immutable.
DROP POLICY IF EXISTS undo_log_read ON volvra.undo_log;
CREATE POLICY undo_log_read ON volvra.undo_log FOR SELECT USING (true);

DROP POLICY IF EXISTS undo_log_append ON volvra.undo_log;
CREATE POLICY undo_log_append ON volvra.undo_log FOR INSERT WITH CHECK (true);

-- ---------------------------------------------------------------------
-- Grants -- least privilege
--
-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default, so every
-- function here must be revoked before anything is granted back.  Schema
-- USAGE is likewise never given to PUBLIC: a role with no volvra grants
-- cannot even name these objects.
-- ---------------------------------------------------------------------
REVOKE ALL ON SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA volvra FROM PUBLIC;

DO $grants$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    RAISE WARNING 'volvra: roles absent, skipping grants -- '
                  'nothing but the installing role can use volvra';
    RETURN;
  END IF;

  -- Baseline: a viewer may read history and run the read-only helpers the
  -- public read functions are built from.  Those helpers are not a way around
  -- anything -- every one of them reads change_log, which is under RLS.
  EXECUTE 'GRANT USAGE ON SCHEMA volvra TO volvra_viewer';
  EXECUTE 'GRANT SELECT ON volvra.change_log, volvra.enabled_tables, '
          'volvra.undo_log, volvra.settings, volvra.seal, volvra.retention, '
          'volvra.retention_log, volvra.erasure_log, volvra.schema_version, '
          'volvra.companion_checkpoint, volvra.companion_gap, '
          'volvra.restore_point '
          'TO volvra_viewer';
  EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA volvra TO volvra_viewer';
  EXECUTE 'GRANT INSERT ON volvra.undo_log TO volvra_viewer';
  -- The companion connects as an ordinary role and must be able to record its
  -- own progress and its own gaps.  Both are SECURITY DEFINER and append only
  -- to their own ledgers, so viewer-level execute is the right level: without
  -- it, only the schema owner could run a companion.
  EXECUTE 'GRANT INSERT ON volvra.companion_gap TO volvra_viewer';
  EXECUTE 'GRANT USAGE ON SEQUENCE volvra.companion_gap_id_seq TO volvra_viewer';
  EXECUTE 'GRANT USAGE ON SEQUENCE volvra.undo_log_id_seq TO volvra_viewer';

  -- ...then take back everything that writes.  volvra_operator and
  -- volvra_admin inherit from volvra_viewer, so these must be revoked from the
  -- viewer role specifically before being granted onward.
  EXECUTE 'REVOKE ALL ON FUNCTION '
          '  volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '              bigint, text, text, text, regclass[]), '
          '  volvra.replay(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '                bigint, text, text, text, regclass[]), '
          '  volvra.undo_txid(bigint, boolean, integer, boolean), '
          '  volvra.undo_to(text, regclass, boolean, integer, boolean, regclass[]), '
          '  volvra.mark(text, text, boolean), '
          '  volvra.unmark(text), '
          '  volvra.enable_all(text), '
          '  volvra.disable_all(text), '
          '  volvra.make_fks_deferrable(text), '
          '  volvra.enable(regclass), '
          '  volvra.disable(regclass), '
          '  volvra.set_setting(text, text), '
          '  volvra.purge(interval), '
          '  volvra.purge(), '
          '  volvra.set_retention(regclass, interval), '
          '  volvra.ensure_partitions(integer), '
          '  volvra.relocate_default(), '
          '  volvra._drop_empty_partitions(), '
          '  volvra._create_partition(date), '
          '  volvra.seal(), '
          '  volvra.forget(regclass, jsonb, boolean, text), '
          '  volvra.exclude_columns(regclass, text[]), '
          '  volvra.set_capture_mode(regclass, text), '
          '  volvra.maintain(integer, boolean, boolean), '
          '  volvra.companion_setup(text, text), '
          '  volvra.capture(), '
          '  volvra.capture_truncate(), '
          '  volvra._publish(text), '
          '  volvra.cover_partitions(regclass), '
          '  volvra.set_capture_replicated(text), '
          '  volvra._stamp_audit(), '
          '  volvra._guard_append_only() '
          'FROM volvra_viewer';

  -- operator: may apply an undo -- and still needs its own DML rights on the
  -- target table, because undo() is SECURITY INVOKER.
  EXECUTE 'GRANT EXECUTE ON FUNCTION '
          'volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '            bigint, text, text, text, regclass[]), '
          'volvra.replay(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '              bigint, text, text, text, regclass[]), '
          'volvra.undo_txid(bigint, boolean, integer, boolean), '
          'volvra.undo_to(text, regclass, boolean, integer, boolean, regclass[]), '
          'volvra.mark(text, text, boolean), '
          'volvra.unmark(text) '
          'TO volvra_operator';
  -- Taking a mark is bookkeeping an operator does, so it needs the row.
  EXECUTE 'GRANT INSERT, UPDATE, DELETE ON volvra.restore_point TO volvra_operator';

  -- admin: configure, arm/disarm tables, enforce retention.
  EXECUTE 'GRANT EXECUTE ON FUNCTION volvra.enable(regclass), volvra.disable(regclass), '
          'volvra.set_setting(text, text), volvra.purge(interval), volvra.purge(), '
          'volvra.set_retention(regclass, interval), '
          'volvra.ensure_partitions(integer), volvra.relocate_default(), '
          'volvra.seal(), volvra.forget(regclass, jsonb, boolean, text), '
          'volvra.exclude_columns(regclass, text[]), '
          'volvra.set_capture_mode(regclass, text), '
          'volvra.maintain(integer, boolean, boolean), '
          'volvra.companion_setup(text, text), '
          'volvra.enable_all(text), volvra.disable_all(text), '
          'volvra._publish(text), '
          'volvra.cover_partitions(regclass), '
          'volvra.set_capture_replicated(text), '
          'volvra.make_fks_deferrable(text) TO volvra_admin';
  -- An administrator has to be able to write the tables its own documented
  -- operations write.  Without these, set_retention, set_capture_mode,
  -- exclude_columns, enable and disable all fail for any admin who does not
  -- happen to own the volvra schema -- which the installer does and nobody
  -- else does.
  EXECUTE 'GRANT INSERT, UPDATE, DELETE ON volvra.settings, volvra.retention, '
          'volvra.enabled_tables TO volvra_admin';
  -- ensure_partitions() and maintain() call this, and it is revoked from
  -- viewer because creating a partition is not a read.
  EXECUTE 'GRANT EXECUTE ON FUNCTION volvra._create_partition(date), '
          'volvra._drop_empty_partitions() TO volvra_admin';
END
$grants$;

-- Partitions created before this release, or by an install that predates the
-- grant above, need it applied once.
DO $partition_grants$
DECLARE
  r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_inherits i ON i.inhrelid = c.oid
    WHERE i.inhparent = 'volvra.change_log'::regclass
  LOOP
    BEGIN
      EXECUTE format('GRANT SELECT ON volvra.%I TO volvra_viewer', r.relname);
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE WARNING 'volvra: could not grant SELECT on partition %', r.relname;
    END;
  END LOOP;
END
$partition_grants$;

-- capture() is deliberately granted to nobody.  PostgreSQL checks EXECUTE on a
-- trigger function when the trigger is CREATED (by volvra_admin), not on every
-- firing, so ordinary writers still have their changes captured while being
-- unable to attach or call it themselves.

-- One line, always, whatever client_min_messages is set to.
--
-- The number is called out as INTERNAL deliberately: volvra.schema_version is
-- a migration counter, not a release number.  The release number lives in
-- extension/volvra.control and is deliberately not repeated here; a version
-- written in two places goes stale in one of them.  Reading "schema v6" as a
-- sixth release is the obvious mistake, so the wording forecloses it.  The
-- ledger itself stays queryable: SELECT * FROM volvra.schema_version.
SELECT format('volvra installed: internal schema version %s%s',
              volvra.version(),
              CASE WHEN v_new > 0
                   THEN format(', %s migration(s) applied by this run', v_new)
                   ELSE '' END) AS volvra
FROM (SELECT count(*) AS v_new FROM volvra.schema_version
      WHERE applied_at >= transaction_timestamp()
        AND (SELECT pre_existing FROM volvra_install_state)) AS applied;

COMMIT;  -- volvra:tx
