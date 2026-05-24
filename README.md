# Flight Project — end-to-end delay prediction in PostgreSQL

End-to-end PostgreSQL pipeline for the **Databases & Project Management**
course project: ingest US flight data + weather, clean it, enrich it,
**train a delay-prediction model in SQL, predict 2024 outcomes from
2022-2023 history, and validate against actual delays**.

> **Status (2026-05-24): live end-to-end on 1.4M flights × 10 top US
> airports × 3 years of weather.** The whole pipeline reruns in
> ~99 seconds. The model achieves MAE 16.9 min and 78% accuracy
> within ±15 min on the 2024 holdout. See `REPORT.md` for the design
> writeup and the full validation table.

> See also **`REPORT.md`** for the educational write-up (sections,
> rationale, references) and **`presentation.html`** for the slide
> deck (open in a browser).

---

## Architecture in one picture

We use an **ELT** pattern (Extract + Load with Python, Transform with SQL).
Python is thin glue; PostgreSQL does the real work.

```
[ Python — this repo ]                    [ PostgreSQL — Uganda DB server ]
─────────────────────                      ─────────────────────────────────

  load_bts_clean.py   ──COPY──>  staging.flights_raw       ┐
  fetch_weather.py    ──COPY──>  staging.weather_raw       │  raw, all TEXT
  fetch_airports.py   ──COPY──>  staging.airports_raw      ┘
                                            │
                                            │  refresh_*()
                                            ▼
                                  airports / airlines / weather_hourly / flights
                                            │
                                            │  refresh_routes()
                                            │  refresh_flights_enriched()
                                            ▼
                                  routes  +  flights_enriched
                                            │
                                            │  refresh_model_route_hour_weather()
                                            ▼
                                  model_route_hour_weather  (THE MODEL)
                                            │
                                            │  predict_flights()
                                            ▼
                                  predictions ──▶ validate_predictions() ──▶ validation_results
                                            │
                                            │  predict_for_airport(airport, date)
                                            ▼
                                  ranked predictions per (airport, date)
```

Everything from "raw" downward is SQL. Stored procedures, foreign keys,
CHECK constraints, joins, DATE_TRUNC, CASE expressions, UPSERTs, audit
triggers — all in the database, all version-controlled in `sql/`.

---

## Data sources

Three independent feeds. All free, all public.

| Source | What it gives us | Volume | Refresh |
|---|---|---|---|
| **BTS On-Time Performance** | Every domestic US flight: scheduled & actual times, delays, cancellations, carrier, origin, dest | ~1.2 GB of pre-cleaned CSVs (14 cols) for 3 years from the Algorithms-project sibling | Annual |
| **OurAirports** | Reference dimension: IATA + ICAO codes, name, city, lat/lon, type | One CSV, filtered to ~180 KB | Effectively static |
| **Open-Meteo Archive** | Hourly historical weather: temp, humidity, precipitation, snow, wind, cloud cover | ~5 KB per airport per week | Daily lag for recent days; otherwise stable |

---

## The database — 5 layers, 13 tables

### 1. Staging tables — raw text, exactly as ingested (3 tables)

These mirror the CSVs verbatim. Every column is `TEXT`. Cleaning,
casting, and validation happen *afterwards* via the procedures below.

| Table | Source | Current rows |
|---|---|---:|
| `staging.flights_raw` | Pre-cleaned BTS CSVs (2022-2024 × top 10 airports) | 1,402,592 |
| `staging.weather_raw` | Open-Meteo Archive (10 airports × 3 years, hourly) | 263,040 |
| `staging.airports_raw` | OurAirports CSV | 872 (US large + medium with IATA) |

### 2. Cleaned tables — typed, validated, reference-integrity (5 tables)

