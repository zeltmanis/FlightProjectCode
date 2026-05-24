-- =========================================================
-- 023_proc_demo_refresh_weather_hourly.sql
--
-- Demo-only variant of refresh_weather_hourly() that uses
-- the "audited failure" pattern so FAILED rows persist in
-- job_log even when the work transaction rolls back.
--
-- HOW THE PATTERN WORKS:
--   1. INSERT the audit row, then COMMIT immediately
--      (so the RUNNING row persists outside the work tx)
--   2. Do the work in a sub-BEGIN block with EXCEPTION
--      handler that captures errors into a variable
--   3. After the sub-block exits, UPDATE the audit row
--      to FAILED or OK accordingly, COMMIT, then re-RAISE
--      if it failed
--
-- WHY THE DUAL APPROACH:
--   Regular refresh_*() procedures use the simpler
--   "one-transaction" pattern and roll back the audit row
--   on failure -- which is correct transactional behaviour
--   for production data pipelines (no partial state).
--   This demo procedure exists ONLY to make the failure
--   visible in job_log for presentation purposes.
--
-- CALLER REQUIREMENT:
--   Must be called with the caller in AUTOCOMMIT mode.
--   PostgreSQL rejects in-procedure COMMIT/ROLLBACK when
--   called from within an explicit outer transaction.
--
--   In DataGrip: toggle the Tx (transaction) indicator in
--   the SQL editor toolbar from "Manual" to "Auto" before
--   running the demo.
--   In psql: default is autocommit ON; nothing to change.
--   In Python: set conn.autocommit = True before calling.
--
-- Usage (in DataGrip with Tx: Auto):
--   CALL demo_refresh_weather_hourly();
-- =========================================================

CREATE OR REPLACE PROCEDURE demo_refresh_weather_hourly()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER := 0;
    v_failed  BOOLEAN := FALSE;
    v_err     TEXT;
BEGIN
    -- Step 1: insert audit row and COMMIT it.
    -- The RUNNING row persists from this point regardless of
    -- what happens to the work transaction below.
    INSERT INTO job_log (job_name, status)
    VALUES ('demo_refresh_weather_hourly', 'RUNNING')
    RETURNING job_id INTO v_job_id;
    COMMIT;

    -- Step 2: do the work in a sub-block with exception handler.
    -- The implicit savepoint at this BEGIN protects job_log
    -- (which is now outside the sub-block's scope, having been
    -- committed in step 1).
    BEGIN
        TRUNCATE weather_hourly;

        INSERT INTO weather_hourly (
            airport_code, obs_timestamp,
            temperature_c, relative_humidity, precipitation_mm,
            snowfall_cm, wind_speed_kmh, cloud_cover_pct, weather_code
        )
        SELECT
            UPPER(airport_code),
            (CAST(time AS TIMESTAMP) AT TIME ZONE 'UTC'),
            NULLIF(temperature_2m,       '')::DECIMAL,
            NULLIF(relative_humidity_2m, '')::DECIMAL,
            NULLIF(precipitation,        '')::DECIMAL,
            NULLIF(snowfall,             '')::DECIMAL,
            NULLIF(windspeed_10m,        '')::DECIMAL,
            NULLIF(cloud_cover,          '')::DECIMAL,
            NULLIF(weathercode,          '')::SMALLINT
        FROM staging.weather_raw
        WHERE airport_code IS NOT NULL
          AND airport_code <> ''
          AND time         IS NOT NULL
          AND time         <> '';

        GET DIAGNOSTICS v_rows = ROW_COUNT;

    EXCEPTION WHEN OTHERS THEN
        -- The sub-block's implicit savepoint has rolled back
        -- the TRUNCATE and partial INSERT. We capture the error
        -- message into a variable so we can write it to job_log
        -- after the sub-block exits.
        v_failed := TRUE;
        v_err    := SQLERRM;
    END;

    -- Step 3: update the audit row based on outcome, COMMIT,
    -- and re-RAISE if we failed.
    IF v_failed THEN
        UPDATE job_log
           SET end_time       = clock_timestamp(),
               status         = 'FAILED',
               errors         = v_err
         WHERE job_id = v_job_id;
        COMMIT;
        RAISE EXCEPTION '%', v_err
              USING HINT = 'See job_log table for the FAILED row.';
    ELSE
        UPDATE job_log
           SET end_time       = clock_timestamp(),
               status         = 'OK',
               rows_processed = v_rows
         WHERE job_id = v_job_id;
        COMMIT;
    END IF;
END;
$$;

COMMENT ON PROCEDURE demo_refresh_weather_hourly() IS
    'Demo variant of refresh_weather_hourly() with audited-failure pattern. Requires caller autocommit. Persists FAILED rows in job_log.';
