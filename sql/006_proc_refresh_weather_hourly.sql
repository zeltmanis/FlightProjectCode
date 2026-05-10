-- =========================================================
-- 006_proc_refresh_weather_hourly.sql
--
-- Cleans staging.weather_raw → weather_hourly.
--
-- Casts every TEXT column to its target type. Time strings
-- like '2023-01-02T00:00' are interpreted as UTC and stored
-- as TIMESTAMPTZ.
--
-- Filters:
--   - airport_code is non-empty
--   - time is non-empty
--
-- Usage:
--   CALL refresh_weather_hourly();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_weather_hourly()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_weather_hourly', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    TRUNCATE weather_hourly;

    INSERT INTO weather_hourly (
        airport_code, obs_timestamp,
        temperature_c, relative_humidity, precipitation_mm,
        snowfall_cm, wind_speed_kmh, cloud_cover_pct, weather_code
    )
    SELECT
        UPPER(airport_code)                                              AS airport_code,
        (CAST(time AS TIMESTAMP) AT TIME ZONE 'UTC')                     AS obs_timestamp,
        NULLIF(temperature_2m,       '')::DECIMAL                        AS temperature_c,
        NULLIF(relative_humidity_2m, '')::DECIMAL                        AS relative_humidity,
        NULLIF(precipitation,        '')::DECIMAL                        AS precipitation_mm,
        NULLIF(snowfall,             '')::DECIMAL                        AS snowfall_cm,
        NULLIF(windspeed_10m,        '')::DECIMAL                        AS wind_speed_kmh,
        NULLIF(cloud_cover,          '')::DECIMAL                        AS cloud_cover_pct,
        NULLIF(weathercode,          '')::SMALLINT                       AS weather_code
    FROM staging.weather_raw
    WHERE airport_code IS NOT NULL
      AND airport_code <> ''
      AND time         IS NOT NULL
      AND time         <> '';

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

COMMENT ON PROCEDURE refresh_weather_hourly() IS
    'Cleans staging.weather_raw into weather_hourly; logs to job_log.';