| Table | Description | Current rows |
|---|---|---:|
| `airports` | Dimension: 872 US airports, code → name/city/state/lat/lon. | 872 |
| `airlines` | Dimension: carriers that appear in BTS. | 17 |
| `weather_hourly` | One row per (airport, hour). UTC timestamps, typed values. UNIQUE on (airport_code, obs_timestamp). | 263,040 |
| `flights` | One row per scheduled flight. ~25 typed columns including `TIMESTAMPTZ` columns built from BTS date+HHMM. | 1,402,592 |
| `routes` | Distinct (origin, dest) pairs. Derived from flights. | ~90 |

### 3. Enriched table — denormalised for the model (1 table)

| Table | Description | Current rows |
|---|---|---:|
| `flights_enriched` | One row per flight. Weather at origin + destination joined inline; plus derived features (`fog_risk`, `severe_weather`, `hour_of_day`, `day_of_week`, `month`, `season`) and a categorical **`dep_weather_bucket`** (one of `clear`, `light_rain`, `heavy_rain`, `snow`, `fog`). | 1,402,592 |

### 4. Prediction layer — the actual delay predictor (3 tables)

| Table | Description | Current rows |
|---|---|---:|
| `model_route_hour_weather` | **The model.** One row per (origin, dest, hour_of_day, weather_bucket) bucket with ≥10 historical observations. 11 aggregates per row: avg/median/p90 delay, P(late), P(cancelled), pct_short/avg/long/extreme, sample_size. Trained from 2022-2023. | 3,888 |
| `predictions` | 2024 holdout predictions: `exp_delay`, `late_likelihood` (low/avg/high), `magnitude` bucket, sample_size, human-readable `explanation`. | 483,897 |
| `validation_results` | Long-format metrics from the latest `validate_predictions()` run: MAE overall + per-likelihood-bucket, accuracy within ±15/30/60 min, precision_high, precision_low, bucket_match_rate. | 11 (per run) |

### 5. System table (1 table)

| Table | Description |
|---|---|
| `job_log` | Audit trail. Every procedure self-logs: name, start/end time, status (RUNNING/OK/FAILED), rows processed, errors. Durations use `clock_timestamp()` so they reflect real wall-clock time. |

---

## The procedures — what runs everything

Each step is a **stored procedure** (PL/pgSQL inside Postgres). Trigger with `CALL X();`.

| # | Procedure | What it does | Pattern |
|---|---|---|---|
| 1 | `refresh_airports()` | Cast text to types; uppercase IATA; extract state | UPSERT |
| 2 | `refresh_airlines()` | Distinct carriers from staging, lookup table for names | UPSERT |
| 3 | `refresh_weather_hourly()` | Cast text; parse `'2023-01-02T00:00'` as UTC `TIMESTAMPTZ` | TRUNCATE+INSERT |
| 4 | `refresh_flights()` | Cast ~14 columns; build 4 `TIMESTAMPTZ`s from date+HHMM via `hhmm_to_ts()`; derive `dep_del15`/`arr_del15`; FK-filter to known airports/airlines | TRUNCATE+INSERT (**also wipes `flights_enriched` and `predictions`**) |
| 5 | `refresh_routes()` | Distinct (origin, dest) pairs | TRUNCATE+INSERT |
| 6 | `refresh_flights_enriched()` | Join flights ↔ weather_hourly twice (origin + dest at scheduled hour); compute `fog_risk`, `severe_weather`, time-bucket features, and **`dep_weather_bucket`** | TRUNCATE+INSERT |
| 7 | `refresh_model_route_hour_weather()` | Train: per-(origin, dest, hour, weather_bucket) compute 11 aggregates from 2022-2023 flights. `HAVING COUNT(*) >= 10`. | TRUNCATE+INSERT |
| 8 | `predict_flights()` | For every 2024 flight: LEFT JOIN against the model; emit `exp_delay`, `late_likelihood`, `magnitude`, `sample_size`, `explanation` | TRUNCATE+INSERT |
| 9 | `validate_predictions()` | Compare predictions to actual 2024 outcomes; write 11 metric rows under a fresh `run_id` | INSERT (cumulative) |
| 10 | `run_pipeline()` | Master orchestrator — calls steps 1–9 in dependency order, ~99 sec post-cleaning | wraps the above |

