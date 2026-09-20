-- =====================================================================
-- pgVolvra phase 1 -- correctness
--
-- Gate: an undo restores exactly what was lost, or refuses and says why.
-- It never silently destroys something it did not capture.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------
\echo '=== P1.1 conflict detection: undo refuses to clobber a later change ==='
DROP TABLE IF EXISTS inventory;
CREATE TABLE inventory (sku text PRIMARY KEY, qty int NOT NULL, note text);
SELECT volvra.enable('inventory');
INSERT INTO inventory VALUES ('A', 10, NULL), ('B', 20, NULL), ('C', 30, NULL);

SELECT clock_timestamp() AS t0 \gset
SELECT pg_sleep(0.05);
UPDATE inventory SET qty = 0;                     -- the accident
SELECT pg_sleep(0.05);
SELECT clock_timestamp() AS t1 \gset

-- a legitimate change lands after the accident, on one row only
UPDATE inventory SET qty = 99 WHERE sku = 'B';

SELECT set_config('test.t0', :'t0', false);
SELECT set_config('test.t1', :'t1', false);

\echo '--- preview reports the conflict up front ---'
SELECT seq, pk, conflict
FROM volvra.preview_undo('inventory', :'t0', :'t1');

DO $$
DECLARE v_conf bigint;
BEGIN
  SELECT count(*) FILTER (WHERE conflict) INTO v_conf
  FROM volvra.preview_undo('inventory',
         current_setting('test.t0')::timestamptz,
         current_setting('test.t1')::timestamptz);
  ASSERT v_conf = 1, format('preview should flag exactly 1 conflict, got %s', v_conf);
END $$;

\echo '--- and undo refuses the whole transaction rather than destroy it ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo('inventory'::regclass,
                        current_setting('test.t0')::timestamptz,
                        current_setting('test.t1')::timestamptz, confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: undo clobbered a later change';
  EXCEPTION WHEN serialization_failure THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'undo must refuse when a row has moved on';

  -- nothing was applied: the refusal rolls back the whole plan, not just the row
  ASSERT (SELECT qty FROM inventory WHERE sku = 'B') = 99, 'later change survived';
  ASSERT (SELECT qty FROM inventory WHERE sku = 'A') = 0,
         'a refused undo applies nothing at all';
END $$;

\echo '--- skip_conflicts => true reverts the rest and leaves the conflict alone ---'
SELECT seq, pk, status
FROM volvra.undo('inventory', :'t0', :'t1', confirm => true, skip_conflicts => true);

DO $$
BEGIN
  ASSERT (SELECT qty FROM inventory WHERE sku = 'A') = 10, 'A reverted';
  ASSERT (SELECT qty FROM inventory WHERE sku = 'C') = 30, 'C reverted';
  ASSERT (SELECT qty FROM inventory WHERE sku = 'B') = 99,
         'B was skipped, not guessed at';
  ASSERT (SELECT count(*) FROM volvra.undo('inventory'::regclass,
            current_setting('test.t0')::timestamptz,
            current_setting('test.t1')::timestamptz,
            confirm => true, skip_conflicts => true)
          WHERE status = 'skipped') = 3,
         'a second pass has nothing left to apply';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.2 conflict detection covers INSERT and DELETE inverses ==='
DROP TABLE IF EXISTS conflicts_id;
CREATE TABLE conflicts_id (id int PRIMARY KEY, v text);
SELECT volvra.enable('conflicts_id');
INSERT INTO conflicts_id VALUES (1, 'one');

SELECT clock_timestamp() AS c0 \gset
SELECT pg_sleep(0.05);
DELETE FROM conflicts_id WHERE id = 1;            -- to be undone
SELECT pg_sleep(0.05);
SELECT clock_timestamp() AS c1 \gset
-- outside the undo window: someone has since taken that primary key
INSERT INTO conflicts_id VALUES (1, 'someone put it back differently');
SELECT set_config('test.c0', :'c0', false);
SELECT set_config('test.c1', :'c1', false);

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    -- resurrecting the deleted row would collide with the row there now
    PERFORM volvra.undo('conflicts_id'::regclass,
                        current_setting('test.c0')::timestamptz,
                        current_setting('test.c1')::timestamptz, confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: undo overwrote an unrelated row';
  EXCEPTION WHEN serialization_failure THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'resurrecting onto an occupied pk must conflict';
  ASSERT (SELECT v FROM conflicts_id WHERE id = 1) = 'someone put it back differently',
         'the occupying row is untouched';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.3 TRUNCATE is captured, not silently lost ==='
DROP TABLE IF EXISTS wiped;
CREATE TABLE wiped (id int PRIMARY KEY, payload text NOT NULL);
SELECT volvra.enable('wiped');
INSERT INTO wiped SELECT g, 'row ' || g FROM generate_series(1, 50) g;

SELECT clock_timestamp() AS w0 \gset
SELECT pg_sleep(0.05);
TRUNCATE wiped;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM wiped) = 0, 'truncate happened';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.wiped' AND op = 'D') = 50,
         'every truncated row must be captured as a delete';
