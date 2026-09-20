-- =====================================================================
-- pgVolvra as_of -- the table as it was, read-only
--
-- Gate: as_of() reconstructs a covered table at a past instant without
-- writing anything, and is either right or loud.  It is not a lookup:
-- an UPDATE stores only the columns that changed, so a row at time T is
-- the row as it stands now overlaid with the old values of every change
-- since T, applied newest first.
--
-- The assertions below exist because each one has a way of being
-- silently wrong rather than failing: a partial update overlaying in
-- the wrong order, a deleted row staying gone, a row inserted after T
-- surviving into the past, a resurrected primary key returning the
-- wrong generation.  Several assert that as_of changed nothing at all.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP SCHEMA IF EXISTS ao CASCADE;
CREATE SCHEMA ao;
SET search_path = ao, public;

CREATE TABLE ao.orders (
  id       bigint PRIMARY KEY,
  customer text NOT NULL,
  status   text NOT NULL,
  total    numeric(10,2)
);

INSERT INTO ao.orders VALUES
  (1, 'ayesha', 'shipped', 240.00),
  (2, 'omar',   'pending',  99.50),
  (3, 'lena',   'shipped',  18.75),
  (4, 'sam',    'paid',     50.00);

SELECT volvra.enable('ao.orders');

-- A1. A table with history answers, and answering writes nothing.
DO $$
DECLARE v_before bigint; v_after bigint; v_rows bigint;
BEGIN
  SELECT count(*) INTO v_before FROM volvra.change_log;
  SELECT count(*) INTO v_rows FROM volvra.as_of('ao.orders', now());
  SELECT count(*) INTO v_after  FROM volvra.change_log;
  ASSERT v_rows = 4, format('A1: expected 4 rows, got %s', v_rows);
  ASSERT v_before = v_after,
    'A1: as_of wrote to the history; it must be read-only';
END $$;

-- Freeze an instant, then make every kind of change after it.
CREATE TEMP TABLE ao_mark AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);

UPDATE ao.orders SET status = 'cancelled' WHERE id = 1;   -- one column
UPDATE ao.orders SET status = 'refunded'  WHERE id = 2;   -- two updates,
UPDATE ao.orders SET total  = 1.00        WHERE id = 2;   --   different columns
DELETE FROM ao.orders WHERE id = 3;                       -- gone since
INSERT INTO ao.orders VALUES (5, 'noor', 'new', 7.00);    -- arrived since
-- id 4 is deliberately untouched

-- A2. Every row is reconstructed exactly as it stood at the mark.
DO $$
DECLARE v jsonb; v_n bigint;
BEGIN
  SELECT count(*) INTO v_n
  FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark));
  ASSERT v_n = 4, format('A2: expected 4 rows at the mark, got %s', v_n);

  -- updated once: the old value comes back
  SELECT r INTO v FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark)) AS r
  WHERE (r ->> 'id')::bigint = 1;
  ASSERT v ->> 'status' = 'shipped',
    format('A2: id 1 status was %s, expected shipped', v ->> 'status');

  -- updated twice in different columns: both old values come back, which
  -- is the case a wrong overlay order gets wrong
  SELECT r INTO v FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark)) AS r
  WHERE (r ->> 'id')::bigint = 2;
  ASSERT v ->> 'status' = 'pending',
    format('A2: id 2 status was %s, expected pending', v ->> 'status');
  ASSERT (v ->> 'total')::numeric = 99.50,
    format('A2: id 2 total was %s, expected 99.50', v ->> 'total');

  -- deleted since: the row is present again
  SELECT r INTO v FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark)) AS r
  WHERE (r ->> 'id')::bigint = 3;
  ASSERT v IS NOT NULL, 'A2: id 3 was deleted after the mark and must reappear';
  ASSERT v ->> 'customer' = 'lena', 'A2: id 3 came back with the wrong values';

  -- untouched: unchanged
  SELECT r INTO v FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark)) AS r
  WHERE (r ->> 'id')::bigint = 4;
  ASSERT v ->> 'status' = 'paid', 'A2: id 4 never changed and must be as it is';

  -- inserted since: absent from the past
  ASSERT NOT EXISTS (
    SELECT 1 FROM volvra.as_of('ao.orders', (SELECT t FROM ao_mark)) AS r
    WHERE (r ->> 'id')::bigint = 5),
    'A2: id 5 was inserted after the mark and must not exist at it';
