-- =====================================================================
-- pgVolvra upgrade test, part 2 -- run after the CURRENT schema has been
-- installed over the seeded previous-release database.
--
-- This is what makes "you can upgrade volvra" a fact rather than an
-- intention: once a database holds history, an install that reshapes a
-- table is data loss.
--
-- test/run.sh runs this once per snapshot in test/releases, each against a
-- database of its own, so every released version is proven to reach the
-- current code. For the newest snapshot the run is a reinstall over live
-- history, which is a property worth asserting on its own.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== U1. the version ledger moved forward and never backwards ==='
SELECT version, note FROM volvra.schema_version ORDER BY version;

DO $$
DECLARE v_before int := (SELECT v::int FROM upg_marker WHERE k = 'schema_before');
BEGIN
  ASSERT volvra.version() >= v_before,
    format('the schema version must not go backwards: was %s, now %s',
           v_before, volvra.version());
  ASSERT (SELECT count(*) FROM volvra.schema_version)
         = (SELECT count(DISTINCT version) FROM volvra.schema_version),
    'no version is recorded twice';
END $$;

\echo '=== U2. every history row survived ==='
DO $$
DECLARE
  v_expected bigint := (SELECT v::bigint FROM upg_marker WHERE k = 'rows');
  v_actual   bigint;
BEGIN
  ASSERT (SELECT relkind FROM pg_class WHERE oid = 'volvra.change_log'::regclass) = 'p',
    'change_log is partitioned';
  SELECT count(*) INTO v_actual FROM volvra.change_log;
  ASSERT v_actual = v_expected,
    format('history must survive the upgrade: had %s rows, now %s',
           v_expected, v_actual);
END $$;

\echo '=== U3. ids and the sequence carried over ==='
DO $$
DECLARE
  v_maxid   bigint := (SELECT v::bigint FROM upg_marker WHERE k = 'maxid');
  v_nextval bigint;
BEGIN
  ASSERT (SELECT max(id) FROM volvra.change_log) = v_maxid,
    'row ids are preserved, so anything referencing a change id still resolves';
  SELECT nextval('volvra.change_log_id_seq') INTO v_nextval;
  ASSERT v_nextval > v_maxid,
    format('the sequence must continue past %s, produced %s', v_maxid, v_nextval);
END $$;

\echo '=== U4. seals taken before the upgrade still verify ==='
DO $$
DECLARE
  v_seals bigint := (SELECT v::bigint FROM upg_marker WHERE k = 'seals');
  v_chain text   := (SELECT v FROM upg_marker WHERE k = 'chain');
  v_bad   bigint;
BEGIN
  ASSERT (SELECT count(*) FROM volvra.seal) = v_seals,
    format('the seal ledger must survive: had %s span(s), now %s',
           v_seals, (SELECT count(*) FROM volvra.seal));
  ASSERT coalesce((SELECT max(chain_hash) FROM volvra.seal), '') = v_chain,
    'and the chain head is unchanged -- an upgrade that rewrote history would '
    'change it';
  SELECT count(*) INTO v_bad FROM volvra.verify() WHERE verdict <> 'ok';
  ASSERT v_bad = 0,
    format('history sealed before the upgrade must still verify, %s failed', v_bad);
END $$;

\echo '=== U5. pre-upgrade history is still usable for an undo ==='
DO $$
DECLARE v_ops text;
BEGIN
  SELECT string_agg(op, '' ORDER BY change_id) INTO v_ops
  FROM volvra.history('upg_orders', '{"id":1}');
  ASSERT v_ops = 'IU',
    format('history() over pre-upgrade rows should show I then U, got %s', v_ops);
END $$;

SELECT count(*) AS reverted
FROM volvra.undo('upg_orders',
                 (SELECT v::timestamptz FROM upg_marker WHERE k = 't0'),
                 now(), confirm => true);

DO $$ BEGIN
  ASSERT (SELECT total FROM upg_orders WHERE id = 1) = 100,
    'an undo driven entirely by pre-upgrade history still restores the row';
  ASSERT (SELECT total FROM upg_orders WHERE id = 2) = 250, 'both rows';
END $$;

\echo '=== U6. capture continues after the upgrade ==='
UPDATE upg_orders SET total = 555 WHERE id = 1;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log_default) = 0,
    'new writes go to a month partition, not the default';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.upg_orders') >= 4, 'and are captured';
END $$;

\echo '=== U7. the scope features work on an upgraded database ==='
BEGIN;
  SELECT txid_current() AS utx \gset
  UPDATE upg_orders SET customer = 'migrated' WHERE id = 1;
COMMIT;
SELECT count(*) FROM volvra.undo_txid(:utx, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT customer FROM upg_orders WHERE id = 1) = 'acme',
    'txid-scoped undo works after the upgrade';
END $$;

\echo '=== U8. a repeat install changes nothing ==='
DO $$
DECLARE v_versions bigint := (SELECT count(*) FROM volvra.schema_version);
BEGIN
  ASSERT v_versions = (SELECT count(DISTINCT version) FROM volvra.schema_version),
    'a repeat install must not add a duplicate ledger row';
  ASSERT (SELECT relkind FROM pg_class WHERE oid='volvra.change_log'::regclass) = 'p',
    'change_log is partitioned and stays partitioned';
END $$;

\echo ''
\echo '*** VOLVRA UPGRADE PASSED ***'
