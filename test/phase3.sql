-- =====================================================================
-- pgVolvra phase 3 -- scale
--
-- Gate: a DBA can predict what volvra costs them in write throughput and
-- disk, and can bound both.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== P3.1 the install is versioned ==='
SELECT version, note FROM volvra.schema_version ORDER BY version;

DO $$ BEGIN
  -- The ledger records one row per SCHEMA version, which is not the product
  -- version and does not move with it: it increments only when the on-disk
  -- shape changes.  So this asserts the shape of the ledger, not a particular
  -- number.  It used to assert exactly 1, on the premise that nothing had been
  -- released; two releases later that premise was false and the assertion
  -- failed for the only reason it ever could, which is that the premise had
  -- expired rather than that anything was wrong.
  ASSERT volvra.version() >= 1, 'the schema is installed';
  ASSERT (SELECT count(*) FROM volvra.schema_version)
         = (SELECT count(DISTINCT version) FROM volvra.schema_version),
    'no version is recorded twice';
  ASSERT (SELECT count(*) FROM volvra.schema_version) = volvra.version(),
    format('the ledger holds one row per version up to %s, found %s row(s) -- '
           'a row per development step would show up here',
           volvra.version(), (SELECT count(*) FROM volvra.schema_version));
  ASSERT (SELECT bool_and(note IS NOT NULL AND note <> '')
          FROM volvra.schema_version),
    'every version says what it changed';
  ASSERT volvra._at_least(1), '_at_least agrees';
  ASSERT volvra._at_least(volvra.version()), 'and agrees at the current version';
  ASSERT NOT volvra._at_least(999), 'and does not over-claim';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P3.2 change_log is partitioned, with a default safety net ==='
SELECT count(*) AS month_partitions
FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'volvra.change_log'::regclass
  AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE 'DEFAULT%';

DO $$
DECLARE v_parts bigint;
BEGIN
  ASSERT (SELECT relkind FROM pg_class WHERE oid = 'volvra.change_log'::regclass) = 'p',
         'change_log must be a partitioned table';
  ASSERT to_regclass('volvra.change_log_default') IS NOT NULL,
         'the default partition is what stops a capture ever failing';
  SELECT count(*) INTO v_parts
  FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
  WHERE i.inhparent = 'volvra.change_log'::regclass;
  ASSERT v_parts >= 13, format('expected 13+ partitions after install, got %s', v_parts);
END $$;

\echo '--- writes land in the month partition, not the default one ---'
DROP TABLE IF EXISTS scale_t;
CREATE TABLE scale_t (id int PRIMARY KEY, v text);
SELECT volvra.enable('scale_t');
INSERT INTO scale_t VALUES (1, 'a'), (2, 'b');

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log_default) = 0,
         'current-month writes must not fall through to the default partition';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.scale_t') = 2, 'and they were captured';
END $$;

\echo '--- ensure_partitions is idempotent ---'
DO $$
DECLARE v_created bigint;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'created') INTO v_created
  FROM volvra.ensure_partitions(12);
  ASSERT v_created = 0, format('a second run should create nothing, created %s', v_created);
END $$;

-- ---------------------------------------------------------------------
\echo '=== P3.3 rows in the default partition are detected and relocated ==='
-- Simulate the one bad case: history written while a month partition is absent.
DO $$
DECLARE v_old timestamptz := now() - interval '25 months';
BEGIN
  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid, ts)
  VALUES ('public.scale_t', 'U', '{"id":1}', '{"id":1,"v":"ancient"}',
          '{"id":1,"v":"a"}', 'test', 'test', 1, v_old);
END $$;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log_default) = 1,
         'a write outside every month range lands in default, not an error';
  ASSERT (SELECT count(*) FROM volvra.health()
          WHERE problem LIKE '%default partition%') = 1,
         'health() must report it';
END $$;

SELECT partition_name, rows_moved FROM volvra.relocate_default();

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log_default) = 0,
         'default partition is empty again';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.scale_t') = 3,
         'and no history was lost in the move';
  ASSERT (SELECT count(*) FROM volvra.health()
          WHERE problem LIKE '%default partition%') = 0,
         'health() is satisfied';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P3.4 retention drops whole partitions, not rows ==='
