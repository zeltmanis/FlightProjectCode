-- =========================================================
-- 002_proc_refresh_airports.sql
--
-- Cleans staging.airports_raw → airports.
--
-- What this procedure does:
--   1. Logs a 'RUNNING' row in job_log
--   2. TRUNCATEs the airports table (idempotent — every run
--      gives a deterministic snapshot)
--   3. INSERTs filtered + cast + normalised rows from staging
--   4. Updates the job_log row to 'OK' with the row count
--   5. On exception, updates the job_log row to 'FAILED'
--
-- Filters / decisions:
--   - iso_country = 'US'                  (project scope)
--   - type IN (large_airport, medium_airport)  (BTS won't reference smaller types)
--   - iata_code IS NOT NULL               (no IATA = useless for joining flights)
--
-- Normalisations:
--   - iata_code uppercased
--   - state extracted from iso_region: 'US-CA' → 'CA'
--   - latitude/longitude cast to DECIMAL (TEXT in staging)
--
-- Usage:
--   CALL refresh_airports();
--   SELECT * FROM job_log WHERE job_name = 'refresh_airports' ORDER BY start_time DESC;
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_airports()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    -- 1. Open a job_log row in 'RUNNING' state.
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_airports', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    -- 2. Upsert from staging — INSERT new rows, UPDATE existing ones.
    --    Using ON CONFLICT instead of TRUNCATE+INSERT so we don't run
    --    into the FK constraint from flights/routes when re-running.
    --    Static dim table; we don't need to delete anything.
    INSERT INTO airports (
        airport_code, icao_code, name, city, state, latitude, longitude
    )
    SELECT
        UPPER(iata_code)                          AS airport_code,
        NULLIF(icao_code, '')                     AS icao_code,
        name,
        municipality                              AS city,
        SPLIT_PART(iso_region, '-', 2)            AS state,
        CAST(latitude_deg  AS DECIMAL)            AS latitude,
        CAST(longitude_deg AS DECIMAL)            AS longitude
    FROM staging.airports_raw
    WHERE iata_code IS NOT NULL
      AND iata_code <> ''
      AND iso_country = 'US'
      AND type IN ('large_airport', 'medium_airport')
    ON CONFLICT (airport_code) DO UPDATE SET
        icao_code = EXCLUDED.icao_code,
        name      = EXCLUDED.name,
        city      = EXCLUDED.city,
        state     = EXCLUDED.state,
        latitude  = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- 4. Mark the job as OK with the row count.
    UPDATE job_log
       SET end_time       = NOW(),
           status         = 'OK',
           rows_processed = v_rows
     WHERE job_id = v_job_id;

EXCEPTION WHEN OTHERS THEN
    -- 5. Mark the job as FAILED, store the error message.
    UPDATE job_log
       SET end_time = NOW(),
           status   = 'FAILED',
           errors   = SQLERRM
     WHERE job_id = v_job_id;
    RAISE;  -- re-raise so the caller sees the error
END;
$$;

COMMENT ON PROCEDURE refresh_airports() IS
    'Cleans staging.airports_raw into airports; logs to job_log.';
