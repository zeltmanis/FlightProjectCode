-- =========================================================
-- 014_proc_run_pipeline.sql
--
-- Master orchestrator. Runs every cleaning + enrichment +
-- prediction procedure in the correct dependency order:
--
--   airports          (independent dim)
--   airlines          (independent dim)
--   weather_hourly    (independent fact, no FKs)
--   flights           (FK → airports, airlines)
--   routes            (derived from flights)
--   flights_enriched  (joins flights × weather_hourly)
--   model_…           (trained from flights_enriched 2022-2023)
--   predict_flights   (writes 2024 predictions)
--   validate_…        (writes validation_results)
--
-- Logs its own row in job_log ('run_pipeline') so you can
-- see total pipeline duration. Each child procedure also
-- logs its own row, so the audit trail shows every step.
--
-- Usage:
--   CALL run_pipeline();
-- =========================================================

CREATE OR REPLACE PROCEDURE run_pipeline()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_total   INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('run_pipeline', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    -- Run each step in dependency order. If any one fails,
    -- the EXCEPTION block at the bottom marks this run FAILED.
    CALL refresh_airports();
    CALL refresh_airlines();
    CALL refresh_weather_hourly();
    CALL refresh_flights();
    CALL refresh_routes();
    CALL refresh_flights_enriched();
    CALL refresh_model_route_hour_weather();
    CALL predict_flights();
    CALL validate_predictions();

    -- Sum the rows processed across the steps that ran inside
    -- this pipeline run (i.e. with start_time >= our start_time).
    SELECT COALESCE(SUM(rows_processed), 0) INTO v_total
    FROM   job_log
    WHERE  job_name <> 'run_pipeline'
      AND  start_time >= (SELECT start_time FROM job_log WHERE job_id = v_job_id);

    UPDATE job_log
       SET end_time       = clock_timestamp(),
           status         = 'OK',
           rows_processed = v_total
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

COMMENT ON PROCEDURE run_pipeline() IS
    'Master orchestrator — runs all cleaning/enrichment procedures in order; logs to job_log.';
