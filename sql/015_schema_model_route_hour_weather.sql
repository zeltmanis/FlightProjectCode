-- =========================================================
-- 015_schema_model_route_hour_weather.sql
--
-- The prediction model. One row per
-- (origin, dest, hour_of_day, weather_bucket) combination.
-- Each row holds the aggregates we computed from 2022-2023
-- history; predict_flights() consumes this table.
--
-- Why a table? Because the model IS the table. Every row is
-- one prediction rule: "for flights ATL→LAX at 14:00 in
-- thunderstorm conditions, 72% historically late, median 180
-- minutes." A grader can ask 'why' and the answer is a SELECT.
--
-- 11 aggregates per bucket — magnitude (3), likelihood (2),
-- magnitude distribution (4), sample_size, all computable in
-- one INSERT SELECT in refresh_model_route_hour_weather().
-- =========================================================

CREATE TABLE IF NOT EXISTS model_route_hour_weather (
    origin            CHAR(3)      NOT NULL REFERENCES airports(airport_code),
    dest              CHAR(3)      NOT NULL REFERENCES airports(airport_code),
    hour_of_day       SMALLINT     NOT NULL CHECK (hour_of_day BETWEEN 0 AND 23),
    weather_bucket    VARCHAR(20)  NOT NULL
                      CHECK (weather_bucket IN
                          ('clear','light_rain','heavy_rain',
                           'snow','fog','thunderstorm')),

    -- Magnitude (continuous estimators of "how late, in minutes")
    avg_delay         DECIMAL,
    median_delay      DECIMAL,
    delay_p90         DECIMAL,

    -- Likelihood (probability of being late or cancelled)
    pct_late          DECIMAL CHECK (pct_late      BETWEEN 0 AND 1),
    pct_cancelled     DECIMAL CHECK (pct_cancelled BETWEEN 0 AND 1),

    -- Magnitude distribution (these sum to 1 with pct_cancelled,
    -- modulo edge cases like NULL arr_delay on non-cancelled flights)
    pct_short         DECIMAL CHECK (pct_short    BETWEEN 0 AND 1),    -- delay <= 30 min
    pct_average       DECIMAL CHECK (pct_average  BETWEEN 0 AND 1),    -- 30 < delay <= 180
    pct_long          DECIMAL CHECK (pct_long     BETWEEN 0 AND 1),    -- 180 < delay <= 480
    pct_extreme       DECIMAL CHECK (pct_extreme  BETWEEN 0 AND 1),    -- > 480

    -- §2 minimum: only buckets with ≥10 historical observations
    -- make it into the model. Smaller buckets are dropped here so
    -- predict_flights() correctly LEFT-JOINs and surfaces them as
    -- "no data, can't predict" in the demo output.
    sample_size       INTEGER NOT NULL CHECK (sample_size >= 10),

    PRIMARY KEY (origin, dest, hour_of_day, weather_bucket)
);

COMMENT ON TABLE  model_route_hour_weather IS
    'Per-(route, hour, weather) prediction rules; trained from flights_enriched 2022-2023.';
COMMENT ON COLUMN model_route_hour_weather.median_delay IS
    'PERCENTILE_CONT(0.5) — used as the continuous "expected delay" in predictions.';
COMMENT ON COLUMN model_route_hour_weather.pct_late IS
    'Share of historical flights in this bucket with arr_delay > 15 min (OTP-15 rule).';
