-- =========================================================
-- 022_func_evaluate_for_airport.sql
--
-- Sibling of predict_for_airport(). Same shape, but adds the
-- ACTUAL outcome columns and a verdict per flight. Use this
-- to demo "how well did the model do?" without writing JOINs.
--
-- Usage:
--   SELECT * FROM evaluate_for_airport('LAX', DATE '2024-07-15');
--
-- Returns one row per scheduled departure from p_airport on
-- p_date, with:
--
--   route, dep_time             -- identifying the flight
--   predicted_likelihood,       -- our late_likelihood label
--   pred_min                    -- predicted delay (minutes)
--   actual_min                  -- actual delay (minutes; NULL if cancelled)
--   was_late_actually           -- TRUE if actual > 15 (FAA OTP-15)
--   error_min                   -- |pred - actual| (NULL when not comparable)
--   verdict                     -- one of:
--                                   'within 15 min' (best)
--                                   'within 30 min'
--                                   'within 60 min'
--                                   'off by more'
--                                   'cancelled'      (flight never flew)
--                                   'no prediction'  (bucket had <10 history)
--
-- Sorted by predicted likelihood (high → low) then by error,
-- so failures bubble to the top of the displayed table.
-- =========================================================

CREATE OR REPLACE FUNCTION evaluate_for_airport(
    p_airport CHAR(3),
    p_date    DATE
)
RETURNS TABLE (
    flight_id              BIGINT,
    route                  TEXT,
    dep_time               TEXT,
    predicted_likelihood   VARCHAR(10),
    pred_min               INTEGER,
    actual_min             INTEGER,
    was_late_actually      BOOLEAN,
    error_min              INTEGER,
    verdict                TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        p.flight_id,
        f.origin_airport_code || '→' || f.dest_airport_code  AS route,
        to_char(f.scheduled_departure, 'HH24:MI')             AS dep_time,
        p.late_likelihood                                     AS predicted_likelihood,
        ROUND(p.exp_delay)::int                               AS pred_min,
        ROUND(f.arr_delay_minutes)::int                       AS actual_min,
        (f.arr_delay_minutes > 15)                            AS was_late_actually,
        CASE
            WHEN p.exp_delay         IS NULL THEN NULL
            WHEN f.arr_delay_minutes IS NULL THEN NULL
            ELSE ROUND(ABS(p.exp_delay - f.arr_delay_minutes))::int
        END                                                   AS error_min,
        CASE
            WHEN p.late_likelihood IS NULL          THEN 'no prediction'
            WHEN f.cancelled                        THEN 'cancelled'
            WHEN f.arr_delay_minutes IS NULL        THEN 'no actual data'
            WHEN ABS(p.exp_delay - f.arr_delay_minutes) <= 15 THEN 'within 15 min'
            WHEN ABS(p.exp_delay - f.arr_delay_minutes) <= 30 THEN 'within 30 min'
            WHEN ABS(p.exp_delay - f.arr_delay_minutes) <= 60 THEN 'within 60 min'
            ELSE 'off by more'
        END                                                   AS verdict
    FROM predictions p
    JOIN flights     f USING (flight_id)
    WHERE f.origin_airport_code = UPPER(p_airport)
      AND f.flight_date         = p_date
    ORDER BY
        -- High-likelihood predictions first (they're the operationally
        -- interesting ones), then by absolute error so misses surface
        CASE p.late_likelihood
            WHEN 'high'    THEN 1
            WHEN 'average' THEN 2
            WHEN 'low'     THEN 3
            ELSE                4
        END,
        p.exp_delay DESC NULLS LAST,
        f.scheduled_departure;
$$;

COMMENT ON FUNCTION evaluate_for_airport(CHAR, DATE) IS
    'Same shape as predict_for_airport, plus actuals + per-flight verdict. Use for demo of model accuracy.';
