-- =========================================================
-- 009_proc_refresh_flights.sql
--
-- Cleans staging.flights_raw → flights. The biggest
-- cleaning procedure in the project.
--
-- What it does:
--   - Casts 14 columns from TEXT to proper types
--   - Builds 4 TIMESTAMPTZs from BTS date + HHMM via
--     hhmm_to_ts(); these are the columns that join to
--     weather_hourly
--   - Drops rows whose origin/dest/airline aren't in our
--     dimension tables (filter, not FK violation)
--   - Normalises empty strings to NULL throughout
--   - Translates '0.0' / '1.0' booleans to BOOLEAN
--   - Derives dep_del15 / arr_del15 from delay minutes
--     (BTS originally carried these as columns; cleaned
--     CSVs dropped them, so we apply the OTP-15 rule:
--     delay > 15 minutes)
--
-- Columns NOT in the cleaned source (set NULL):
--   - distance_miles, carrier_delay, security_delay,
--     late_aircraft_delay — these were pruned during
--     the algorithms-project cleaning step
--
-- Edge-case decisions baked in:
--   - DepTime/ArrTime empty for cancelled flights
--     → actual_departure / actual_arrival = NULL
--   - CancellationCode '' for non-cancelled flights
--     → cancellation_code = NULL
--
-- Note: this runs over ~1.4M rows for the full 3-year
-- top-10 scale-up. The TRUNCATE+INSERT is in a single
-- transaction, so a failure rolls back cleanly.
--
-- Usage:
--   CALL refresh_flights();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_flights()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_flights', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    -- flights_enriched FKs to flights, so we must truncate both together.
    -- The user should re-run refresh_flights_enriched() after this.
    TRUNCATE flights, flights_enriched RESTART IDENTITY;

    INSERT INTO flights (
        flight_date, airline_code,
        origin_airport_code, dest_airport_code,
        scheduled_departure, actual_departure,
        scheduled_arrival,   actual_arrival,
        scheduled_dep_time,  actual_dep_time,
        scheduled_arr_time,  actual_arr_time,
        dep_delay_minutes, dep_del15,
        arr_delay_minutes, arr_del15,
        cancelled, cancellation_code, distance_miles,
        carrier_delay, weather_delay, nas_delay, security_delay, late_aircraft_delay
    )
    SELECT
        f.flight_date::DATE                                 AS flight_date,
        UPPER(f.reporting_airline)                          AS airline_code,
        UPPER(f.origin)                                     AS origin_airport_code,
        UPPER(f.dest)                                       AS dest_airport_code,

        -- 4 TIMESTAMPTZs from flight_date + HHMM. hhmm_to_ts() handles
        -- the unpadded form ("800" → "0800") and the float-text form
        -- ("757.0" → strips ".0", LPADs to 4 digits).
        hhmm_to_ts(f.flight_date, f.crs_dep_time)           AS scheduled_departure,
        hhmm_to_ts(f.flight_date, f.dep_time)               AS actual_departure,
        hhmm_to_ts(f.flight_date, f.crs_arr_time)           AS scheduled_arrival,
        hhmm_to_ts(f.flight_date, f.arr_time)               AS actual_arrival,

        -- Raw HHMM as SMALLINT (kept for BTS fidelity). SPLIT_PART
        -- drops the ".0" if present.
        NULLIF(SPLIT_PART(f.crs_dep_time, '.', 1), '')::SMALLINT  AS scheduled_dep_time,
        NULLIF(SPLIT_PART(f.dep_time,     '.', 1), '')::SMALLINT  AS actual_dep_time,
        NULLIF(SPLIT_PART(f.crs_arr_time, '.', 1), '')::SMALLINT  AS scheduled_arr_time,
        NULLIF(SPLIT_PART(f.arr_time,     '.', 1), '')::SMALLINT  AS actual_arr_time,

        NULLIF(f.dep_delay_minutes, '')::DECIMAL            AS dep_delay_minutes,
        -- Derived: OTP-15 rule. NULL when there's no delay value at all
        -- (e.g. cancelled flight with no DepDelayMinutes).
        CASE
            WHEN NULLIF(f.dep_delay_minutes, '') IS NULL THEN NULL
            ELSE f.dep_delay_minutes::DECIMAL > 15
        END                                                 AS dep_del15,

        NULLIF(f.arr_delay_minutes, '')::DECIMAL            AS arr_delay_minutes,
        CASE
            WHEN NULLIF(f.arr_delay_minutes, '') IS NULL THEN NULL
            ELSE f.arr_delay_minutes::DECIMAL > 15
        END                                                 AS arr_del15,

        -- Cleaned CSVs use "1.0" / "0.0" (not "1.00" / "0.00") because they
        -- went through pandas' default float formatting.
        CASE NULLIF(f.cancelled, '')
             WHEN '1.0' THEN TRUE
             WHEN '0.0' THEN FALSE
             ELSE FALSE END                                 AS cancelled,
        NULLIF(f.cancellation_code, '')::CHAR(1)            AS cancellation_code,
        NULL::DECIMAL                                       AS distance_miles,        -- not in cleaned source

        NULL::DECIMAL                                       AS carrier_delay,         -- not in cleaned source
        NULLIF(f.weather_delay, '')::DECIMAL                AS weather_delay,
        NULLIF(f.nas_delay,     '')::DECIMAL                AS nas_delay,
        NULL::DECIMAL                                       AS security_delay,        -- not in cleaned source
        NULL::DECIMAL                                       AS late_aircraft_delay    -- not in cleaned source
    FROM staging.flights_raw f
    INNER JOIN airports a_origin ON a_origin.airport_code = UPPER(f.origin)
    INNER JOIN airports a_dest   ON a_dest.airport_code   = UPPER(f.dest)
    INNER JOIN airlines al       ON al.airline_code       = UPPER(f.reporting_airline)
    WHERE f.flight_date IS NOT NULL
      AND f.flight_date <> '';

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE job_log
       SET end_time       = NOW(),
           status         = 'OK',
           rows_processed = v_rows
     WHERE job_id = v_job_id;

EXCEPTION WHEN OTHERS THEN
    UPDATE job_log
       SET end_time = NOW(),
           status   = 'FAILED',
           errors   = SQLERRM
     WHERE job_id = v_job_id;
    RAISE;
END;
$$;

COMMENT ON PROCEDURE refresh_flights() IS
    'Cleans staging.flights_raw into flights with FK filtering and HHMM→TIMESTAMPTZ; logs to job_log.';
