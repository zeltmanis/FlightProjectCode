# Next steps & current status

> This file is the **portable handoff note** — read it after `git pull`
> on a fresh machine to know exactly where the project is and what's
> next. Pairs with `REPORT.md` (design) and `README.md` (operations).
> Last updated: 2026-05-27.

---

## Current state (one paragraph)

End-to-end prediction pipeline is **live and tested** on 1,402,592
flights × 3 years × top-10 US airports, with 263,040 hourly weather
observations. Model trained from 2022–2023 in ~13 seconds; predicts
the 483,897 flights of 2024 holdout in ~20 seconds; validates against
actuals in ~6 seconds. Headline accuracy: **MAE 16.9 minutes, 78%
within ±15 min, 84% magnitude-bucket match**. Demo entrypoints
`predict_for_airport()` and `evaluate_for_airport()` work; resilience
demo via `demo_refresh_weather_hourly()` shows visible FAILED rows in
`job_log`. Doc artefacts (README, REPORT, presentation.html) are up
to date with live numbers. Latest commit on `main`: `cf721b2`.

---

## Pending capstone deliverables

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | **pgTAP test suite** | ⏸️ blocked / pending | User does NOT have root on Uganda PG and cannot `CREATE EXTENSION pgtap` (requires superuser). User to ask the teacher: (a) install server-side, (b) drop from scope, or (c) test against a local Mac PG instance. **Backup plan if dropped: Python + pytest + psycopg2 suite covering schema shape, procedure post-conditions, and prediction-math correctness.** |
| 2 | **Slide 11 (pgTAP)** | ⏸️ TODO | Depends on item 1's resolution. |
| 3 | **Dress rehearsal** | ⏳ not started | Open `presentation.html` in a browser, walk slide-by-slide, time each section. |
| 4 | **Convex-hull bookend** | 🎁 stretch | Cross-project reuse from the Algorithms capstone — a US map with high-delay airports clustered into convex hulls, overlaid on weather-affected regions. ~1 min demo bookend. See sibling project at `/Users/private/Desktop/UNIVERSITY/02_Semester/Algorithms and data/Capstone/`. |

Everything else (cleaning, enrichment, model, predictions, validation,
resilience demo, REPORT, README, slides 1–10) is shipped.

---

## Open decisions

None blocking. Two items the user has set aside:
- **Carrier as a 5th grouping key** for the model — discussed, deferred.
- **Top 10 → top 50 airports scale-up** — discussed, deferred. Pipeline
  code is unchanged; only `config.py` + load-script filters would need
  to grow.

---

## How to resume on any machine

1. `cd FlightProjectCode && git pull origin main`
2. VPN to the Uganda PG server (`192.168.203.7`).
3. `.env` is gitignored — make sure your local copy has `PGUSER` /
   `PGPASSWORD` filled in.
4. Quick sanity check in DataGrip or via the included helpers:
   ```sql
   -- Pipeline summary
   SELECT job_name, status, rows_processed,
          end_time - start_time AS duration
   FROM job_log
   ORDER BY start_time DESC LIMIT 10;

   -- Latest validation metrics
   SELECT metric_name, ROUND(metric_value, 3), population, notes
   FROM validation_results
   WHERE run_id = (SELECT MAX(run_id) FROM validation_results)
   ORDER BY metric_name;

   -- Live demo of the model
   SELECT * FROM predict_for_airport('LAX', DATE '2024-07-15') LIMIT 10;
   ```

If table counts look wrong (e.g. `flights_enriched` is 0), someone
ran `refresh_flights()` and it cascade-truncated downstream. Recovery
is `CALL run_pipeline();` or call the individual procedures in
dependency order (see `REPORT.md §10.5`).

---

## Recent commit highlights

```
cf721b2  Update docs for the audited-failure demo pattern
2c03f98  Add demo_refresh_weather_hourly() — persists FAILED rows in job_log
6810f5f  Switch failed-job demo to refresh_weather_hourly (10s vs 3-4min)
215f63e  Add evaluate_for_airport() function: predictions vs actuals
5dc2c25  Rewrite README for the post-prediction state
d3305b7  Add failed-job demo + fix refresh_flights TRUNCATE for predictions FK
92b12f7  Use clock_timestamp() so job_log durations are real
34a9ba4  Drop thunderstorm from weather_bucket; add live numbers to docs
f72a198  Add prediction layer: model, predictions, validation, demo
1611397  Refactor weather pipeline for 10-airport × 3-year scale-up
```

Full history with `git log --oneline`.
