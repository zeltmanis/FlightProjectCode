-- =========================================================
-- 000_schema_job_log.sql
--
-- System table that records every batch job execution
-- (cleaning, enrichment, prediction, etc.). Every other
-- procedure in this project writes one row here when it
-- starts and updates it when it finishes or fails.
--
-- Run order: this is first — every other procedure depends
-- on this table existing.
-- =========================================================

CREATE TABLE IF NOT EXISTS job_log (
    job_id          BIGSERIAL PRIMARY KEY,
    job_name        VARCHAR NOT NULL,
    start_time      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    end_time        TIMESTAMPTZ,
    rows_processed  INTEGER,
    status          VARCHAR NOT NULL DEFAULT 'RUNNING'
                    CHECK (status IN ('RUNNING', 'OK', 'FAILED')),
    errors          TEXT
);

CREATE INDEX IF NOT EXISTS idx_job_log_name_start
    ON job_log (job_name, start_time DESC);

COMMENT ON TABLE job_log IS
    'One row per batch job execution; written by every refresh_*() procedure.';
