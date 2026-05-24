-- =========================================================
-- 004_proc_refresh_airlines.sql
--
-- Cleans staging.flights_raw → airlines.
--
-- Source: distinct values of "Reporting_Airline" from BTS.
-- Names: small in-procedure lookup for the major US carriers
-- (anything not in the lookup gets NULL — easy to fill later).
--
-- Usage:
--   CALL refresh_airlines();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_airlines()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_airlines', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    -- Upsert from staging — flights references airlines via FK, so
    -- TRUNCATE would fail. INSERT ... ON CONFLICT updates existing
    -- rows and adds new ones without wiping the table.
    -- staging.flights_raw uses snake_case columns since the 2026-05-23
    -- scale-up (pre-cleaned 3-year CSVs from the Algorithms project).
    INSERT INTO airlines (airline_code, name)
    SELECT DISTINCT
        UPPER(reporting_airline) AS airline_code,
        CASE UPPER(reporting_airline)
            WHEN 'AA' THEN 'American Airlines'
            WHEN 'DL' THEN 'Delta Air Lines'
            WHEN 'UA' THEN 'United Airlines'
            WHEN 'WN' THEN 'Southwest Airlines'
            WHEN 'AS' THEN 'Alaska Airlines'
            WHEN 'B6' THEN 'JetBlue Airways'
            WHEN 'F9' THEN 'Frontier Airlines'
            WHEN 'NK' THEN 'Spirit Airlines'
            WHEN 'HA' THEN 'Hawaiian Airlines'
            WHEN 'G4' THEN 'Allegiant Air'
            WHEN '9E' THEN 'Endeavor Air'
            WHEN 'OO' THEN 'SkyWest Airlines'
            WHEN 'YX' THEN 'Republic Airways'
            WHEN 'MQ' THEN 'Envoy Air'
            WHEN 'OH' THEN 'PSA Airlines'
            WHEN 'YV' THEN 'Mesa Airlines'
            WHEN 'QX' THEN 'Horizon Air'
            WHEN 'ZW' THEN 'Air Wisconsin'
            ELSE NULL
        END AS name
    FROM staging.flights_raw
    WHERE reporting_airline IS NOT NULL
      AND reporting_airline <> ''
    ON CONFLICT (airline_code) DO UPDATE SET
        name = EXCLUDED.name;

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

COMMENT ON PROCEDURE refresh_airlines() IS
    'Cleans distinct airlines from staging.flights_raw into airlines; logs to job_log.';