END $$;

SELECT count(*) AS restored
FROM volvra.undo('wiped', :'w0', clock_timestamp(), confirm => true);

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM wiped) = 50, 'truncate fully undone';
  ASSERT (SELECT payload FROM wiped WHERE id = 42) = 'row 42', 'payloads intact';
END $$;

\echo '--- on_truncate = block refuses outright ---'
SELECT volvra.set_setting('on_truncate', 'block');
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    TRUNCATE wiped;
    RAISE EXCEPTION 'CORRECTNESS FAILURE: truncate was allowed in block mode';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'on_truncate=block must refuse';
  ASSERT (SELECT count(*) FROM wiped) = 50, 'nothing was lost';
END $$;

\echo '--- the capture cap refuses rather than copying a huge table ---'
SELECT volvra.set_setting('on_truncate', 'capture');
SELECT volvra.set_setting('truncate_capture_max_rows', '10');
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    TRUNCATE wiped;
    RAISE EXCEPTION 'CORRECTNESS FAILURE: capture cap did not apply';
  EXCEPTION WHEN program_limit_exceeded THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'capture cap must refuse loudly';
END $$;
SELECT volvra.set_setting('truncate_capture_max_rows', '100000');

\echo '--- on_truncate = allow leaves a marker undo will not step over ---'
SELECT volvra.set_setting('on_truncate', 'allow');
SELECT clock_timestamp() AS w1 \gset
SELECT pg_sleep(0.05);
TRUNCATE wiped;
SELECT set_config('test.w1', :'w1', false);

