-- =========================================================
-- 017_schema_predictions.sql
--
-- Per-flight predictions for the 2024 holdout. Populated by
-- predict_flights() — one row per 2024 flight, the result of
-- joining flights_enriched against the trained model.
--
-- LEFT JOIN behaviour:
--   When a flight's (origin, dest, hour, weather_bucket) bucket
--   doesn't exist in the model (because 2022-2023 had fewer
--   than 10 historical flights in that bucket), all
--   model-derived columns are NULL. The `explanation` column
--   still describes WHY there's no prediction.
--
-- We never write predictions for 2022 or 2023 flights — those
-- are training data, not predictions.
-- =========================================================

CREATE TABLE IF NOT EXISTS predictions (
    prediction_id     BIGSERIAL PRIMARY KEY,
    flight_id         BIGINT NOT NULL UNIQUE
                      REFERENCES flights(flight_id) ON DELETE CASCADE,

    -- Continuous: median historical delay from the matching bucket.
    -- NULL when there's no matching model row.
    exp_delay         DECIMAL,

    -- Categorical: late-likelihood bucket. NULL when no model row.
    late_likelihood   VARCHAR(10)
                      CHECK (late_likelihood IS NULL
                             OR late_likelihood IN ('low','average','high')),
    -- Raw P(late) for transparency.
    late_pct          DECIMAL CHECK (late_pct IS NULL OR late_pct BETWEEN 0 AND 1),

    -- Categorical: most-likely magnitude bucket. NULL when no model row.
    magnitude         VARCHAR(15)
                      CHECK (magnitude IS NULL
                             OR magnitude IN ('short','average','long',
                                              'extreme','cancelled')),

    -- Honest sample-size disclosure. NULL when no model row matched.
    sample_size       INTEGER,

    -- Human-readable explanation traceable back to the model row.
    -- Always populated, even when the prediction itself is NULL.
    explanation       TEXT NOT NULL,

    predicted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_predictions_likelihood
    ON predictions (late_likelihood)
    WHERE late_likelihood IS NOT NULL;

COMMENT ON TABLE  predictions IS
    '2024 per-flight delay predictions; output of predict_flights().';
COMMENT ON COLUMN predictions.exp_delay IS
    'Median historical delay (minutes) from the matching model bucket.';
COMMENT ON COLUMN predictions.late_likelihood IS
    'low (<20% historical late rate) / average (20-50%) / high (>=50%)';
COMMENT ON COLUMN predictions.magnitude IS
    'Modal magnitude bucket for the matching model row; ties resolved toward less-severe.';
COMMENT ON COLUMN predictions.explanation IS
    'Always populated. Either traces the model lookup or explains why we cannot predict.';