Plus two callable helpers:

- **`hhmm_to_ts(date_text, hhmm_text)`** — combines a flight date and HHMM time string into a UTC `TIMESTAMPTZ`. Handles the `'2400'` edge case (= midnight next day). Used inside `refresh_flights()`.
- **`predict_for_airport(p_airport CHAR(3), p_date DATE)`** — `SELECT * FROM predict_for_airport('LAX', DATE '2024-07-15');` returns ranked predictions for the day. The headline demo entrypoint.

### Why two patterns (UPSERT vs TRUNCATE+INSERT)?

- **Static dimension tables** (`airports`, `airlines`) are referenced by other tables via foreign keys. `TRUNCATE` would fail once flights/routes have data. So those use `INSERT … ON CONFLICT DO UPDATE` (UPSERT) — idempotent without ever wiping the table.
- **Fact tables** (`weather_hourly`, `flights`, `routes`, `flights_enriched`) are wiped and rebuilt each run. Used `TRUNCATE+INSERT` for clarity. `refresh_flights()` truncates `flights` and `flights_enriched` together because the latter has an FK to the former.

### Idempotency rule

Every procedure is **safe to re-run** any number of times. The only
ordering caveat: after `refresh_flights()`, you must also call
`refresh_flights_enriched()` (because flights wiped the enriched
table). `run_pipeline()` handles this automatically.

---

## How to run things

In **DataGrip**, connected to `uganda@192.168.203.7`:

```sql
-- Run the entire pipeline (cleaning → model → predictions → validation)
-- Total ~10 min after a fresh fetch+load, ~99 sec without re-cleaning flights.
CALL run_pipeline();

-- Or run individual steps:
CALL refresh_airports();
CALL refresh_airlines();
CALL refresh_weather_hourly();
CALL refresh_flights();                       -- ~2 min on 1.4M rows; ALSO wipes flights_enriched + predictions
CALL refresh_routes();
CALL refresh_flights_enriched();              -- ~56 sec
CALL refresh_model_route_hour_weather();      -- ~13 sec (the training step)
CALL predict_flights();                       -- ~20 sec
CALL validate_predictions();                  -- ~6 sec

-- Inspect the audit trail (durations are real wall-clock, not 0):
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
ORDER BY start_time DESC
LIMIT 10;

-- See the latest validation metrics:
SELECT metric_name, ROUND(metric_value, 3) AS value, population, notes
FROM validation_results
WHERE run_id = (SELECT MAX(run_id) FROM validation_results)
ORDER BY metric_name;

-- The headline demo query — ranked predictions for an airport on a date:
SELECT * FROM predict_for_airport('LAX', DATE '2024-07-15') LIMIT 20;
```

Every run is logged in `job_log` on success. **Failures leave no
partial state anywhere** (cleaned tables and the audit row both roll
back) — the failure signal is the Postgres `ERROR` in the caller's
output. See REPORT.md §9 for the rationale.

---

## Setup

You need Python 3.11 and a venv:

```bash
cd FlightProjectCode
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Dependencies: `pandas`, `requests`, `psycopg2-binary`, `python-dotenv`.

Then create `.env` from `.env.example` and fill in the Uganda DB
credentials:

```bash
cp .env.example .env
# Edit .env — fill in PGUSER and PGPASSWORD
```

---

## Run order — full pipeline from scratch

```bash
source .venv/bin/activate

# Step 1 — fetch raw data into data/raw/
python scripts/fetch_weather.py    # 120 quarterly CSVs (10 airports × 3 years × 4 quarters)
python scripts/fetch_airports.py   # OurAirports → US filtered
# (flights data comes from the parallel Algorithms-project cleaned CSVs;
#  load_bts_clean.py reads them directly, no separate fetch step)

# Step 2 — load CSVs into Postgres staging tables
python scripts/load_bts_clean.py   # → staging.flights_raw   (~1.4M rows after top-10 filter)
python scripts/load_weather.py     # → staging.weather_raw   (~263k rows)
python scripts/load_airports.py    # → staging.airports_raw  (872 rows)

