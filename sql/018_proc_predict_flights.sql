-- =========================================================
-- 018_proc_predict_flights.sql
--
-- The prediction step. For every 2024 flight, look up the
-- matching model bucket and emit a row with:
--   - exp_delay      (median minutes from the bucket)
--   - late_likelihood (low/average/high — derived from pct_late)
--   - late_pct       (raw P(late) from the bucket)
--   - magnitude      (modal magnitude bucket)
--   - sample_size    (so the demo can show confidence)
--   - explanation    (always populated; describes the lookup
--                     or why a prediction is missing)
--
-- LEFT JOIN against the model so flights with no matching
-- bucket still get a row (with NULL predictions, NULL labels,
-- and an explanation like "no historical analogue").
--
-- No look-ahead: we read fe.dep_weather_bucket, fe.hour_of_day,
-- f.origin_airport_code, f.dest_airport_code, f.scheduled_*.
-- We never read f.arr_delay_minutes or f.cancelled — those are
-- the outcomes we're predicting.
--
-- Magnitude tie-breaking: the CASE clauses are ordered from
-- least-severe (short) to most-severe (cancelled). When two
-- buckets tie on the highest pct_*, the less-severe bucket
-- wins — we don't cry wolf.
--
-- Usage:
--   CALL predict_flights();
-- =========================================================

CREATE OR REPLACE PROCEDURE predict_flights()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_rows    INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('predict_flights', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    TRUNCATE predictions RESTART IDENTITY;

    INSERT INTO predictions (
        flight_id,
        exp_delay,
        late_likelihood, late_pct,
        magnitude,
        sample_size,
        explanation
    )
    SELECT
        f.flight_id,

        m.median_delay AS exp_delay,

        -- Late-likelihood bucket
        CASE
            WHEN m.pct_late IS NULL THEN NULL
            WHEN m.pct_late <  0.20 THEN 'low'
            WHEN m.pct_late <  0.50 THEN 'average'
            ELSE                         'high'
        END                                            AS late_likelihood,

        m.pct_late                                     AS late_pct,

        -- Magnitude bucket — modal, ties resolved less-severe.
        -- CASE GREATEST(...) WHEN x THEN literal: matches the
        -- first arm whose pct_* equals the max.
        CASE GREATEST(m.pct_short,    m.pct_average,
                      m.pct_long,     m.pct_extreme,
                      m.pct_cancelled)
            WHEN NULL              THEN NULL
            WHEN m.pct_short       THEN 'short'
            WHEN m.pct_average     THEN 'average'
            WHEN m.pct_long        THEN 'long'
            WHEN m.pct_extreme     THEN 'extreme'
            WHEN m.pct_cancelled   THEN 'cancelled'
        END                                            AS magnitude,

        m.sample_size,

        -- Explanation: always populated, three paths.
        CASE
            WHEN fe.dep_weather_bucket IS NULL THEN
                'weather forecast unavailable for ' || f.origin_airport_code
                || ' at ' || to_char(f.scheduled_departure, 'YYYY-MM-DD HH24:00')
            WHEN m.sample_size IS NULL THEN
                'no historical analogue: ' || f.origin_airport_code
                || '→' || f.dest_airport_code
                || ', hour=' || fe.hour_of_day::text
                || ', weather=' || fe.dep_weather_bucket
                || ' (need n>=10 in 2022-2023)'
            ELSE
                f.origin_airport_code || '→' || f.dest_airport_code
                || ', hour=' || fe.hour_of_day::text
                || ', weather=' || fe.dep_weather_bucket
                || ': ' || ROUND(m.pct_late * 100)::text || '% late historically, '
                || 'median ' || ROUND(m.median_delay)::text || 'm '
                || '(n=' || m.sample_size::text || ')'
        END                                            AS explanation

    FROM flights_enriched fe
    INNER JOIN flights f USING (flight_id)
    LEFT JOIN model_route_hour_weather m
        ON  m.origin         = f.origin_airport_code
        AND m.dest           = f.dest_airport_code
        AND m.hour_of_day    = fe.hour_of_day
        AND m.weather_bucket = fe.dep_weather_bucket
    WHERE EXTRACT(YEAR FROM f.flight_date) = 2024;

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

COMMENT ON PROCEDURE predict_flights() IS
    'Predicts 2024 flights from model_route_hour_weather; logs to job_log.';
