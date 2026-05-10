-- =========================================================
-- 013_proc_refresh_flights_enriched.sql
--
-- The big join. For each flight, look up:
--   1. Weather at origin airport at the scheduled departure hour
--   2. Weather at destination airport at the scheduled arrival hour
-- Plus derive a few time-bucket features for the algorithms.
--
-- Run order: must be AFTER refresh_flights AND
-- refresh_weather_hourly. Otherwise either side of the join
-- is empty.
--
-- LEFT JOIN strategy:
--   We use LEFT JOIN so flights without a weather match (most
--   flights for now — only 5 hubs × 7 days are covered) still
--   land in flights_enriched with NULL weather columns. When
--   the team scales weather to top-50 × full year, the match
--   rate climbs without changing this code.
--
-- Derived features:
--   - fog_risk:        humidity > 90 AND temperature in [-2, 5]°C
--   - severe_weather:  precipitation ≥ 4mm OR snowfall ≥ 1cm OR wind ≥ 40 km/h
--   - hour_of_day:     EXTRACT(HOUR FROM scheduled_departure)  (0–23)
--   - day_of_week:     EXTRACT(ISODOW)  (1=Mon, 7=Sun)
--   - month:           1–12
--   - season:          winter / spring / summer / autumn
--
-- Usage:
--   CALL refresh_flights_enriched();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_flights_enriched()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_flights_enriched', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    TRUNCATE flights_enriched RESTART IDENTITY;

    INSERT INTO flights_enriched (
        flight_id,
        dep_temperature, dep_precipitation, dep_snow, dep_wind,
        dep_humidity, dep_cloud_cover, dep_fog_risk, dep_severe_weather,
        arr_temperature, arr_precipitation, arr_snow, arr_wind,
        arr_humidity, arr_cloud_cover, arr_fog_risk, arr_severe_weather,
        hour_of_day, day_of_week, month, season
    )
    SELECT
        f.flight_id,

        -- Weather at origin
        w_dep.temperature_c       AS dep_temperature,
        w_dep.precipitation_mm    AS dep_precipitation,
        w_dep.snowfall_cm         AS dep_snow,
        w_dep.wind_speed_kmh      AS dep_wind,
        w_dep.relative_humidity   AS dep_humidity,
        w_dep.cloud_cover_pct     AS dep_cloud_cover,
        CASE WHEN w_dep.relative_humidity > 90
             AND  w_dep.temperature_c BETWEEN -2 AND 5
             THEN TRUE
             WHEN w_dep.airport_code IS NULL THEN NULL
             ELSE FALSE END                                AS dep_fog_risk,
        CASE WHEN w_dep.precipitation_mm >= 4
              OR  w_dep.snowfall_cm      >= 1
              OR  w_dep.wind_speed_kmh   >= 40
             THEN TRUE
             WHEN w_dep.airport_code IS NULL THEN NULL
             ELSE FALSE END                                AS dep_severe_weather,

        -- Weather at destination
        w_arr.temperature_c       AS arr_temperature,
        w_arr.precipitation_mm    AS arr_precipitation,
        w_arr.snowfall_cm         AS arr_snow,
        w_arr.wind_speed_kmh      AS arr_wind,
        w_arr.relative_humidity   AS arr_humidity,
        w_arr.cloud_cover_pct     AS arr_cloud_cover,
        CASE WHEN w_arr.relative_humidity > 90
             AND  w_arr.temperature_c BETWEEN -2 AND 5
             THEN TRUE
             WHEN w_arr.airport_code IS NULL THEN NULL
             ELSE FALSE END                                AS arr_fog_risk,
        CASE WHEN w_arr.precipitation_mm >= 4
              OR  w_arr.snowfall_cm      >= 1
              OR  w_arr.wind_speed_kmh   >= 40
             THEN TRUE
             WHEN w_arr.airport_code IS NULL THEN NULL
             ELSE FALSE END                                AS arr_severe_weather,

        -- Time-bucket features (NULL-safe via COALESCE on flight_date)
        EXTRACT(HOUR   FROM f.scheduled_departure)::SMALLINT AS hour_of_day,
        EXTRACT(ISODOW FROM f.scheduled_departure)::SMALLINT AS day_of_week,
        EXTRACT(MONTH  FROM f.scheduled_departure)::SMALLINT AS month,
        CASE EXTRACT(MONTH FROM f.scheduled_departure)::INT
             WHEN 12 THEN 'winter' WHEN 1  THEN 'winter' WHEN 2  THEN 'winter'
             WHEN 3  THEN 'spring' WHEN 4  THEN 'spring' WHEN 5  THEN 'spring'
             WHEN 6  THEN 'summer' WHEN 7  THEN 'summer' WHEN 8  THEN 'summer'
             WHEN 9  THEN 'autumn' WHEN 10 THEN 'autumn' WHEN 11 THEN 'autumn'
        END                                              AS season

    FROM flights f
    LEFT JOIN weather_hourly w_dep
           ON w_dep.airport_code = f.origin_airport_code
          AND w_dep.obs_timestamp = DATE_TRUNC('hour', f.scheduled_departure)
    LEFT JOIN weather_hourly w_arr
           ON w_arr.airport_code = f.dest_airport_code
          AND w_arr.obs_timestamp = DATE_TRUNC('hour', f.scheduled_arrival)
    WHERE f.scheduled_departure IS NOT NULL;

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

COMMENT ON PROCEDURE refresh_flights_enriched() IS
    'Joins flights with weather_hourly (twice: dep + arr), denormalised; logs to job_log.';