END $$;

-- A3. The live table is untouched by any of the above.
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM ao.orders;
  ASSERT v_n = 4, format('A3: live table has %s rows, expected 4', v_n);
  ASSERT EXISTS (SELECT 1 FROM ao.orders WHERE id = 5),
    'A3: as_of must not have removed the row inserted after the mark';
  ASSERT NOT EXISTS (SELECT 1 FROM ao.orders WHERE id = 3),
    'A3: as_of must not have resurrected the deleted row in the live table';
END $$;

-- A4. A future instant is simply the table as it stands.
DO $$
DECLARE v_now bigint; v_future bigint;
BEGIN
  SELECT count(*) INTO v_now FROM ao.orders;
  SELECT count(*) INTO v_future
  FROM volvra.as_of('ao.orders', now() + interval '1 hour');
  ASSERT v_now = v_future,
    format('A4: future as_of gave %s rows, live table has %s', v_future, v_now);
END $$;

-- A5. TRUNCATE is recoverable in the past as well as by undo.
CREATE TABLE ao.wiped (id int PRIMARY KEY, v text);
INSERT INTO ao.wiped VALUES (1,'a'),(2,'b'),(3,'c');
SELECT volvra.enable('ao.wiped');
CREATE TEMP TABLE ao_mark2 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
TRUNCATE ao.wiped;

DO $$
DECLARE v_live bigint; v_past bigint;
BEGIN
  SELECT count(*) INTO v_live FROM ao.wiped;
  SELECT count(*) INTO v_past
  FROM volvra.as_of('ao.wiped', (SELECT t FROM ao_mark2));
  ASSERT v_live = 0, 'A5: the table should be empty now';
  ASSERT v_past = 3,
    format('A5: expected 3 rows before the truncate, got %s', v_past);
END $$;

-- A6. A primary key deleted and reused must return the generation that
--     existed at the mark, not the one that replaced it.
CREATE TABLE ao.reused (id int PRIMARY KEY, v text);
INSERT INTO ao.reused VALUES (1,'original');
SELECT volvra.enable('ao.reused');
CREATE TEMP TABLE ao_mark3 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
DELETE FROM ao.reused WHERE id = 1;
INSERT INTO ao.reused VALUES (1,'replacement');

DO $$
DECLARE v jsonb;
BEGIN
  SELECT r INTO v FROM volvra.as_of('ao.reused', (SELECT t FROM ao_mark3)) AS r
  WHERE (r ->> 'id')::int = 1;
  ASSERT v ->> 'v' = 'original',
    format('A6: got %s, expected the generation alive at the mark', v ->> 'v');
END $$;

-- A7. Full-image capture reconstructs identically to delta capture.
CREATE TABLE ao.fullmode (id int PRIMARY KEY, a text, b text);
INSERT INTO ao.fullmode VALUES (1,'a1','b1');
SELECT volvra.enable('ao.fullmode');
SELECT volvra.set_capture_mode('ao.fullmode', 'full');
CREATE TEMP TABLE ao_mark4 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
UPDATE ao.fullmode SET a = 'a2' WHERE id = 1;

DO $$
DECLARE v jsonb;
BEGIN
  SELECT r INTO v FROM volvra.as_of('ao.fullmode', (SELECT t FROM ao_mark4)) AS r;
  ASSERT v ->> 'a' = 'a1' AND v ->> 'b' = 'b1',
    format('A7: full-mode reconstruction gave a=%s b=%s', v ->> 'a', v ->> 'b');
END $$;

-- A8. A table that was never covered is refused, not answered from thin air.
CREATE TABLE ao.never (id int PRIMARY KEY, v text);
INSERT INTO ao.never VALUES (1,'x');
DO $$
DECLARE v_raised boolean := false;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.as_of('ao.never', now());
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
  END;
  ASSERT v_raised,
    'A8: as_of on a never-covered table must refuse rather than return the '
    'present and call it the past';
END $$;

-- A9. A disabled table keeps answering, because disable() keeps the history.
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM volvra.disable('ao.fullmode');
  SELECT r INTO v FROM volvra.as_of('ao.fullmode', (SELECT t FROM ao_mark4)) AS r;
  ASSERT v ->> 'a' = 'a1',
    'A9: disable() retains history, so as_of must still answer for it';
END $$;