# Step 3 — run the full pipeline (cleaning → model → predictions → validation)
# In DataGrip (or psql):
#   CALL run_pipeline();
```

Each load script is **idempotent**: it drops and recreates its target
staging table on every run, then COPYs the CSV in. `fetch_weather.py`
skips files already on disk so a partial failure can be resumed
without re-downloading.

`data/raw/` is gitignored.

### One-shot helpers for teammates

If you just pulled the repo and want to apply everything from scratch:

```bash
python scripts/apply_and_refresh.py            # applies new procs + runs cleaning
python scripts/apply_predictions_setup.py      # applies the prediction layer
```

The applies are CREATE OR REPLACE-based so they're safe to re-run.

---

## Project layout

```
.
├── config.py                              # AIRPORTS dict (top 10), WEATHER_YEARS
├── requirements.txt                        # pandas, requests, psycopg2-binary, python-dotenv
├── .env.example                            # PG* env var template — copy to .env, fill in
├── REPORT.md                               # design doc for teammates (what & why)
├── presentation.html                       # 12-slide deck (open in a browser)
├── scripts/                                # Python — fetch + load + migration runners
│   ├── fetch_bts.py                        # legacy single-month BTS fetch
│   ├── fetch_weather.py                    # 120 quarterly CSVs (idempotent + retry)
│   ├── fetch_airports.py                   # OurAirports → US filtered
│   ├── load_bts.py                         # legacy 110-col loader
│   ├── load_bts_clean.py                   # 14-col loader, 3 years × top 10, ~1.4M rows
│   ├── load_weather.py                     # globs weather_???_2*.csv into staging
│   ├── load_airports.py
│   ├── inspect_data.py
│   ├── apply_and_refresh.py                # one-shot: applies updated procs + runs refreshes
│   └── apply_predictions_setup.py          # one-shot: applies the prediction layer
├── sql/                                    # SQL — schemas + procedures (run in numeric order)
│   ├── 000_schema_job_log.sql
│   ├── 001_schema_airports.sql
│   ├── 002_proc_refresh_airports.sql
│   ├── 003_schema_airlines.sql
│   ├── 004_proc_refresh_airlines.sql
│   ├── 005_schema_weather_hourly.sql
│   ├── 006_proc_refresh_weather_hourly.sql
│   ├── 007_func_hhmm_to_ts.sql
│   ├── 008_schema_flights.sql
│   ├── 009_proc_refresh_flights.sql
│   ├── 010_schema_routes.sql
│   ├── 011_proc_refresh_routes.sql
│   ├── 012_schema_flights_enriched.sql
│   ├── 013_proc_refresh_flights_enriched.sql
│   ├── 014_proc_run_pipeline.sql
│   ├── 015_schema_model_route_hour_weather.sql       # the model
│   ├── 016_proc_refresh_model_route_hour_weather.sql # trains the model
│   ├── 017_schema_predictions.sql
│   ├── 018_proc_predict_flights.sql                  # produces 2024 predictions
│   ├── 019_schema_validation_results.sql
│   ├── 020_proc_validate_predictions.sql             # MAE + accuracy metrics
│   ├── 021_func_predict_for_airport.sql              # the headline demo function
│   └── demo/
│       └── failed_job_demo.sql                       # the resilience-story demo (paste line by line)
├── data/raw/                               # gitignored — raw CSVs
└── README.md                                # this file
```

Numbered prefix on SQL files = deterministic run order. Schemas and
procedures are split into separate files so each is independently
reviewable.

---

## Conventions and decisions

1. **ELT, not ETL.** Python only downloads + saves. All transforms happen in SQL.
2. **US only.** BTS is US-only by source; OurAirports is filtered to US; weather is per US airport.
3. **Top 50 derived in SQL**, not hardcoded. The fetch keeps all 872 US large+medium airports.
4. **Idempotent everywhere.** Re-running any fetch, load, or procedure is safe.
5. **Single canonical truth.** No data dropped at storage; filter at query time.
6. **No DB credentials in the repo.** `.env` (gitignored) holds them.
7. **Static dim tables use UPSERT** (`airports`, `airlines`); fact tables use TRUNCATE+INSERT.

---

## Demo flow

See **REPORT.md §11** for the minute-by-minute storyboard. The
short version:

```sql
-- 1. Show that the audit trail is alive
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log ORDER BY start_time DESC LIMIT 8;