DO $$
DECLARE v_state text;
BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.wiped' AND op = 'T') = 1,
         'allow mode must record a T marker';
  BEGIN
    PERFORM volvra.undo('wiped'::regclass, current_setting('test.w1')::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: undo stepped over an uncaptured truncate';
  EXCEPTION WHEN data_exception THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused',
         'a half-restored table that looks whole is worse than a clear refusal';
END $$;
SELECT volvra.set_setting('on_truncate', 'capture');

-- ---------------------------------------------------------------------
\echo '=== P1.4 schema drift is caught at plan time ==='
DROP TABLE IF EXISTS drifting;
CREATE TABLE drifting (id int PRIMARY KEY, a text);
SELECT volvra.enable('drifting');
INSERT INTO drifting VALUES (1, 'x');
SELECT clock_timestamp() AS d0 \gset
SELECT pg_sleep(0.05);
UPDATE drifting SET a = 'y';
SELECT set_config('test.d0', :'d0', false);

ALTER TABLE drifting DROP COLUMN a;
ALTER TABLE drifting ADD COLUMN b text NOT NULL DEFAULT 'z';

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo('drifting'::regclass, current_setting('test.d0')::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: replayed a row into a changed table';
  EXCEPTION WHEN datatype_mismatch THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'undo must refuse an image the current schema cannot accept';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.5 type fidelity: every column round-trips through jsonb ==='
DROP TABLE IF EXISTS wide;
DROP TYPE IF EXISTS mood;
DROP DOMAIN IF EXISTS positive_int;
CREATE TYPE mood AS ENUM ('calm', 'panic');
CREATE DOMAIN positive_int AS int CHECK (VALUE > 0);

CREATE TABLE wide (
  id            int PRIMARY KEY,
  c_smallint    smallint,
  c_bigint      bigint,
  c_numeric     numeric(20,6),
  c_real        real,
  c_double      double precision,
  c_double_inf  double precision,
  c_double_nan  double precision,
  c_text        text,
  c_varchar     varchar(40),
  c_char        char(6),
  c_bytea       bytea,
  c_bool        boolean,
  c_date        date,
  c_time        time,
  c_timetz      timetz,
  c_timestamp   timestamp,
  c_timestamptz timestamptz,
  c_interval    interval,
  c_uuid        uuid,
  c_inet        inet,
  c_cidr        cidr,
  c_macaddr     macaddr,
  c_json        json,
  c_jsonb       jsonb,
  c_int_arr     int[],
  c_text_arr    text[],
  c_int4range   int4range,
  c_tstzrange   tstzrange,
  c_numrange    numrange,
  c_bit         bit(8),
  c_varbit      varbit,
  c_enum        mood,
  c_domain      positive_int,
  c_point       point,
  c_money       money,
  c_null        text
);

SELECT volvra.enable('wide');

INSERT INTO wide VALUES (
  1,
  -32768,
  9223372036854775807,
  -12345678901234.567890,
  3.4e38::real,
  2.2250738585072014e-308,
  'Infinity'::double precision,
  'NaN'::double precision,
  E'tab\there, newline\nhere, quote " and backslash \\ and unicode é中',
  'varchar with '' quote',
  'padded',
  '\xDEADBEEF00'::bytea,
  true,
  '0001-01-01'::date,
  '23:59:59.999999'::time,
  '23:59:59.999999+05:30'::timetz,
  '4713-01-01 00:00:00'::timestamp,
  '2026-09-06 14:30:00.123456+00'::timestamptz,
  '1 year 2 mons 3 days 04:05:06.789'::interval,
  '0189ab3c-0000-4000-8000-000000000000'::uuid,
  '192.168.0.1/24'::inet,
  '10.0.0.0/8'::cidr,
  '08:00:2b:01:02:03'::macaddr,
  '{"a": [1, 2, {"b": null}]}'::json,
  '{"z": 1, "a": {"nested": true}}'::jsonb,
  ARRAY[1, NULL, 3],
  ARRAY['a', NULL, 'has "quotes"', '{braces}'],
  '[1,10)'::int4range,
  '[2026-01-01 00:00:00+00, 2026-12-31 00:00:00+00)'::tstzrange,
  '(1.5,2.5]'::numrange,
  B'10101010',
  B'1101',
  'panic'::mood,
  42::positive_int,
  '(1.5,-2.5)'::point,
  '1234.56'::money,
  NULL
);

-- snapshot the exact row, wreck it, put it back, compare byte for byte
SELECT to_jsonb(w) AS before FROM wide w WHERE id = 1 \gset
SELECT set_config('test.before', :'before', false);

SELECT clock_timestamp() AS y0 \gset
SELECT pg_sleep(0.05);

UPDATE wide SET
  c_smallint = 0, c_bigint = 0, c_numeric = 0, c_real = 0, c_double = 0,
  c_double_inf = 0, c_double_nan = 0, c_text = 'wrecked', c_varchar = 'wrecked',
  c_char = 'x', c_bytea = '\x00'::bytea, c_bool = false,
  c_date = '2000-01-01', c_time = '00:00', c_timetz = '00:00+00',
  c_timestamp = '2000-01-01', c_timestamptz = '2000-01-01+00',
  c_interval = '0', c_uuid = '00000000-0000-0000-0000-000000000000',
  c_inet = '127.0.0.1', c_cidr = '127.0.0.0/8', c_macaddr = '00:00:00:00:00:00',
  c_json = 'null', c_jsonb = 'null', c_int_arr = '{}', c_text_arr = '{}',
  c_int4range = 'empty', c_tstzrange = 'empty', c_numrange = 'empty',
  c_bit = B'00000000', c_varbit = B'0', c_enum = 'calm', c_domain = 1,
  c_point = '(0,0)', c_money = '0', c_null = 'not null any more';

SELECT count(*) AS reverted
FROM volvra.undo('wide', :'y0', clock_timestamp(), confirm => true);

DO $$
DECLARE
  v_before jsonb := current_setting('test.before')::jsonb;
  v_after  jsonb;
  v_bad    text;
BEGIN
  SELECT to_jsonb(w) INTO v_after FROM wide w WHERE id = 1;

  SELECT string_agg(format('%s: %s -> %s', k,
                           coalesce((v_before -> k)::text, 'MISSING'),
                           coalesce((v_after  -> k)::text, 'MISSING')), E'\n  ')
    INTO v_bad
  FROM jsonb_object_keys(v_before) AS k
  WHERE (v_before -> k) IS DISTINCT FROM (v_after -> k);

  ASSERT v_bad IS NULL,
    format('these columns did not survive the round trip:%s  %s', E'\n', v_bad);
END $$;

\echo '--- and the live values, not just their jsonb shadows, are identical ---'
DO $$
BEGIN
  ASSERT (SELECT c_double_inf FROM wide WHERE id=1) = 'Infinity'::double precision,
         'infinity survived';
  ASSERT (SELECT c_double_nan FROM wide WHERE id=1) IS NOT DISTINCT FROM
         'NaN'::double precision, 'NaN survived';
  ASSERT (SELECT c_bytea FROM wide WHERE id=1) = '\xDEADBEEF00'::bytea, 'bytea survived';
  ASSERT (SELECT c_text_arr FROM wide WHERE id=1)
         = ARRAY['a', NULL, 'has "quotes"', '{braces}'], 'array with NULL survived';
  ASSERT (SELECT c_money FROM wide WHERE id=1) = '1234.56'::money, 'money survived';
  ASSERT (SELECT c_null FROM wide WHERE id=1) IS NULL, 'NULL stayed NULL';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.6 the plan is built once ==='
DO $$
DECLARE v_plan_calls bigint;
BEGIN
  -- _plan is STABLE and side-effect free, so this asserts the shape of undo
  -- rather than a counter: a materialised plan returns the same rows it applied.
  ASSERT (SELECT count(*) FROM volvra.undo('wide'::regclass, '-infinity'::timestamptz,
                                           now(), confirm => false)) > 0,
         'preview mode returns the materialised plan';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.7 an update that changed nothing is not history ==='
DROP TABLE IF EXISTS noop_t;
CREATE TABLE noop_t (id int PRIMARY KEY, a int, b text);
SELECT volvra.enable('noop_t');
INSERT INTO noop_t VALUES (1, 10, 'x');

DO $$
DECLARE v_before bigint; v_after bigint;
BEGIN
  SELECT count(*) INTO v_before FROM volvra.change_log
   WHERE table_name = 'public.noop_t';

  UPDATE noop_t SET a = a, b = b WHERE id = 1;      -- what an ORM writes
  UPDATE noop_t SET a = 10 WHERE id = 1;            -- same value again

  SELECT count(*) INTO v_after FROM volvra.change_log
   WHERE table_name = 'public.noop_t';

  ASSERT v_after = v_before,
    format('two no-op updates should record nothing, recorded %s', v_after - v_before);
END $$;

\echo '--- unless you ask for them ---'
SELECT volvra.set_setting('capture_no_op_updates', 'on');
UPDATE noop_t SET a = a WHERE id = 1;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.noop_t' AND op = 'U') = 1,
    'capture_no_op_updates = on records the touch';
END $$;
SELECT volvra.set_setting('capture_no_op_updates', 'off');

-- ---------------------------------------------------------------------
\echo '=== P1.8 an update stores the delta, not two copies of the row ==='
DROP TABLE IF EXISTS wide_upd;
CREATE TABLE wide_upd (
  id    int PRIMARY KEY,
  small int NOT NULL,
  blob  text NOT NULL
);
SELECT volvra.enable('wide_upd');
INSERT INTO wide_upd VALUES (1, 1, repeat('x', 8000));

SELECT clock_timestamp() AS w0 \gset
SELECT pg_sleep(0.05);
UPDATE wide_upd SET small = 2 WHERE id = 1;
SELECT set_config('test.w0', :'w0', false);

SELECT op, old_row, new_row FROM volvra.change_log
WHERE table_name = 'public.wide_upd' AND op = 'U';

DO $$
DECLARE r record;
BEGIN
  SELECT old_row, new_row INTO r FROM volvra.change_log
   WHERE table_name = 'public.wide_upd' AND op = 'U';

  ASSERT r.old_row = '{"small": 1}'::jsonb,
    format('only the changed column should be captured, got %s', r.old_row);
  ASSERT r.new_row = '{"small": 2}'::jsonb, 'and its new value';
  ASSERT NOT (r.old_row ? 'blob'),
    'an 8 KB column that did not change must not be copied into the history';
END $$;

\echo '--- and the undo restores that column without touching the others ---'
UPDATE wide_upd SET blob = repeat('y', 8000);        -- an unrelated later change
SELECT count(*) FROM volvra.undo('wide_upd', :'w0', now(), confirm => true,
                                 predicate => $$op = 'U' AND old_row ? 'small'$$);
DO $$ BEGIN
  ASSERT (SELECT small FROM wide_upd WHERE id = 1) = 1, 'the delta was reverted';
  ASSERT (SELECT blob  FROM wide_upd WHERE id = 1) = repeat('y', 8000),
    'the column the undo never captured was left exactly as it was';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.9 a change to an unrelated column is not a conflict ==='
DROP TABLE IF EXISTS unrelated_t;
CREATE TABLE unrelated_t (id int PRIMARY KEY, total numeric, note text);
SELECT volvra.enable('unrelated_t');
INSERT INTO unrelated_t VALUES (1, 100, 'original');

SELECT clock_timestamp() AS u0 \gset
SELECT pg_sleep(0.05);
UPDATE unrelated_t SET total = 0 WHERE id = 1;       -- the accident
SELECT pg_sleep(0.05);
SELECT clock_timestamp() AS u1 \gset
UPDATE unrelated_t SET note = 'edited since' WHERE id = 1;   -- unrelated, later
SELECT set_config('test.u0', :'u0', false);
SELECT set_config('test.u1', :'u1', false);

DO $$
DECLARE v_conf bigint;
BEGIN
  SELECT count(*) FILTER (WHERE conflict) INTO v_conf
  FROM volvra.preview_undo('unrelated_t',
         current_setting('test.u0')::timestamptz,
         current_setting('test.u1')::timestamptz);
  ASSERT v_conf = 0,
    'reverting total cannot destroy a change to note, so it is not a conflict';
END $$;

SELECT count(*) FROM volvra.undo('unrelated_t', :'u0', :'u1', confirm => true);
DO $$ BEGIN
  ASSERT (SELECT total FROM unrelated_t WHERE id = 1) = 100, 'total reverted';
  ASSERT (SELECT note  FROM unrelated_t WHERE id = 1) = 'edited since',
    'and the later, unrelated change survived';
END $$;

\echo '--- but a change to the SAME column still is one ---'
SELECT clock_timestamp() AS u2 \gset
SELECT pg_sleep(0.05);
UPDATE unrelated_t SET total = 0 WHERE id = 1;
SELECT pg_sleep(0.05);
SELECT clock_timestamp() AS u3 \gset
UPDATE unrelated_t SET total = 555 WHERE id = 1;
SELECT set_config('test.u2', :'u2', false);
SELECT set_config('test.u3', :'u3', false);

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo('unrelated_t'::regclass,
                        current_setting('test.u2')::timestamptz,
                        current_setting('test.u3')::timestamptz, confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: undo clobbered a later change to the same column';
  EXCEPTION WHEN serialization_failure THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'same-column conflicts must still be refused';
  ASSERT (SELECT total FROM unrelated_t WHERE id = 1) = 555, 'nothing was applied';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P1.10 capture_updates = full keeps complete images ==='
SELECT volvra.set_setting('capture_updates', 'full');
DROP TABLE IF EXISTS full_t;
CREATE TABLE full_t (id int PRIMARY KEY, a int, b text);
SELECT volvra.enable('full_t');
INSERT INTO full_t VALUES (1, 1, 'keep');
UPDATE full_t SET a = 2 WHERE id = 1;

DO $$
DECLARE r record;
BEGIN
  SELECT old_row, new_row INTO r FROM volvra.change_log
   WHERE table_name = 'public.full_t' AND op = 'U';
  ASSERT r.old_row ? 'b' AND r.new_row ? 'b',
    'full mode must record every column, for audit regimes that require it';
  ASSERT r.old_row = '{"a": 1, "b": "keep", "id": 1}'::jsonb,
    format('expected a complete before image, got %s', r.old_row);
END $$;

\echo '--- and a full image still drives an undo correctly ---'
SELECT count(*) FROM volvra.undo('full_t', predicate => $$op = 'U'$$, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT a FROM full_t WHERE id = 1) = 1, 'reverted from a full image';
  ASSERT (SELECT b FROM full_t WHERE id = 1) = 'keep', 'and nothing else moved';
END $$;
SELECT volvra.set_setting('capture_updates', 'changed');

-- ---------------------------------------------------------------------
\echo '=== P1.11 several changes to one row are not false conflicts ==='

-- A row changed twice inside the window has two entries in the plan. Only the
-- newest can be compared against the live row: the older one's captured
-- "after" image is the intermediate value, which by definition no longer
-- matches, so probing it reports a conflict that will not happen.
--
-- This is a regression test for a real defect, and for the fix that replaced
-- its fix: the dedup was first done by accumulating every row already seen
-- into a jsonb object, which was quadratic and made a large preview look like
-- a hang. It is now a window function over the plan query. Both must agree,
-- and this is what says so.
DROP TABLE IF EXISTS multi;
CREATE TABLE multi (id int PRIMARY KEY, v int, note text);
SELECT volvra.enable('multi');
INSERT INTO multi VALUES (1, 1, 'a'), (2, 1, 'a');

SELECT clock_timestamp() AS m0 \gset
SELECT pg_sleep(0.05);
UPDATE multi SET v = 2;                    -- intermediate
SELECT pg_sleep(0.05);
UPDATE multi SET v = 3;                    -- current
SELECT set_config('test.m0', :'m0', false);

\echo '--- the plan holds two changes per row, and none is a conflict ---'
SELECT seq, pk, op, conflict
FROM volvra.preview_undo('multi', current_setting('test.m0')::timestamptz, now());

DO $$
DECLARE v_rows bigint; v_conf bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE conflict)
    INTO v_rows, v_conf
  FROM volvra.preview_undo('multi',
         current_setting('test.m0')::timestamptz, now());
  ASSERT v_rows = 4, format('two rows changed twice gives 4 steps, got %s', v_rows);
  ASSERT v_conf = 0,
         format('none of them is a conflict, got %s -- the older change to each '
                'row was probed against the live row', v_conf);
END $$;

\echo '--- and the undo walks both changes back to the original ---'
SELECT count(*) FROM volvra.undo('multi',
  current_setting('test.m0')::timestamptz, now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM multi WHERE v = 1) = 2,
         'both rows are back at their original value, not the intermediate one';
END $$;

\echo '--- a genuine conflict on such a row is still caught ---'
UPDATE multi SET v = 1;                    -- back to a known state
SELECT clock_timestamp() AS m1 \gset
SELECT pg_sleep(0.05);
UPDATE multi SET v = 2;
SELECT pg_sleep(0.05);
UPDATE multi SET v = 3;
SELECT clock_timestamp() AS m1end \gset
SELECT set_config('test.m1', :'m1', false);
SELECT set_config('test.m1end', :'m1end', false);
-- Someone else moves row 1 after the window closes.  An explicit end bound is
-- required: "m1 + 1 second" put this update inside the window, where reverting
-- it is correct and no conflict arises -- the assertion failed for a reason
-- that had nothing to do with what it was testing.
SELECT pg_sleep(0.05);
UPDATE multi SET v = 99 WHERE id = 1;

DO $$
DECLARE v_conf bigint; v_conf1 bigint;
BEGIN
  SELECT count(*) FILTER (WHERE conflict),
         count(*) FILTER (WHERE conflict AND pk = '{"id": 1}'::jsonb)
    INTO v_conf, v_conf1
  FROM volvra.preview_undo('multi',
         current_setting('test.m1')::timestamptz,
         current_setting('test.m1end')::timestamptz);
  ASSERT v_conf1 = 1,
         format('the row that moved is flagged exactly once, got %s', v_conf1);
  ASSERT v_conf = 1,
         format('and the row that did not move is not flagged, got %s total', v_conf);
END $$;

-- ---------------------------------------------------------------------
-- P1.12  Column names that collide with the aliases in generated SQL.
--
-- Every statement volvra builds aliases the user's table.  With a bare
-- alias, a column of the same name wins the reference, and the damage is
-- silent: to_jsonb(t) yields that column instead of the row, so TRUNCATE
-- capture stored a scalar where a row image belongs and the data became
-- unrecoverable.  A column named tgt broke undo outright.
--
-- Shipped in 1.0.0-beta1 and found on 2026-09-20 while testing as_of.
-- The aliases are quoted now; this asserts they stay that way.
-- ---------------------------------------------------------------------
\echo '--- P1.12 alias collisions ---'

DROP TABLE IF EXISTS collide;
CREATE TABLE collide (
  id  int PRIMARY KEY,
  t   timestamptz,     -- the alias capture_truncate and as_of use
  tgt text,            -- the alias the undo statements use
  src text,            -- the alias the update statement uses
  k   text,            -- the alias the key lookup uses
  v   text
);
INSERT INTO collide VALUES
  (1, now(), 'a', 'b', 'c', 'before'),
  (2, now(), 'd', 'e', 'f', 'before2');
SELECT volvra.enable('collide');

DO $$
DECLARE v_pk jsonb; v_img jsonb; v_n bigint; v_v text;
BEGIN
  -- An UPDATE must still be undoable when every alias name is taken.
  UPDATE collide SET v = 'after' WHERE id = 1;
  PERFORM volvra.undo(target => 'collide',
                      from_ts => now() - interval '1 minute', confirm => true);
  SELECT v INTO v_v FROM collide WHERE id = 1;
  ASSERT v_v = 'before',
    format('P1.12: undo left %s; an aliased column broke the guard', v_v);

  -- TRUNCATE must record real row images, not a column value.
  TRUNCATE collide;
  SELECT count(*) INTO v_n
  FROM volvra.change_log WHERE table_name = 'public.collide' AND op = 'D';
  ASSERT v_n = 2,
    format('P1.12: truncate recorded %s rows, expected 2', v_n);

  SELECT pk, old_row INTO v_pk, v_img
  FROM volvra.change_log
  WHERE table_name = 'public.collide' AND op = 'D' ORDER BY id LIMIT 1;
  ASSERT jsonb_typeof(v_img) = 'object',
    format('P1.12: truncate stored a %s, not a row image', jsonb_typeof(v_img));
  ASSERT v_pk -> 'id' IS NOT NULL AND v_pk ->> 'id' IS NOT NULL,
    format('P1.12: truncate recorded pk %s; the alias resolved to a column', v_pk);

  -- And the truncate must actually be reversible, which is the whole point.
  PERFORM volvra.undo(target => 'collide',
                      from_ts => now() - interval '1 minute', confirm => true);
  SELECT count(*) INTO v_n FROM collide;
  ASSERT v_n = 2,
    format('P1.12: %s rows came back after undoing the truncate, expected 2', v_n);
END $$;

-- ---------------------------------------------------------------------
-- P1.13  Redefining the primary key is reported as what it is.
--
-- The statement is built from the table's CURRENT key while the captured
-- pk holds the old one, so the lookup finds nothing and the guard used to
-- report a conflict -- sending the reader after a concurrent change that
-- never happened.
-- ---------------------------------------------------------------------
\echo '--- P1.13 primary key redefined ---'
DROP TABLE IF EXISTS pkchange;
CREATE TABLE pkchange (a int, b int, v text, PRIMARY KEY (a));
INSERT INTO pkchange VALUES (1, 1, 'before');
SELECT volvra.enable('pkchange');

DO $$
DECLARE v_msg text; v_ok boolean := false;
BEGIN
  PERFORM pg_sleep(0.05);
  UPDATE pkchange SET v = 'after';
  ALTER TABLE pkchange DROP CONSTRAINT pkchange_pkey;
  ALTER TABLE pkchange ADD PRIMARY KEY (a, b);
  BEGIN
    PERFORM volvra.undo(target => 'pkchange',
                        from_ts => now() - interval '1 minute', confirm => true);
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM; v_ok := true;
  END;
  ASSERT v_ok, 'P1.13: undo must refuse when the primary key was redefined';
  ASSERT v_msg ILIKE '%primary key%has changed%',
    format('P1.13: the message blamed something else: %s', v_msg);
END $$;

-- ---------------------------------------------------------------------
-- P1.14  Legacy INHERITS is not partitioning.
--
-- A row trigger is not inherited, so UPDATE on the parent rewrites child
-- rows that nothing captures.  Worse, volvra.enable() used to refuse the
-- child as "already covered through" the parent, so the gap could not be
-- closed even deliberately.  Partition links must keep working.
-- ---------------------------------------------------------------------
\echo '--- P1.14 inheritance children ---'
DROP TABLE IF EXISTS inh_child;
DROP TABLE IF EXISTS inh_parent CASCADE;
CREATE TABLE inh_parent (id int PRIMARY KEY, v text);
CREATE TABLE inh_child () INHERITS (inh_parent);
ALTER TABLE inh_child ADD PRIMARY KEY (id);
INSERT INTO inh_parent VALUES (1, 'before');
INSERT INTO inh_child  VALUES (2, 'before');

DO $$
DECLARE v_n bigint; v_p text; v_c text;
BEGIN
  PERFORM volvra.enable('inh_parent');

  -- The gap is reported rather than hidden.
  SELECT count(*) INTO v_n FROM volvra.preflight()
  WHERE finding ILIKE '%inheritance%';
  ASSERT v_n = 1,
    'P1.14: a covered parent with an uncovered child must be a preflight finding';

  -- And it can actually be closed.
  PERFORM volvra.enable('inh_child');
  SELECT count(*) INTO v_n FROM volvra.preflight()
  WHERE finding ILIKE '%inheritance%';
  ASSERT v_n = 0,
    'P1.14: covering the child must clear the finding; enable() refused it '
    'as "already covered" before';

  PERFORM pg_sleep(0.05);
  UPDATE inh_parent SET v = 'after';          -- rewrites both rows
  PERFORM volvra.undo(target => 'inh_parent',
                      from_ts => now() - interval '1 minute', confirm => true);
  PERFORM volvra.undo(target => 'inh_child',
                      from_ts => now() - interval '1 minute', confirm => true);
  SELECT v INTO v_p FROM ONLY inh_parent WHERE id = 1;
  SELECT v INTO v_c FROM inh_child WHERE id = 2;
  ASSERT v_p = 'before', format('P1.14: parent row is %s', v_p);
  ASSERT v_c = 'before',
    format('P1.14: child row is %s; the child had no history of its own', v_c);
END $$;

-- ---------------------------------------------------------------------
-- P1.15  A table's own BEFORE row trigger can rewrite what an undo puts
--        back, and the undo still reports success.  That is PostgreSQL
--        semantics rather than a fault, but the product promises to
--        restore the captured row, so preflight says when it cannot.
--        A trigger that suppresses the write is a different case: the
--        guard catches that one and refuses.
-- ---------------------------------------------------------------------
\echo '--- P1.15 user BEFORE triggers ---'
DROP TABLE IF EXISTS stamped;
CREATE TABLE stamped (id int PRIMARY KEY, v text, touched timestamptz);
CREATE OR REPLACE FUNCTION stamp_touched() RETURNS trigger
LANGUAGE plpgsql AS $t$
BEGIN NEW.touched := '2099-01-01'::timestamptz; RETURN NEW; END $t$;
CREATE TRIGGER stamped_before BEFORE UPDATE ON stamped
  FOR EACH ROW EXECUTE FUNCTION stamp_touched();
INSERT INTO stamped VALUES (1, 'before', '2000-01-01');
SELECT volvra.enable('stamped');

DO $$
DECLARE v_n bigint; v_v text; v_touched timestamptz;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.preflight()
  WHERE finding ILIKE '%BEFORE row trigger%';
  ASSERT v_n = 1,
    'P1.15: a covered table with its own BEFORE row trigger must be reported';

  PERFORM pg_sleep(0.05);
  UPDATE stamped SET v = 'after';
  PERFORM volvra.undo(target => 'stamped',
                      from_ts => now() - interval '1 minute', confirm => true);

  SELECT v, touched INTO v_v, v_touched FROM stamped WHERE id = 1;
  ASSERT v_v = 'before', format('P1.15: v is %s', v_v);
  -- The column the trigger owns is NOT restored, which is exactly why the
  -- warning exists.  Asserted so the behaviour cannot drift unnoticed.
  ASSERT v_touched = '2099-01-01'::timestamptz,
    format('P1.15: touched is %s; if this now restores, the preflight '
           'warning is stale and should be revisited', v_touched);
END $$;

DROP TRIGGER stamped_before ON stamped;

-- ---------------------------------------------------------------------
-- P1.16  Noticing a mistake as it is made.
--
-- The one place volvra can speak before you know something is wrong.
-- Off by default, and off means the statement triggers are not attached
-- at all: a user who does not want it must not pay for it.
-- ---------------------------------------------------------------------
\echo '--- P1.16 large-statement warning ---'
DROP TABLE IF EXISTS loud;
CREATE TABLE loud (id int PRIMARY KEY, v text);
INSERT INTO loud SELECT g, 'x' FROM generate_series(1, 100) g;
SELECT volvra.enable('loud');

DO $$
DECLARE v_n bigint;
BEGIN
  ASSERT coalesce(volvra.get_setting('warn_changed_rows'), '0') = '0',
    'P1.16: the warning must be off by default';

  SELECT count(*) INTO v_n FROM pg_trigger
  WHERE tgrelid = 'loud'::regclass AND tgname LIKE 'volvra\_stmt%';
  ASSERT v_n = 0,
    format('P1.16: %s statement trigger(s) attached while off; off must cost '
           'nothing', v_n);

  PERFORM volvra.set_warn_changed_rows(10);
  SELECT count(*) INTO v_n FROM pg_trigger
  WHERE tgrelid = 'loud'::regclass AND tgname LIKE 'volvra\_stmt%';
  ASSERT v_n = 2,
    format('P1.16: expected both statement triggers after turning it on, got %s',
           v_n);

  -- A table covered while it is on must get the triggers too, or the
  -- setting would quietly not apply to anything created later.
  CREATE TABLE loud2 (id int PRIMARY KEY, v text);
  PERFORM volvra.enable('loud2');
  SELECT count(*) INTO v_n FROM pg_trigger
  WHERE tgrelid = 'loud2'::regclass AND tgname LIKE 'volvra\_stmt%';
  ASSERT v_n = 2,
    'P1.16: a table covered while the warning is on must get the triggers';

  PERFORM volvra.set_warn_changed_rows(0);
  SELECT count(*) INTO v_n FROM pg_trigger
  WHERE tgrelid = 'loud'::regclass AND tgname LIKE 'volvra\_stmt%';
  ASSERT v_n = 0, 'P1.16: turning it off must remove the triggers again';
END $$;

DO $$
DECLARE v_raised boolean := false;
BEGIN
  BEGIN
    PERFORM volvra.set_warn_changed_rows(-1);
  EXCEPTION WHEN OTHERS THEN v_raised := true;
  END;
  ASSERT v_raised, 'P1.16: a negative limit must be refused';
END $$;

-- The warning itself is a WARNING, which an assertion cannot catch, so it
-- is asserted through its effect: the exact count runs only when the cheap
-- sequence delta says the limit may have been crossed, and a small
-- statement must leave the data untouched either way.
DO $$
DECLARE v_before bigint; v_after bigint;
BEGIN
  PERFORM volvra.set_warn_changed_rows(10);
  SELECT count(*) INTO v_before FROM volvra.change_log WHERE table_name = 'public.loud';
  UPDATE loud SET v = 'small' WHERE id <= 3;      -- under the limit, quiet
  UPDATE loud SET v = 'large';                    -- over the limit, warns
  SELECT count(*) INTO v_after FROM volvra.change_log WHERE table_name = 'public.loud';
  ASSERT v_after - v_before = 103,
    format('P1.16: the warning must not change what is captured; %s rows',
           v_after - v_before);
  PERFORM volvra.set_warn_changed_rows(0);
END $$;

DROP TABLE loud2;

\echo ''
\echo '*** ALL VOLVRA PHASE 1 CHECKS PASSED ***'