DO $$
DECLARE
  v_before bigint;
  v_dropped bigint;
BEGIN
  SELECT count(*) INTO v_before
  FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
  WHERE i.inhparent = 'volvra.change_log'::regclass
    AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE 'DEFAULT%';

  -- the relocated row is ~25 months old, so a 12-month cutoff must drop
  -- its whole partition rather than delete the row
  SELECT count(*) INTO v_dropped
  FROM volvra.purge('12 months'::interval) WHERE action = 'dropped partition';

  ASSERT v_dropped >= 1,
    'retention must reclaim history by dropping partitions, not by scanning rows';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.scale_t') = 2,
    'the ancient row is gone, recent history intact';
END $$;

\echo '--- and recent history survives a purge with a long horizon ---'
SELECT action, object, rows_removed FROM volvra.purge('100 years'::interval);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log) > 0, 'nothing recent was removed';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P3.5 per-table retention policy ==='
SELECT volvra.set_retention('scale_t', '1 second'::interval);
DO $$ BEGIN
  ASSERT (SELECT keep_for FROM volvra.retention WHERE table_name = 'public.scale_t')
         = '1 second'::interval, 'policy recorded';
END $$;

SELECT pg_sleep(1.1);
SELECT table_name, keep_for, rows_removed FROM volvra.purge()
WHERE table_name = 'public.scale_t';

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.scale_t') = 0,
         'the per-table policy was applied';
END $$;

-- put it back so later phases are not surprised
DELETE FROM volvra.retention WHERE table_name = 'public.scale_t';

-- ---------------------------------------------------------------------
\echo '=== P3.6 observability ==='
INSERT INTO scale_t VALUES (3, 'c');
UPDATE scale_t SET v = 'c2' WHERE id = 3;

SELECT table_name, history_rows FROM volvra.storage()
WHERE table_name = 'public.scale_t';

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.storage() WHERE table_name = 'public.scale_t';
  ASSERT r.history_rows = 2, format('storage() row count, got %s', r.history_rows);
  ASSERT r.table_bytes > 0, 'storage() reports the base table size';
  -- >= 0 would pass vacuously: pg_total_relation_size on a partitioned parent
  -- reports nothing, which is exactly the bug this caught.
  ASSERT r.history_bytes > 0,
    format('storage() must sum the partition tree, reported %s bytes', r.history_bytes);
  ASSERT volvra._total_bytes('volvra.change_log'::regclass) > 0,
    'the partitioned change_log must report real bytes';
END $$;

SELECT bucket, inserts, updates, deletes FROM volvra.activity('1 hour', '1 hour');

DO $$ BEGIN
  ASSERT (SELECT sum(changes) FROM volvra.activity('1 hour', '1 hour')) >= 2,
         'activity() sees recent capture volume';
END $$;

\echo '--- health() reports a table that stopped capturing ---'
ALTER TABLE scale_t DISABLE TRIGGER volvra_capture;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.health()
          WHERE severity = 'critical' AND problem LIKE '%not capturing%') = 1,
         'a disabled trigger is a critical finding, not a warning';
END $$;
ALTER TABLE scale_t ENABLE TRIGGER volvra_capture;

\echo '--- and an uncovered table ---'
DROP TABLE IF EXISTS never_covered;
CREATE TABLE never_covered (id int PRIMARY KEY);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.health()
          WHERE problem LIKE '%coverage%') = 1, 'health() notices an uncovered table';
END $$;
DROP TABLE never_covered;

-- ---------------------------------------------------------------------
\echo '=== P3.7 retention still cannot be used to erase history casually ==='
DO $$
DECLARE v_state text;
BEGIN
  -- the purge escape hatch is admin-only and transaction-local; a plain DELETE
  -- must still be refused even right after a purge ran in this session
  BEGIN
    DELETE FROM volvra.change_log WHERE true;
    RAISE EXCEPTION 'SECURITY FAILURE: change_log was deleted outside purge()';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked',
    'the append-only guard must survive purge() having opened and closed its window';
END $$;

\echo ''
\echo '*** ALL VOLVRA PHASE 3 CHECKS PASSED ***'
