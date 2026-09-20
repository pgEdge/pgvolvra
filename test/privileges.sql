-- =====================================================================
-- pgVolvra privilege matrix
--
-- One row per (role, function) pair, asserting BOTH directions: that a
-- permitted call is not refused, and that a forbidden call raises
-- insufficient_privilege rather than returning an empty result.  An
-- empty result and a refusal are different answers, and only one of
-- them is safe.
--
-- The matrix measures AUTHORIZATION, not behaviour, so every call is
-- chosen to be a no-op: selectors that match nothing, keys that do not
-- exist, schemas that are empty.  pgVolvra checks the caller's role
-- before it does anything else, so a no-op call still exercises the
-- check.  Behaviour is covered by the other suites.
--
-- The installing role is not a row here.  Whether the installer is a
-- superuser or an unprivileged owner is covered by running the whole
-- battery in both contexts.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== M0. roles, fixtures, and grants ==='

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['m_admin','m_operator_rw','m_operator_ro',
                           'm_viewer_sel','m_viewer_nosel','m_app','m_none'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I LOGIN', r);
    END IF;
    -- From PostgreSQL 16 a CREATEROLE role gets ADMIN OPTION but not SET on
    -- roles it creates, so SET ROLE needs an explicit grant.
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
      EXECUTE format('GRANT %I TO CURRENT_USER', r);
    END IF;
  END LOOP;
END $$;

GRANT volvra_admin    TO m_admin;
GRANT volvra_operator TO m_operator_rw, m_operator_ro;
GRANT volvra_viewer   TO m_viewer_sel, m_viewer_nosel;

DROP SCHEMA IF EXISTS pm CASCADE;
CREATE SCHEMA pm;
CREATE TABLE pm.t (id int PRIMARY KEY, v text);
INSERT INTO pm.t VALUES (1, 'a');
SELECT volvra.enable('pm.t');
UPDATE pm.t SET v = 'b' WHERE id = 1;

-- An empty schema, so the schema-wide admin functions are genuine no-ops.
DROP SCHEMA IF EXISTS pm_empty CASCADE;
CREATE SCHEMA pm_empty;

GRANT USAGE ON SCHEMA pm, pm_empty TO m_admin, m_operator_rw, m_operator_ro,
                                      m_viewer_sel, m_viewer_nosel, m_app, m_none;
GRANT SELECT ON pm.t TO m_viewer_sel, m_operator_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON pm.t TO m_operator_rw, m_app;
-- m_viewer_nosel and m_none deliberately get nothing on pm.t.

\echo '=== M1. the matrix ==='

CREATE TEMP TABLE pm_case (
  seq        serial PRIMARY KEY,
  role_name  text NOT NULL,
  label      text NOT NULL,
  call_sql   text NOT NULL,
  allowed    boolean NOT NULL
);

-- Every public function, with a no-op call.  tier says which role the
-- function is documented to require, and the expectations below follow from
-- it, so a documentation change and a test change stay in step.
CREATE TEMP TABLE pm_fn (fn text PRIMARY KEY, call_sql text, tier text);

INSERT INTO pm_fn (fn, call_sql, tier) VALUES
  -- no role documented, but EXECUTE is granted at viewer level
  ('version',              $$SELECT volvra.version()$$,                                'viewer'),
  ('get_setting',          $$SELECT volvra.get_setting('max_undo_rows')$$,              'viewer'),
  -- viewer, not table specific
  ('status',               $$SELECT count(*) FROM volvra.status()$$,                    'viewer'),
  ('health',               $$SELECT count(*) FROM volvra.health()$$,                    'viewer'),
  ('preflight',            $$SELECT count(*) FROM volvra.preflight()$$,                 'viewer'),
  ('storage',              $$SELECT count(*) FROM volvra.storage()$$,                   'viewer'),
  ('activity',             $$SELECT count(*) FROM volvra.activity('1 hour','1 hour')$$, 'viewer'),
  ('fingerprint',          $$SELECT count(*) FROM volvra.fingerprint()$$,               'viewer'),
  ('verify',               $$SELECT count(*) FROM volvra.verify()$$,                    'viewer'),
  ('transactions',         $$SELECT count(*) FROM volvra.transactions()$$,              'viewer'),
  ('uncovered',            $$SELECT count(*) FROM volvra.uncovered('pm_empty')$$,       'viewer'),
  ('companion_status',     $$SELECT count(*) FROM volvra.companion_status()$$,           'viewer'),
  ('companion_report',     $$SELECT volvra.companion_report('pm_slot','0/1',0,0,NULL)$$, 'viewer'),
  ('companion_record_gap', $$SELECT volvra.companion_record_gap('pm_slot','0/1','0/2','pm','pm')$$, 'viewer'),
  -- viewer, but also needs SELECT on the table
  ('history',              $$SELECT count(*) FROM volvra.history('pm.t','{"id":1}')$$,  'viewer_table'),
  ('preview_undo',         $$SELECT count(*) FROM volvra.preview_undo('pm.t','2000-01-01','2000-01-02')$$, 'viewer_table'),
  ('preview_replay',       $$SELECT count(*) FROM volvra.preview_replay('pm.t','2000-01-01','2000-01-02')$$, 'viewer_table'),
  ('as_of',                $$SELECT count(*) FROM volvra.as_of('pm.t', now())$$,       'viewer_table'),
  -- A txid names no table, so the plan is unscoped and read privilege is
  -- required on EVERY covered table.  No role in this matrix has that, and
  -- that refusal is the correct answer rather than a gap.
  ('preview_undo_txid',    $$SELECT count(*) FROM volvra.preview_undo_txid(1)$$,        'viewer_all'),
  -- operator
  ('undo',                 $$SELECT count(*) FROM volvra.undo('pm.t','2000-01-01','2000-01-02', confirm => true)$$, 'operator'),
  ('replay',               $$SELECT count(*) FROM volvra.replay('pm.t','2000-01-01','2000-01-02', confirm => true)$$, 'operator'),
  ('undo_txid',            $$SELECT count(*) FROM volvra.undo_txid(1, confirm => true)$$, 'viewer_all'),
  -- admin
  -- Attaching or dropping a trigger needs ownership of the table, which
  -- volvra_admin does not confer and deliberately should not.
  ('enable',               $$SELECT volvra.enable('pm.t')$$,                            'admin_owner'),
  ('enable_all',           $$SELECT count(*) FROM volvra.enable_all('pm_empty')$$,       'admin'),
  ('set_warn_changed_rows',$$SELECT volvra.set_warn_changed_rows(0)$$,                 'admin'),
  ('disable_all',          $$SELECT count(*) FROM volvra.disable_all('pm_empty')$$,      'admin'),
  ('set_setting',          $$SELECT volvra.set_setting('strict_roles','off')$$,          'admin'),
  ('set_retention',        $$SELECT volvra.set_retention('pm.t','365 days')$$,           'admin'),
  ('set_capture_mode',     $$SELECT volvra.set_capture_mode('pm.t', NULL)$$,             'admin'),
  ('exclude_columns',      $$SELECT count(*) FROM volvra.exclude_columns('pm.t', ARRAY['v'])$$, 'admin'),
  ('purge_interval',       $$SELECT count(*) FROM volvra.purge('100 years'::interval)$$, 'admin'),
  ('purge_policy',         $$SELECT count(*) FROM volvra.purge()$$,                      'admin'),
  ('ensure_partitions',    $$SELECT count(*) FROM volvra.ensure_partitions(1)$$,         'admin'),
  ('relocate_default',     $$SELECT count(*) FROM volvra.relocate_default()$$,           'admin'),
  ('maintain',             $$SELECT count(*) FROM volvra.maintain(1, false, false)$$,    'admin'),
  ('seal',                 $$SELECT count(*) FROM volvra.seal()$$,                       'admin'),
  ('forget',               $$SELECT count(*) FROM volvra.forget('pm.t','{"id":999999}')$$, 'admin'),
  ('make_fks_deferrable',  $$SELECT count(*) FROM volvra.make_fks_deferrable('pm_empty')$$, 'admin'),
  ('companion_setup',      $$SELECT count(*) FROM volvra.companion_setup('pm_empty')$$,  'admin'),
  ('_publish',             $$SELECT volvra._publish('pm.t')$$,                           'admin'),
  ('cover_partitions',     $$SELECT count(*) FROM volvra.cover_partitions()$$,           'admin'),
  ('set_capture_replicated',$$SELECT count(*) FROM volvra.set_capture_replicated('off')$$, 'admin'),
  ('disable',              $$SELECT volvra.disable('pm.t')$$,                            'admin_owner'),
  -- marks: taking one is operator bookkeeping, reading them is a view
  ('marks',                $$SELECT count(*) FROM volvra.marks()$$,                      'viewer'),
  -- operator_only: needs the operator role but reads no table, so an admin
  -- (which inherits operator) can call it even without SELECT on pm.t
  ('mark',                 $$SELECT volvra.mark('pm_probe_' || md5(random()::text))$$,    'operator_only'),
  ('unmark',               $$SELECT volvra.unmark('pm_no_such_mark')$$,                   'operator_only'),
  ('undo_to',              $$SELECT count(*) FROM volvra.undo_to('pm_no_such_mark')$$,    'operator_only'),
  ('preview_undo_to',      $$SELECT count(*) FROM volvra.preview_undo_to('pm_no_such_mark')$$, 'viewer');

-- The expectation for every pair follows from the tier and the role.
INSERT INTO pm_case (role_name, label, call_sql, allowed)
SELECT r.role_name, f.fn, f.call_sql,
       -- volvra_admin confers neither read on a table nor ownership of one,
       -- so an admin without SELECT on pm.t cannot read its history, and an
       -- admin who does not own pm.t cannot attach a trigger to it.  Both
       -- refusals are correct.
       CASE r.role_name
         WHEN 'm_admin'        THEN f.tier IN ('viewer','admin','operator_only')
         WHEN 'm_operator_rw'  THEN f.tier IN ('viewer','viewer_table','operator',
                                               'operator_only')
         WHEN 'm_operator_ro'  THEN f.tier IN ('viewer','viewer_table','operator',
                                               'operator_only')
         WHEN 'm_viewer_sel'   THEN f.tier IN ('viewer','viewer_table')
         WHEN 'm_viewer_nosel' THEN f.tier = 'viewer'
         ELSE false
       END
FROM pm_fn f
CROSS JOIN (VALUES ('m_admin'),('m_operator_rw'),('m_operator_ro'),
                   ('m_viewer_sel'),('m_viewer_nosel'),('m_app'),('m_none')) AS r(role_name);

DO $$
DECLARE
  c            record;
  v_refused    boolean;
  v_err        text;
  v_mismatch   text[] := '{}';
  v_checked    int := 0;
BEGIN
  FOR c IN SELECT * FROM pm_case ORDER BY seq LOOP
    EXECUTE format('SET LOCAL ROLE %I', c.role_name);

    v_refused := false;
    v_err := NULL;
    BEGIN
      EXECUTE c.call_sql;
    EXCEPTION
      WHEN insufficient_privilege THEN
        v_refused := true;
        v_err := SQLERRM;
      WHEN OTHERS THEN
        -- Any other error means the call was authorised and then failed for
        -- some unrelated reason, which for this matrix counts as allowed.
        v_err := SQLERRM;
    END;

    RESET ROLE;
    v_checked := v_checked + 1;

    IF c.allowed AND v_refused THEN
      v_mismatch := v_mismatch ||
        format('%s may call %s but was REFUSED: %s',
               c.role_name, c.label, coalesce(v_err, '(no message)'))::text;
    ELSIF NOT c.allowed AND NOT v_refused THEN
      v_mismatch := v_mismatch ||
        format('%s must NOT call %s but was ALLOWED%s', c.role_name, c.label,
               coalesce(' (errored: ' || left(v_err, 60) || ')', ''))::text;
    END IF;
  END LOOP;

  RAISE NOTICE 'privilege matrix: % pairs checked', v_checked;

  ASSERT v_mismatch = '{}',
    format('%s privilege mismatch(es):%s  %s', cardinality(v_mismatch),
           E'\n', array_to_string(v_mismatch, E'\n  '));
END $$;

\echo '=== M2. the matrix covers every public function ==='
DO $$
DECLARE v_missing text[];
BEGIN
  SELECT array_agg(p.proname::text ORDER BY p.proname) INTO v_missing
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'volvra'
    AND p.proname NOT LIKE '\_%'
    AND p.proname NOT IN ('capture','capture_truncate')   -- trigger functions
    AND NOT EXISTS (
      SELECT 1 FROM pm_fn f
      WHERE f.fn = p.proname
         OR f.fn LIKE p.proname || '\_%');                -- purge overloads
  ASSERT v_missing IS NULL,
    format('public functions absent from the privilege matrix: %s',
           array_to_string(v_missing, ', '));
END $$;

\echo '=== M3. a refusal is never an empty result ==='
-- The most dangerous failure mode is a read that returns nothing instead of
-- refusing, because the caller cannot tell the two apart.
DO $$
DECLARE v_bad text[] := '{}';
BEGIN
  SET LOCAL ROLE m_viewer_nosel;
  BEGIN
    PERFORM count(*) FROM volvra.history('pm.t'::regclass, '{"id":1}'::jsonb);
    v_bad := v_bad || 'history returned instead of refusing'::text;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM count(*) FROM volvra.preview_undo('pm.t'::regclass,
              '2000-01-01'::timestamptz, '2000-01-02'::timestamptz);
    v_bad := v_bad || 'preview_undo returned instead of refusing'::text;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  ASSERT v_bad = '{}', array_to_string(v_bad, '; ');
END $$;

\echo '--- and row-level security hides history rather than leaking it ---'
DO $$
DECLARE v_rows bigint;
BEGIN
  SET LOCAL ROLE m_viewer_nosel;
  SELECT count(*) INTO v_rows FROM volvra.change_log WHERE table_name = 'pm.t';
  RESET ROLE;
  ASSERT v_rows = 0,
    format('a reader with no SELECT on pm.t saw %s history row(s)', v_rows);
END $$;

DO $$
DECLARE v_rows bigint;
BEGIN
  SET LOCAL ROLE m_viewer_sel;
  SELECT count(*) INTO v_rows FROM volvra.change_log WHERE table_name = 'pm.t';
  RESET ROLE;
  ASSERT v_rows > 0,
    'a reader with SELECT on pm.t must see its history';
END $$;

\echo ''
\echo '*** ALL VOLVRA PRIVILEGE MATRIX CHECKS PASSED ***'
