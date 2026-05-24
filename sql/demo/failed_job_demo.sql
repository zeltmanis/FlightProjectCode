-- =========================================================
-- failed_job_demo.sql -- the resilience story
--
-- Run this **line by line** in DataGrip during the demo.
-- Do NOT execute as a batch -- the point is the audience
-- sees each step and its result.
--
-- The narrative: when a refresh procedure encounters dirty
-- data, the WHOLE transaction rolls back. Nothing partial
-- ever lands in the cleaned tables. The cleanup operator
-- sees the Postgres ERROR with a clear message pointing
-- at the bad data, fixes it, and re-runs.
--
-- Storyboard (~60 seconds of demo time):
--   1. Show the audit trail before anything bad happens
--   2. Introduce dirty data: one staging row with a corrupt
--      date (simulating real-world ETL: upstream fat-fingered
--      a date)
--   3. Run refresh_flights() -- the DATE cast fails. The
--      Postgres error message points at the bad data
--   4. Prove nothing downstream was corrupted -- the TRUNCATE
--      in the procedure rolled back; flights is unchanged.
--      job_log shows the LAST OK entry is from BEFORE the
--      demo (the failed call left no trace because of clean
--      transactional rollback -- this is correct behaviour)
--   5. Fix the bad row
--   6. Re-run refresh_flights() -- now succeeds
--   7. job_log gets a fresh OK row with real wall-clock
--      duration. The pipeline is back to healthy
-- =========================================================


-- 1. Baseline: what does the audit trail look like right now?
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
ORDER BY start_time DESC
LIMIT 5;


-- 2. Introduce dirty data -- one flight with a corrupt date.
--    Real-world ETL hits this all the time: an upstream
--    extract truncates a date or fat-fingers a value, and
--    our cleaning procedure has to deal with it.
INSERT INTO staging.flights_raw (
    flight_date, reporting_airline, origin, dest,
    crs_dep_time, dep_time, dep_delay_minutes,
    crs_arr_time, arr_time, arr_delay_minutes,
    cancelled, cancellation_code,
    weather_delay, nas_delay
) VALUES (
    'CORRUPT_DATE', 'AA', 'ATL', 'LAX',
    '0800', '0805.0', '5.0',
    '1100', '1105.0', '5.0',
    '0.0', '',
    '', ''
);

-- Confirm the bad row landed.
SELECT flight_date, reporting_airline, origin, dest
FROM staging.flights_raw
WHERE flight_date = 'CORRUPT_DATE';


-- 3. Run refresh_flights() -- the f.flight_date::DATE cast
--    in the procedure will fail when it hits this row.
--    The error message in DataGrip's output IS the failure
--    signal -- it points directly at the bad data.
CALL refresh_flights();
-- Expected: ERROR: invalid input syntax for type date: "CORRUPT_DATE"


-- 4. Prove nothing was corrupted downstream. The procedure
--    did TRUNCATE flights, flights_enriched, predictions
--    FIRST and then failed during INSERT -- but the WHOLE
--    call is one transaction, so the TRUNCATE rolled back
--    too. flights still has every row it had before, and
--    job_log doesn't have a new entry because the audit
--    INSERT rolled back with the rest of the transaction.
--    This is *correct* transactional behaviour: failures
--    leave no partial state, anywhere.
SELECT COUNT(*) AS flights_count FROM flights;
-- Expected: still 1,402,592 (unchanged from before the demo)

SELECT job_name, status,
       end_time - start_time AS duration
FROM job_log
WHERE job_name = 'refresh_flights'
ORDER BY start_time DESC LIMIT 2;
-- Expected: the same OK rows as in step 1 -- no FAILED row
-- because the failed call's audit INSERT rolled back too.


-- 5. Fix the bad row.
DELETE FROM staging.flights_raw
WHERE flight_date = 'CORRUPT_DATE';


-- 6. Re-run. This time the procedure succeeds.
CALL refresh_flights();


-- 7. Audit trail shows a fresh OK row with real wall-clock
--    duration. The pipeline is back to healthy.
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
WHERE job_name = 'refresh_flights'
ORDER BY start_time DESC LIMIT 3;


-- =========================================================
-- Cleanup (run only if the demo was interrupted between
-- steps 2 and 5 and a corrupt row is still in staging):
--
--   DELETE FROM staging.flights_raw
--   WHERE flight_date NOT SIMILAR TO '[0-9]{4}-[0-9]{2}-[0-9]{2}';
-- =========================================================