-- 2. The headline query — predictions for an airport on a date
SELECT * FROM predict_for_airport('LAX', DATE '2024-07-15') LIMIT 15;

-- 3. The validation numbers
SELECT metric_name, ROUND(metric_value, 3) AS value, population, notes
FROM validation_results
WHERE run_id = (SELECT MAX(run_id) FROM validation_results)
ORDER BY metric_name;

-- 4. The resilience demo — paste sql/demo/failed_job_demo.sql line by line
```

Demonstrates: orchestration, audit logging, idempotency, real
predictions, real validation, and clean transactional rollback on
dirty data.

---

## What scales up later

This pipeline runs on **3 years × top 10 airports = 1.4M flights +
263k hourly weather observations**. The same procedures work unchanged
for top-50 airports — only the input volume grows. Specifically:

- Top 10 → top 50 airports: change `AIRPORTS` in `config.py`,
  rerun `fetch_weather.py` (skips already-fetched files), update
  the top-10 filter in `load_bts_clean.py`, rerun.
- More years: extend `WEATHER_YEARS` in `config.py`, extend
  `YEARS` in `load_bts_clean.py`.
- Add carrier as a 5th grouping key for the model: change
  `GROUP BY` in `016_proc_refresh_model_route_hour_weather.sql`
  and add `airline_code` to the model PK.

---

## For teammates

### First-time setup

```bash
git clone https://github.com/zeltmanis/FlightProjectCode.git
cd FlightProjectCode
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env       # edit .env to fill in PGUSER + PGPASSWORD
```

### Running it end-to-end

```bash
# Fetch (Python)
source .venv/bin/activate
python scripts/fetch_weather.py     # 120 quarterly CSVs (resumable)
python scripts/fetch_airports.py

# Load into Postgres staging
python scripts/load_bts_clean.py    # reads from Algorithms-project cleaned CSVs
python scripts/load_weather.py
python scripts/load_airports.py

# Apply schemas + procedures (first time on a fresh DB) and run end-to-end
python scripts/apply_predictions_setup.py

# Or, in DataGrip:
# CALL run_pipeline();
```

### Inspecting the data

```bash
python scripts/inspect_data.py     # row counts, null rates, samples
```

Or any SQL query in DataGrip against the cleaned tables.

### Branching

For now: direct pushes to `main` with clear commit messages. We'll move
to feature branches + PRs once the prediction phase splits work
between teammates.

### Owners

| Area | Owner |
|---|---|
| BTS / Open-Meteo / Python ingestion | Tim |
| PostgreSQL schema, stored procs, pgTAP | Endrit |
| Algorithms, validation, report | Egon |
| Plan, scope, Jira, risk | Edgar |

---

## If a fetch fails

**Open-Meteo Archive** has had outages where the free endpoint returns
504 even on small requests. `fetch_weather.py` retries 3 times with
backoff, but the API can be down for hours. If the script exits with
504s, wait it out (the script is idempotent — re-running picks up
where it left off).

**BTS** is no longer fetched directly — flight data comes from the
parallel **Algorithms-project** sibling at
`/Users/private/Desktop/UNIVERSITY/02_Semester/Algorithms and data/Capstone/data/cleaned/flights_{2022,2023,2024}.csv`.
If those files move, update `CLEANED_DIR` in `scripts/load_bts_clean.py`.

The original `scripts/fetch_bts.py` and `scripts/load_bts.py` are
**legacy** — they handled the single-month spike at the start of the
project. They're kept for reference but the current pipeline doesn't
use them.
