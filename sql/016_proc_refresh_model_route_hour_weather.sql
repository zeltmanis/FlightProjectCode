-- =========================================================
-- 016_proc_refresh_model_route_hour_weather.sql
--
-- Trains the prediction model. For every observed
-- (origin, dest, hour_of_day, weather_bucket) combination
-- in 2022-2023 with at least 10 flights, compute 11
-- aggregates and store them as one row.
--
-- All 11 aggregates come from ONE GROUP BY using Postgres's
-- COUNT(*) FILTER (WHERE ...) and PERCENTILE_CONT — no
-- extensions, no Python, no opaque model artefacts.
--
-- Magnitude bucket cutoffs (locked in §2 of REPORT.md):
--   short:    arr_delay <= 30
--   average:  30 < arr_delay <= 180
--   long:     180 < arr_delay <= 480
--   extreme:  arr_delay > 480
--   cancelled: separate state (its own pct_cancelled column)
--
-- Discipline: we never look at f.arr_delay or f.cancelled for
-- 2024 flights — only 2022-2023. That keeps the model honest
-- when predict_flights() runs against 2024.
--
-- Usage:
--   CALL refresh_model_route_hour_weather();
-- =========================================================

CREATE OR REPLACE PROCEDURE refresh_model_route_hour_weather()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('refresh_model_route_hour_weather', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    TRUNCATE model_route_hour_weather;

    INSERT INTO model_route_hour_weather (
        origin, dest, hour_of_day, weather_bucket,
        avg_delay, median_delay, delay_p90,
        pct_late, pct_cancelled,
        pct_short, pct_average, pct_long, pct_extreme,
        sample_size
    )
    SELECT
        f.origin_airport_code,
        f.dest_airport_code,
        fe.hour_of_day,
        fe.dep_weather_bucket,

        -- Magnitude
        AVG(f.arr_delay_minutes),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.arr_delay_minutes),
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.arr_delay_minutes),

        -- Likelihood
        COUNT(*) FILTER (WHERE f.arr_delay_minutes > 15)::DECIMAL / COUNT(*),
        COUNT(*) FILTER (WHERE f.cancelled)::DECIMAL / COUNT(*),

        -- Magnitude distribution (non-cancelled flights only —
        -- cancelled is its own state in pct_cancelled).
        COUNT(*) FILTER (WHERE NOT f.cancelled
                         AND f.arr_delay_minutes <= 30)::DECIMAL / COUNT(*),
        COUNT(*) FILTER (WHERE NOT f.cancelled
                         AND f.arr_delay_minutes >  30
                         AND f.arr_delay_minutes <= 180)::DECIMAL / COUNT(*),
        COUNT(*) FILTER (WHERE NOT f.cancelled
                         AND f.arr_delay_minutes >  180
                         AND f.arr_delay_minutes <= 480)::DECIMAL / COUNT(*),
        COUNT(*) FILTER (WHERE NOT f.cancelled
                         AND f.arr_delay_minutes >  480)::DECIMAL / COUNT(*),

        COUNT(*) AS sample_size

    FROM flights_enriched fe
    INNER JOIN flights f USING (flight_id)
    WHERE EXTRACT(YEAR FROM f.flight_date) IN (2022, 2023)
      AND fe.dep_weather_bucket IS NOT NULL
      AND fe.hour_of_day        IS NOT NULL
    GROUP BY 1, 2, 3, 4
    HAVING COUNT(*) >= 10;

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

COMMENT ON PROCEDURE refresh_model_route_hour_weather() IS
    'Trains the prediction model from flights_enriched 2022-2023; logs to job_log.';
