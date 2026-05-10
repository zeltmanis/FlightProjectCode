-- =========================================================
-- 009_proc_refresh_flights.sql
--
-- Cleans staging.flights_raw → flights. The biggest
-- cleaning procedure in the project.
--
-- What it does:
--   - Casts ~25 columns from TEXT to proper types
--   - Builds 4 TIMESTAMPTZs from BTS date + HHMM via
--     hhmm_to_ts(); these are the columns that join to
--     weather_hourly
--   - Drops rows whose origin/dest/airline aren't in our
--     dimension tables (filter, not FK violation)
--   - Normalises empty strings to NULL throughout
--   - Translates '0.00' / '1.00' BTS booleans to BOOLEAN
--
-- Edge-case decisions baked in:
--   - DepTime/ArrTime empty for cancelled flights
--     → actual_departure / actual_arrival = NULL
--   - CancellationCode '' for non-cancelled flights
--     → cancellation_code = NULL
--   - Delay reason fields NULL when there is no delay
--     → carried as NULL (not 0)
--
-- Note: this runs over ~540k rows for one month, so the
-- procedure can take ~30s. The TRUNCATE+INSERT is in a
-- single transaction, so a failure rolls back cleanly.
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
        f."FlightDate"::DATE                                AS flight_date,
        UPPER(f."Reporting_Airline")                        AS airline_code,
        UPPER(f."Origin")                                   AS origin_airport_code,
        UPPER(f."Dest")                                     AS dest_airport_code,

        hhmm_to_ts(f."FlightDate", f."CRSDepTime")          AS scheduled_departure,
        hhmm_to_ts(f."FlightDate", f."DepTime")             AS actual_departure,
        hhmm_to_ts(f."FlightDate", f."CRSArrTime")          AS scheduled_arrival,
        hhmm_to_ts(f."FlightDate", f."ArrTime")             AS actual_arrival,

        NULLIF(SPLIT_PART(f."CRSDepTime", '.', 1), '')::SMALLINT  AS scheduled_dep_time,
        NULLIF(SPLIT_PART(f."DepTime",    '.', 1), '')::SMALLINT  AS actual_dep_time,
        NULLIF(SPLIT_PART(f."CRSArrTime", '.', 1), '')::SMALLINT  AS scheduled_arr_time,
        NULLIF(SPLIT_PART(f."ArrTime",    '.', 1), '')::SMALLINT  AS actual_arr_time,

        NULLIF(f."DepDelayMinutes", '')::DECIMAL            AS dep_delay_minutes,
        CASE NULLIF(f."DepDel15", '')
             WHEN '1.00' THEN TRUE
             WHEN '0.00' THEN FALSE
             ELSE NULL END                                  AS dep_del15,

        NULLIF(f."ArrDelayMinutes", '')::DECIMAL            AS arr_delay_minutes,
        CASE NULLIF(f."ArrDel15", '')
             WHEN '1.00' THEN TRUE
             WHEN '0.00' THEN FALSE
             ELSE NULL END                                  AS arr_del15,

        CASE NULLIF(f."Cancelled", '')
             WHEN '1.00' THEN TRUE
             WHEN '0.00' THEN FALSE
             ELSE FALSE END                                 AS cancelled,
        NULLIF(f."CancellationCode", '')::CHAR(1)           AS cancellation_code,
        NULLIF(f."Distance", '')::DECIMAL                   AS distance_miles,

        NULLIF(f."CarrierDelay",      '')::DECIMAL          AS carrier_delay,
        NULLIF(f."WeatherDelay",      '')::DECIMAL          AS weather_delay,
        NULLIF(f."NASDelay",          '')::DECIMAL          AS nas_delay,
        NULLIF(f."SecurityDelay",     '')::DECIMAL          AS security_delay,
        NULLIF(f."LateAircraftDelay", '')::DECIMAL          AS late_aircraft_delay
    FROM staging.flights_raw f
    INNER JOIN airports a_origin ON a_origin.airport_code = UPPER(f."Origin")
    INNER JOIN airports a_dest   ON a_dest.airport_code   = UPPER(f."Dest")
    INNER JOIN airlines al       ON al.airline_code       = UPPER(f."Reporting_Airline")
    WHERE f."FlightDate" IS NOT NULL
      AND f."FlightDate" <> '';

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
