-- =========================================================
-- failed_job_demo.sql -- the resilience story (quick version)
--
-- Demonstrates clean transactional rollback using
-- refresh_weather_hourly(), which is fast (~3 sec) and has
-- no downstream FK dependencies. The whole demo runs in
-- ~10 seconds total -- perfect for live presentation.
--
-- The pattern is **identical for every refresh_* procedure**
-- in the project. We use refresh_weather_hourly() because:
--   - it's fast (no audience downtime)
--   - it doesn't cascade-truncate anything, so the demo
--     leaves the prediction layer untouched
--
-- Run line by line in DataGrip. Do NOT execute as a batch
-- -- the point is the audience sees each step + its result.
--
-- Storyboard (~10 sec of demo):
--   1. Show the audit trail before anything bad happens
--   2. Introduce dirty data -- one staging row with a corrupt
--      timestamp (simulating real-world ETL: upstream
--      fat-fingered a value)
--   3. Run refresh_weather_hourly() -- the TIMESTAMP cast
--      fails. The Postgres error message points at the bad
--      data
--   4. Prove nothing was corrupted -- weather_hourly is
--      unchanged; the failed call left no trace in job_log
--      (clean transactional rollback)
--   5. Fix the bad row
--   6. Re-run -- now succeeds; fresh OK row in job_log
-- =========================================================


-- 1. Baseline: what does the audit trail look like right now?
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
ORDER BY start_time DESC
LIMIT 5;


-- 2. Introduce dirty data -- one row with a corrupt timestamp.
--    Real-world ETL hits this all the time: an upstream
--    extract truncates a value or hits an encoding bug.
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

-- Confirm the bad row landed in staging.
SELECT airport_code, time, temperature_2m
FROM staging.weather_raw
WHERE time = 'CORRUPT_TIMESTAMP';


-- 3. Run the cleaning procedure -- the CAST(time AS TIMESTAMP)
--    will fail when it hits this row.
CALL refresh_weather_hourly();
-- Expected: ERROR: invalid input syntax for type timestamp: "CORRUPT_TIMESTAMP"


-- 4. Prove nothing was corrupted downstream. The procedure
--    did TRUNCATE weather_hourly FIRST and then failed
--    during INSERT -- but the WHOLE call is one transaction,
--    so the TRUNCATE rolled back too. weather_hourly still
--    has every row it had before, AND job_log has no new
--    entry because the audit INSERT rolled back with the
--    rest of the transaction. This is *correct*
--    transactional behaviour: failures leave no partial
--    state, anywhere.
SELECT COUNT(*) AS weather_rows FROM weather_hourly;
-- Expected: 263,040 (unchanged from before the demo)

SELECT job_name, status,
       end_time - start_time AS duration
FROM job_log
WHERE job_name = 'refresh_weather_hourly'
ORDER BY start_time DESC LIMIT 2;
-- Expected: the same OK rows as in step 1 -- no FAILED row
-- because the failed call's audit INSERT rolled back too.


-- 5. Fix the bad row.
DELETE FROM staging.weather_raw
WHERE time = 'CORRUPT_TIMESTAMP';


-- 6. Re-run. This time the procedure succeeds in ~3 seconds.
CALL refresh_weather_hourly();


-- 7. Audit trail shows a fresh OK row with real wall-clock
--    duration. The pipeline is back to healthy.
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
WHERE job_name = 'refresh_weather_hourly'
ORDER BY start_time DESC LIMIT 3;


-- =========================================================
-- Cleanup (run only if the demo was interrupted between
-- steps 2 and 5 and a corrupt row is still in staging):
--
--   DELETE FROM staging.weather_raw WHERE time = 'CORRUPT_TIMESTAMP';
-- =========================================================
