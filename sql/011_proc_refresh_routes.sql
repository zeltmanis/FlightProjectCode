-- =========================================================
-- 011_proc_refresh_routes.sql
--
-- Derives routes from flights. Must run AFTER refresh_flights
-- (no source data otherwise).
--
-- One row per distinct (origin, dest) pair.
--
-- Usage:
--   CALL refresh_routes();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_routes()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_routes', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    TRUNCATE routes RESTART IDENTITY;

    INSERT INTO routes (origin_airport_code, dest_airport_code)
    SELECT DISTINCT origin_airport_code, dest_airport_code
    FROM flights
    ORDER BY origin_airport_code, dest_airport_code;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE job_log
       SET end_time       = clock_timestamp(),
           status         = 'OK',
           rows_processed = v_rows
     WHERE job_id = v_job_id;

EXCEPTION WHEN OTHERS THEN
    UPDATE job_log
       SET end_time = clock_timestamp(),
           status   = 'FAILED',
           errors   = SQLERRM
     WHERE job_id = v_job_id;
    RAISE;
END;
$$;

COMMENT ON PROCEDURE refresh_routes() IS
    'Derives routes from distinct (origin, dest) pairs in flights; logs to job_log.';
