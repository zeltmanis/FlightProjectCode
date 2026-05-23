-- =========================================================
-- 021_func_predict_for_airport.sql
--
-- The headline demo. Returns one row per scheduled departure
-- from p_airport on p_date, ranked by predicted late-likelihood
-- (high → low) then by predicted minutes delayed.
--
-- This is a FUNCTION (not a PROCEDURE) so we can SELECT from
-- it in the demo:
--
--   SELECT * FROM predict_for_airport('LAX', DATE '2024-07-15');
--
-- Returns:
--   flight_id, route ("ATL→LAX"), dep_time (HH:MM),
--   late_likelihood (low/average/high or NULL),
--   late_pct (raw P(late) for transparency),
--   magnitude (short/average/long/extreme/cancelled or NULL),
--   exp_delay (median minutes), sample_size,
--   explanation (always populated)
--
-- Marked STABLE because it reads from tables but doesn't
-- modify state.
-- =========================================================

CREATE OR REPLACE FUNCTION predict_for_airport(
    p_airport CHAR(3),
    p_date    DATE
)
RETURNS TABLE (
    flight_id        BIGINT,
    route            TEXT,
    dep_time         TEXT,
    late_likelihood  VARCHAR(10),
    late_pct         DECIMAL,
    magnitude        VARCHAR(15),
    exp_delay        DECIMAL,
    sample_size      INTEGER,
    explanation      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        p.flight_id,
        f.origin_airport_code || '→' || f.dest_airport_code  AS route,
        to_char(f.scheduled_departure, 'HH24:MI')             AS dep_time,
        p.late_likelihood,
        p.late_pct,
        p.magnitude,
        p.exp_delay,
        p.sample_size,
        p.explanation
    FROM predictions p
    JOIN flights     f USING (flight_id)
    WHERE f.origin_airport_code = UPPER(p_airport)
      AND f.flight_date         = p_date
    ORDER BY
        -- High-likelihood flights first; predictions with no data last
        CASE p.late_likelihood
            WHEN 'high'    THEN 1
            WHEN 'average' THEN 2
            WHEN 'low'     THEN 3
            ELSE                4   -- NULL — no data
        END,
        p.exp_delay DESC NULLS LAST,
        f.scheduled_departure;
$$;

COMMENT ON FUNCTION predict_for_airport(CHAR, DATE) IS
    'Demo entrypoint: ranked predictions for one (airport, date). SELECT-able.';
