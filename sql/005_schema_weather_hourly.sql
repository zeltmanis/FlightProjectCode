-- =========================================================
-- 005_schema_weather_hourly.sql
--
-- Cleaned hourly weather observations, one row per
-- (airport, hour). Populated by refresh_weather_hourly()
-- from staging.weather_raw.
--
-- Time handling: Open-Meteo Archive returns timestamps in
-- the form '2023-01-02T00:00' (we requested timezone=UTC).
-- We cast through TIMESTAMP AT TIME ZONE 'UTC' so the
-- TIMESTAMPTZ column stores the right absolute time.
-- =========================================================

CREATE TABLE IF NOT EXISTS weather_hourly (
    weather_id          BIGSERIAL    PRIMARY KEY,
    airport_code        CHAR(3)      NOT NULL,
    obs_timestamp       TIMESTAMPTZ  NOT NULL,
    temperature_c       DECIMAL,
    relative_humidity   DECIMAL      CHECK (relative_humidity BETWEEN 0 AND 100),
    precipitation_mm    DECIMAL      CHECK (precipitation_mm  >= 0),
    snowfall_cm         DECIMAL      CHECK (snowfall_cm       >= 0),
    wind_speed_kmh      DECIMAL      CHECK (wind_speed_kmh    >= 0),
    cloud_cover_pct     DECIMAL      CHECK (cloud_cover_pct BETWEEN 0 AND 100),
    weather_code        SMALLINT,

    -- One observation per (airport, hour). Also creates an index for joins.
    UNIQUE (airport_code, obs_timestamp)
);

COMMENT ON TABLE  weather_hourly                    IS 'Cleaned hourly weather (origin: Open-Meteo Archive)';
COMMENT ON COLUMN weather_hourly.obs_timestamp      IS 'UTC, hour-aligned';
COMMENT ON COLUMN weather_hourly.snowfall_cm        IS 'Open-Meteo reports snowfall in cm; not converted';
