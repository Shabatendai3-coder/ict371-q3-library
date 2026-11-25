-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student: Patience Shaba (202409214) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3, public;

-- (a) Tables and seed data -------------------------------------------------------
CREATE TABLE books (
  book_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INTEGER NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE NULL,
  new_returned_on  DATE NULL,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INTEGER NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);
INSERT INTO books (title) VALUES
 ('Database System Concepts'), ('Introduction to Algorithms'), ('Computer Networks');
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
 (1, 'Chanda Mwape',   '2026-10-01', '2026-10-15', NULL,         0),   -- open, overdue
 (1, 'Mwila Zulu',     '2026-10-05', '2026-10-19', '2026-10-19', 0),   -- returned on due date: no fine
 (2, 'Temwani Tembo',  '2026-10-10', '2026-10-24', '2026-10-29', 10),  -- returned 5 days late: K10
 (2, 'Bwalya Sakala',  '2026-11-01', '2026-11-15', NULL,         0),   -- open, overdue
 (3, 'Natasha Lungu',  CURRENT_DATE - 3, CURRENT_DATE + 11, NULL, 0),  -- open, on time
 (3, 'Kunda Simbeye',  '2026-09-01', '2026-09-15', '2026-09-14', 0);   -- returned early

-- (b) Function ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_returned DATE; v_end DATE; v_days INTEGER;
BEGIN
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date is required.'; END IF;
  SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loan % does not exist.', p_loan_id; END IF;
  v_end  := LEAST(p_as_of, COALESCE(v_returned, p_as_of));   -- fines stop at the return date
  v_days := GREATEST(v_end - v_due, 0);                       -- never negative
  RETURN (v_days * 2)::NUMERIC(10,2);                         -- K2 per day
END; $$;

-- (c) Procedure ------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE;
BEGIN
  IF p_returned_on IS NULL THEN RAISE EXCEPTION 'Return date is required.'; END IF;
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loan % does not exist.', p_loan_id; END IF;
  IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan % was already returned.', p_loan_id; END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date cannot be before the borrowed date.';
  END IF;
  -- One UPDATE stores the return date and the final fine together.
  UPDATE loans
     SET returned_on = p_returned_on,
         fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
   WHERE loan_id = p_loan_id;
END; $$;

-- (d) Trigger -------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
      VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_loans_audit AFTER UPDATE ON loans FOR EACH ROW
  WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
  EXECUTE FUNCTION fn_trg_loan_audit();

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY 1;
SELECT fn_loan_fine(2, DATE '2026-10-19') AS due_day_fine_is_zero;
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END $$;
CALL pr_return_loan(5, CURRENT_DATE);                        -- valid return, logged by trigger
DO $$ BEGIN CALL pr_return_loan(5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already returned): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, DATE '2026-09-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (before borrowed): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END $$;
UPDATE loans SET borrower_name = 'Natasha Lungu' WHERE loan_id = 5;   -- date unchanged: no audit row
SELECT * FROM loan_audit ORDER BY audit_id;                           -- exactly one row

-- (e) View -----------------------------------------------------------------------------------
CREATE VIEW v_overdue_loans AS
  SELECT l.loan_id, b.title AS book_title, l.borrower_name, l.due_on,
         fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
  FROM loans l JOIN books b ON b.book_id = l.book_id
  WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans ORDER BY loan_id;

-- (f) Index ------------------------------------------------------------------------------------
-- Partial index: only unreturned loans are indexed (a small, hot subset), keyed by book_id.
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;   -- tiny table: forces the plan to show the index
EXPLAIN SELECT loan_id, borrower_name, due_on FROM loans
WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job -------------------------------------------------------------------------------
-- Assumption: a loan counts when it is unreturned as of p_as_of (never returned, or returned
-- after that date) and is past its due date on p_as_of.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql SET search_path = q3, public AS $$
BEGIN
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date is required.'; END IF;
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END; $$;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                        -- rerun replaces the same row
SELECT * FROM overdue_summary ORDER BY snapshot_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *', $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q3_refresh_overdue';
