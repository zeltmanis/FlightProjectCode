-- =========================================================
-- 012_schema_flights_enriched.sql
--
-- Denormalised: one row per flight, with weather at origin
-- and destination joined inline, plus derived time-of-day
-- features. Algorithms read this table directly — no joins
-- needed at query time.
--
-- Source: flights × weather_hourly (twice, via DATE_TRUNC).
-- Populated by refresh_flights_enriched().
-- =========================================================

CREATE TABLE IF NOT EXISTS flights_enriched (
    flight_enriched_id    BIGSERIAL PRIMARY KEY,
    flight_id             BIGINT NOT NULL UNIQUE REFERENCES flights(flight_id) ON DELETE CASCADE,

    -- Weather at origin at scheduled departure hour
    dep_temperature       DECIMAL,
    dep_precipitation     DECIMAL,
    dep_snow              DECIMAL,
    dep_wind              DECIMAL,
    dep_humidity          DECIMAL,
    dep_cloud_cover       DECIMAL,
    dep_fog_risk          BOOLEAN,
    dep_severe_weather    BOOLEAN,

    -- Weather at destination at scheduled arrival hour
    arr_temperature       DECIMAL,
    arr_precipitation     DECIMAL,
    arr_snow              DECIMAL,
    arr_wind              DECIMAL,
    arr_humidity          DECIMAL,
    arr_cloud_cover       DECIMAL,
    arr_fog_risk          BOOLEAN,
    arr_severe_weather    BOOLEAN,

    -- Time-based features for algorithm B
    hour_of_day           SMALLINT  CHECK (hour_of_day BETWEEN 0 AND 23),
    day_of_week           SMALLINT  CHECK (day_of_week BETWEEN 1 AND 7),
    month                 SMALLINT  CHECK (month       BETWEEN 1 AND 12),
    season                VARCHAR   CHECK (season IN ('winter','spring','summer','autumn')),

    -- Single categorical label summarising departure weather. The
    -- fourth grouping key of the prediction model. Tiers are layered
    -- so the most specific match wins; see refresh_flights_enriched()
    -- for the exact CASE expression.
    dep_weather_bucket    VARCHAR(20)
                          CHECK (dep_weather_bucket IS NULL
                                 OR dep_weather_bucket IN
                                     ('clear','light_rain','heavy_rain',
                                      'snow','fog','thunderstorm'))
);

CREATE INDEX IF NOT EXISTS idx_flights_enriched_flight_id ON flights_enriched (flight_id);

COMMENT ON TABLE flights_enriched IS
    'One row per flight, weather + time features inlined; the table algorithms train on';
COMMENT ON COLUMN flights_enriched.dep_fog_risk IS
    'humidity > 90% AND temperature in [-2, 5]°C — typical aviation fog conditions';
COMMENT ON COLUMN flights_enriched.dep_severe_weather IS
    'precipitation >= 4mm OR snowfall >= 1cm OR wind >= 40 km/h';
COMMENT ON COLUMN flights_enriched.dep_weather_bucket IS
    'Categorical bucket: thunderstorm | snow | heavy_rain | light_rain | fog | clear. NULL when weather not joined.';
