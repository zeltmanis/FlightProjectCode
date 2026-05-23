-- =========================================================
-- 019_schema_validation_results.sql
--
-- One row per (run_id, metric_name). Populated by
-- validate_predictions(). Each call to validate_predictions
-- inserts a new run_id and multiple metric rows under it.
--
-- This is a long-format table — easier to add new metrics
-- without schema changes. Query with WHERE run_id = (latest)
-- for the current snapshot.
-- =========================================================

CREATE TABLE IF NOT EXISTS validation_results (
    validation_id  BIGSERIAL PRIMARY KEY,
    run_id         BIGINT NOT NULL,                       -- groups one validation pass
    metric_name    VARCHAR(60) NOT NULL,
    metric_value   DECIMAL,
    population     INTEGER,                                -- # predictions in this metric
    notes          TEXT,                                   -- optional context for the metric
    computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (run_id, metric_name)
);

CREATE INDEX IF NOT EXISTS idx_validation_results_run
    ON validation_results (run_id);

COMMENT ON TABLE  validation_results IS
    'Long-format validation metrics; one row per (run, metric). Populated by validate_predictions().';
COMMENT ON COLUMN validation_results.run_id IS
    'Monotonic per call. Latest run_id = SELECT MAX(run_id) FROM validation_results.';