-- A10. A stored generated column is reconstructed, not recomputed from
--      the present.  It changes whenever its source does, so capture
--      records it and the overlay restores it.
CREATE TABLE ao.gen (id int PRIMARY KEY, n int, dbl int GENERATED ALWAYS AS (n * 2) STORED);
INSERT INTO ao.gen(id, n) VALUES (1, 5);
SELECT volvra.enable('ao.gen');
CREATE TEMP TABLE ao_mark5 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
UPDATE ao.gen SET n = 50 WHERE id = 1;

DO $$
DECLARE v jsonb;
BEGIN
  SELECT r INTO v FROM volvra.as_of('ao.gen', (SELECT t FROM ao_mark5)) AS r;
  ASSERT (v ->> 'n')::int = 5,
    format('A10: n was %s, expected 5', v ->> 'n');
  ASSERT (v ->> 'dbl')::int = 10,
    format('A10: generated column was %s, expected 10 -- it must be the '
           'value at the mark, not recomputed from the present', v ->> 'dbl');
END $$;

-- A11. An excluded column has no history, so it can only be reported as
--      it stands now.  Asserted so the limitation stays documented and
--      does not quietly become a wrong answer.
CREATE TABLE ao.excl (id int PRIMARY KEY, secret text, v text);
INSERT INTO ao.excl VALUES (1, 'old-secret', 'before');
SELECT volvra.enable('ao.excl');
SELECT volvra.exclude_columns('ao.excl', ARRAY['secret']);
CREATE TEMP TABLE ao_mark6 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
UPDATE ao.excl SET secret = 'new-secret', v = 'after' WHERE id = 1;

DO $$
DECLARE v jsonb;
BEGIN
  SELECT r INTO v FROM volvra.as_of('ao.excl', (SELECT t FROM ao_mark6)) AS r;
  ASSERT v ->> 'v' = 'before',
    format('A11: captured column was %s, expected before', v ->> 'v');
  ASSERT v ->> 'secret' = 'new-secret',
    format('A11: excluded column was %s; with no history it can only be the '
           'current value', v ->> 'secret');
END $$;

-- A12. A partitioned table answers as one table, and calling as_of on a
--      partition points at the ancestor instead of dead-ending.  Telling
--      the caller to enable() the partition would be a dead end, because
--      enable() refuses it as already covered through the parent.
CREATE TABLE ao.ev (id int, ts date, v text, PRIMARY KEY (id, ts))
  PARTITION BY RANGE (ts);
CREATE TABLE ao.ev_2026 PARTITION OF ao.ev
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
INSERT INTO ao.ev VALUES (1,'2026-06-01','before'), (2,'2026-07-01','before');
SELECT volvra.enable('ao.ev');
CREATE TEMP TABLE ao_mark7 AS SELECT clock_timestamp() AS t;
SELECT pg_sleep(0.2);
UPDATE ao.ev SET v = 'after' WHERE id = 1;
DELETE FROM ao.ev WHERE id = 2;
INSERT INTO ao.ev VALUES (3,'2026-08-01','new');

DO $$
DECLARE v_n bigint; v_msg text; v_raised boolean := false;
BEGIN
  SELECT count(*) INTO v_n
  FROM volvra.as_of('ao.ev', (SELECT t FROM ao_mark7));
  ASSERT v_n = 2,
    format('A12: expected 2 rows across partitions at the mark, got %s', v_n);

  ASSERT EXISTS (SELECT 1 FROM volvra.as_of('ao.ev', (SELECT t FROM ao_mark7)) AS r
                 WHERE (r ->> 'id')::int = 2),
    'A12: the row deleted after the mark must reappear';
  ASSERT NOT EXISTS (SELECT 1 FROM volvra.as_of('ao.ev', (SELECT t FROM ao_mark7)) AS r
                     WHERE (r ->> 'id')::int = 3),
    'A12: the row inserted after the mark must be absent';

  BEGIN
    PERFORM count(*) FROM volvra.as_of('ao.ev_2026', now());
  EXCEPTION WHEN OTHERS THEN
    v_raised := true; v_msg := SQLERRM;
  END;
  ASSERT v_raised, 'A12: a partition has no history of its own and must refuse';
  ASSERT v_msg ILIKE '%recorded under%ao.ev%',
    format('A12: the refusal must name the covered ancestor, got: %s', v_msg);
END $$;

\echo 'ALL VOLVRA AS_OF CHECKS PASSED'
