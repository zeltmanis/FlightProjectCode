-- =========================================================
-- failed_job_demo.sql -- the resilience story
--
-- Uses the demo procedure demo_refresh_weather_hourly() which
-- persists FAILED rows in job_log via the audited-failure
-- pattern (see sql/023_proc_demo_refresh_weather_hourly.sql).
-- The demo procedure mirrors refresh_weather_hourly() in
-- behaviour but commits its audit row outside the work
-- transaction.
--
-- IMPORTANT -- BEFORE YOU RUN:
--
--   DataGrip users: switch the SQL editor's transaction
--   mode from "Tx: Manual" to "Tx: Auto" (the indicator
--   in the toolbar above the editor). The procedure uses
--   in-body COMMIT/RAISE; PG rejects this if the caller
--   has an explicit outer transaction open.
--
--   psql/Python users: default autocommit is OK; nothing
--   to change.
--
-- Run line by line in DataGrip. The whole demo runs in
-- ~10 seconds.
--
-- Storyboard:
--   1. Show the audit trail before anything bad happens
--   2. Introduce dirty data -- one staging row with a
--      corrupt timestamp (simulating real-world ETL)
--   3. Run demo_refresh_weather_hourly() -- the TIMESTAMP
--      cast fails. Two things happen: (a) a FAILED row
--      lands in job_log with the error message; (b) PG
--      raises the exception so DataGrip shows the error
--   4. Prove the work was rolled back -- weather_hourly
--      is unchanged. But the FAILED row in job_log is
--      now visible
--   5. Fix the bad row
--   6. Re-run -- succeeds; fresh OK row in job_log
-- =========================================================


-- 1. Baseline: audit trail before the demo
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration,
       LEFT(COALESCE(errors, ''), 50) AS errors
FROM job_log
WHERE job_name IN ('demo_refresh_weather_hourly',
                   'refresh_weather_hourly')
ORDER BY start_time DESC
LIMIT 5;


-- 2. Introduce dirty data -- one row with a corrupt timestamp
INSERT INTO staging.weather_raw (
    airport_code, time,
    temperature_2m, relative_humidity_2m,
    precipitation, snowfall, windspeed_10m,
    cloud_cover, weathercode
) VALUES (
    'ATL', 'CORRUPT_TIMESTAMP',
    '10', '50',
    '0', '0', '5',
    '20', '0'
);

-- Confirm bad row is in staging
SELECT airport_code, time, temperature_2m
FROM staging.weather_raw
WHERE time = 'CORRUPT_TIMESTAMP';


-- 3. Run the demo procedure -- expect an ERROR AND a FAILED
--    row in job_log. The CAST(time AS TIMESTAMP) will fail
--    on the corrupt row; the procedure's EXCEPTION handler
--    captures the error and writes a FAILED row via the
--    audited-failure pattern (independent of the work tx).
CALL demo_refresh_weather_hourly();
-- Expected: ERROR: invalid input syntax for type timestamp: "CORRUPT_TIMESTAMP"
-- Expected: HINT: See job_log table for the FAILED row.


-- 4. Now look at the audit trail -- a FAILED row appears
--    with the error message captured. The work, however,
--    was rolled back: weather_hourly is unchanged.
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration,
       LEFT(errors, 80) AS errors
FROM job_log
WHERE job_name = 'demo_refresh_weather_hourly'
ORDER BY start_time DESC
LIMIT 3;

SELECT COUNT(*) AS weather_rows FROM weather_hourly;
-- Expected: still 263,040 (unchanged from before the demo)


-- 5. Fix the bad row
DELETE FROM staging.weather_raw
WHERE time = 'CORRUPT_TIMESTAMP';


-- 6. Re-run -- this time the procedure succeeds
CALL demo_refresh_weather_hourly();


-- 7. Audit trail now shows FAILED then OK side by side
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration,
       LEFT(COALESCE(errors, ''), 50) AS errors
FROM job_log
WHERE job_name = 'demo_refresh_weather_hourly'
ORDER BY start_time DESC
LIMIT 4;


-- =========================================================
-- Cleanup if the demo was interrupted between steps 2 and 5
-- and a corrupt row is still in staging:
--
--   DELETE FROM staging.weather_raw
--   WHERE time = 'CORRUPT_TIMESTAMP';
-- =========================================================
