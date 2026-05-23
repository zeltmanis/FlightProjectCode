-- =========================================================
-- 020_proc_validate_predictions.sql
--
-- Compares predictions to actual 2024 outcomes (which are
-- recorded in flights as arr_delay_minutes / cancelled).
-- One CALL inserts a batch of metric rows into
-- validation_results, all sharing a fresh run_id.
--
-- Metrics computed (all over predictions that actually have a
-- prediction — i.e. late_likelihood IS NOT NULL):
--
--   mae                    — mean absolute error of exp_delay vs actual
--   median_abs_error       — robust alternative
--   mae_when_low           — MAE restricted to late_likelihood='low'
--   mae_when_average       — ... 'average'
--   mae_when_high          — ... 'high'
--   accuracy_within_15min  — share of |error| ≤ 15
--   accuracy_within_30min  — share of |error| ≤ 30
--   accuracy_within_60min  — share of |error| ≤ 60
--   precision_high         — P(actually late | predicted 'high')
--   precision_low          — P(actually on-time | predicted 'low')
--   bucket_match_rate      — share of predictions whose modal
--                             magnitude bucket = actual magnitude
--
-- "Actual late" = arr_delay_minutes > 15 (OTP-15 rule).
-- Cancelled flights are excluded from the magnitude-error
-- metrics (no arr_delay to compare against).
--
-- Usage:
--   CALL validate_predictions();
--   SELECT * FROM validation_results
--    WHERE run_id = (SELECT MAX(run_id) FROM validation_results)
--    ORDER BY metric_name;
-- =========================================================

CREATE OR REPLACE PROCEDURE validate_predictions()
LANGUAGE plpgsql AS $$
DECLARE
    v_job_id  BIGINT;
    v_run_id  BIGINT;
    v_inserted INTEGER;
BEGIN
    INSERT INTO job_log (job_name, status)
    VALUES ('validate_predictions', 'RUNNING')
    RETURNING job_id INTO v_job_id;

    -- Allocate a fresh run_id (monotonic).
    SELECT COALESCE(MAX(run_id), 0) + 1 INTO v_run_id FROM validation_results;

    -- All metrics evaluated against this base set: 2024 flights
    -- with a non-NULL prediction AND a known actual outcome.
    WITH evaluable AS (
        SELECT
            p.exp_delay,
            p.late_likelihood,
            p.late_pct,
            p.magnitude,
            f.arr_delay_minutes  AS actual_delay,
            f.cancelled          AS actual_cancelled,
            (f.arr_delay_minutes > 15) AS actual_late,
            CASE
                WHEN f.cancelled THEN 'cancelled'
                WHEN f.arr_delay_minutes <= 30  THEN 'short'
                WHEN f.arr_delay_minutes <= 180 THEN 'average'
                WHEN f.arr_delay_minutes <= 480 THEN 'long'
                ELSE                                  'extreme'
            END AS actual_magnitude
        FROM predictions p
        JOIN flights f USING (flight_id)
        WHERE p.late_likelihood IS NOT NULL
    )
    INSERT INTO validation_results (run_id, metric_name, metric_value, population, notes)
    SELECT v_run_id, metric_name, metric_value, population, notes
    FROM (
        SELECT 'mae'::VARCHAR(60) AS metric_name,
               AVG(ABS(exp_delay - actual_delay)) AS metric_value,
               COUNT(*) AS population,
               'mean abs error, all predictions, non-cancelled'::TEXT AS notes
        FROM evaluable WHERE NOT actual_cancelled

        UNION ALL SELECT 'median_abs_error',
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(exp_delay - actual_delay)),
               COUNT(*),
               'median abs error, non-cancelled'
        FROM evaluable WHERE NOT actual_cancelled

        UNION ALL SELECT 'mae_when_low',
               AVG(ABS(exp_delay - actual_delay)), COUNT(*),
               'MAE within predictions labelled low'
        FROM evaluable WHERE late_likelihood = 'low' AND NOT actual_cancelled

        UNION ALL SELECT 'mae_when_average',
               AVG(ABS(exp_delay - actual_delay)), COUNT(*),
               'MAE within predictions labelled average'
        FROM evaluable WHERE late_likelihood = 'average' AND NOT actual_cancelled

        UNION ALL SELECT 'mae_when_high',
               AVG(ABS(exp_delay - actual_delay)), COUNT(*),
               'MAE within predictions labelled high'
        FROM evaluable WHERE late_likelihood = 'high' AND NOT actual_cancelled

        UNION ALL SELECT 'accuracy_within_15min',
               AVG(CASE WHEN ABS(exp_delay - actual_delay) <= 15 THEN 1 ELSE 0 END),
               COUNT(*),
               'share of predictions within ±15 min'
        FROM evaluable WHERE NOT actual_cancelled

        UNION ALL SELECT 'accuracy_within_30min',
               AVG(CASE WHEN ABS(exp_delay - actual_delay) <= 30 THEN 1 ELSE 0 END),
               COUNT(*),
               'share of predictions within ±30 min'
        FROM evaluable WHERE NOT actual_cancelled

        UNION ALL SELECT 'accuracy_within_60min',
               AVG(CASE WHEN ABS(exp_delay - actual_delay) <= 60 THEN 1 ELSE 0 END),
               COUNT(*),
               'share of predictions within ±60 min'
        FROM evaluable WHERE NOT actual_cancelled

        UNION ALL SELECT 'precision_high',
               AVG(CASE WHEN actual_late THEN 1 ELSE 0 END),
               COUNT(*),
               'P(actually late | predicted high)'
        FROM evaluable WHERE late_likelihood = 'high'

        UNION ALL SELECT 'precision_low',
               AVG(CASE WHEN NOT actual_late THEN 1 ELSE 0 END),
               COUNT(*),
               'P(actually on-time | predicted low)'
        FROM evaluable WHERE late_likelihood = 'low'

        UNION ALL SELECT 'bucket_match_rate',
               AVG(CASE WHEN magnitude = actual_magnitude THEN 1 ELSE 0 END),
               COUNT(*),
               'share where predicted magnitude bucket matches actual'
        FROM evaluable
    ) metrics;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    UPDATE job_log
       SET end_time       = NOW(),
           status         = 'OK',
           rows_processed = v_inserted
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

COMMENT ON PROCEDURE validate_predictions() IS
    'Compares predictions to actual 2024 outcomes; writes metric rows to validation_results; logs to job_log.';
