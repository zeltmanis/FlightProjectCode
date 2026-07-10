# Speaker guide — Batch jobs  (~2–3 min)

**Slides 4–6:** Why jobs? → Batch jobs → Resilience.

## The one-sentence point
> Raw data arrives as messy text; **batch jobs** clean it, give it real types, and load it into tables — **repeatably**, and with a full **audit trail**, so we can rebuild the whole database with one command and see exactly what happened.

## What to say (the story)
- The CSV loads as **14 TEXT columns** — a date is `'2022-01-06'` text, a time is `'512.0'` (a *float* as text!), a boolean is `'0.0'`. Text can't be validated, sorted, or math'd. That's the problem.
- So each step is a **stored procedure** — a "batch job." It reads the raw text, **validates + types** it (DATE, BOOLEAN, CHAR(3) with a foreign key…), and writes clean rows.
- Every job follows the **same 5-step shape**: log *"started"* → do the work → log *"OK"* — or, if anything breaks, log *"FAILED"* and **undo everything** (rollback).
- `run_pipeline()` runs all nine jobs **in dependency order** with one call. Every run is recorded in `job_log` — rows processed, duration, errors.
- Why this matters: **repeatable** (rebuild from raw anytime), **auditable** (nothing is hidden), **safe** (a failure never leaves half-written data).

## Live demo A — run the pipeline, show the audit log
```sql
-- one command runs all nine steps in the right order
CALL run_pipeline();

-- the audit trail: every job, its rows, its duration
SELECT job_name, status, rows_processed, end_time - start_time AS duration
FROM job_log ORDER BY start_time DESC;
```
**Point at:** each step `OK` with real row counts (weather 263k, flights 1.4M, predictions 484k) and the total (~4 min). *"One call, nine jobs, all logged."*

> Tip: `run_pipeline()` takes ~4 min. For a live talk, either run it **before** the presentation and just `SELECT` the log, or run the small individual ones (`refresh_airports`, `refresh_airlines`) live and show the log.

## Live demo B — Resilience: a job that fails (the money demo)
This shows failures are **caught, logged, and rolled back** — not hidden.
```sql
-- 1. baseline: the demo job currently succeeds
SELECT job_name, status, rows_processed, end_time - start_time AS duration, errors
FROM job_log WHERE job_name = 'demo_refresh_weather_hourly'
ORDER BY start_time DESC LIMIT 3;

-- 2. inject one corrupt row (a bad timestamp) into staging
INSERT INTO staging.weather_raw
  (airport_code, time, temperature_2m, relative_humidity_2m,
   precipitation, snowfall, windspeed_10m, cloud_cover, weathercode)
VALUES ('ATL', 'CORRUPT_TIMESTAMP', '10','50','0','0','5','20','0');

-- 3. run the job → it ERRORS on the bad cast
CALL demo_refresh_weather_hourly();     -- expect: ERROR invalid input syntax for type timestamp

-- 4. but look — the failure is RECORDED, and the table is untouched
SELECT job_name, status, rows_processed, LEFT(errors,80) AS errors
FROM job_log WHERE job_name = 'demo_refresh_weather_hourly'
ORDER BY start_time DESC LIMIT 2;       -- top row: FAILED, rows = NULL

-- 5. fix the bad data
DELETE FROM staging.weather_raw WHERE time = 'CORRUPT_TIMESTAMP';

-- 6. re-run → succeeds
CALL demo_refresh_weather_hourly();

-- 7. audit shows BOTH, side by side: the FAILED attempt and the OK recovery
SELECT job_name, status, rows_processed, end_time - start_time AS duration,
       LEFT(COALESCE(errors,''),50) AS errors
FROM job_log WHERE job_name = 'demo_refresh_weather_hourly'
ORDER BY start_time DESC LIMIT 4;
```
**Say at step 4:** *"The cast failed ~10 ms in. The job caught the error, wrote a FAILED row to the log, and rolled back its work — `weather_hourly` is still exactly 263,040 rows. Failures are data, not silence."*
**Say at step 7:** *"FAILED then OK, both in the audit trail. That's the whole point — you can always see what happened."*

**Console review:** your 7-step flow is solid — keep it. Only tips: run **step 1 first** so the audience sees a clean baseline; and if you've run the demo before, the FAILED row from last time may already be there (harmless, just note it).

## If they ask
- *Why does the audit row survive the rollback?* → the FAILED-log write is done in a separate step outside the work transaction, so it persists even though the work is undone.
- *Idempotent?* → yes: each refresh `TRUNCATE`s and rebuilds its table, so re-running never duplicates.
