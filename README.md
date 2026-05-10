# Flight Project — ingestion + cleaning pipeline

End-to-end PostgreSQL pipeline for the **Databases & Project Management**
course project: ingest US flight data + weather, clean it, enrich it,
and (next) run delay-prediction algorithms against it.

> **Status**: ingestion + cleaning + enrichment is **live and tested**.
> Three raw tables, seven cleaned/derived tables, seven stored
> procedures, one helper function, and a master orchestrator —
> everything reproducible from one `CALL run_pipeline()`. Next phase:
> prediction algorithms.

---

## Architecture in one picture

We use an **ELT** pattern (Extract + Load with Python, Transform with SQL).
Python is thin glue; PostgreSQL does the real work.

```
[ Python — this repo ]                    [ PostgreSQL — Uganda DB server ]
─────────────────────                      ─────────────────────────────────

  fetch_bts.py        ──COPY──>  staging.flights_raw       ┐
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
                                            │  (next phase)
                                            ▼
                                  predictions / actuals / validation_results
```

Everything from "raw" downward is SQL. Stored procedures, foreign keys,
CHECK constraints, joins, DATE_TRUNC, CASE expressions, UPSERTs, audit
triggers — all in the database, all version-controlled in `sql/`.

---

## Data sources

Three independent feeds. All free, all public.

| Source | What it gives us | Volume | Refresh |
|---|---|---|---|
| **BTS On-Time Performance** | Every domestic US flight: scheduled & actual times, delays, cancellations, carrier, origin, dest | ~50 MB zip per month → ~250 MB CSV | Monthly |
| **OurAirports** | Reference dimension: IATA + ICAO codes, name, city, lat/lon, type | One CSV, filtered to ~180 KB | Effectively static |
| **Open-Meteo Archive** | Hourly historical weather: temp, humidity, precipitation, snow, wind, cloud cover | ~5 KB per airport per week | Daily lag for recent days; otherwise stable |

---

## The database — 4 layers, 10 tables, 7 procedures

The Uganda PostgreSQL server holds all the project data. There are
three logical groups:

### 1. Staging tables — raw text, exactly as ingested (3 tables)

These mirror the CSVs verbatim. Every column is `TEXT`. Cleaning,
casting, and validation happen *afterwards* via the procedures below.

| Table | Source | Rows |
|---|---|---|
| `staging.flights_raw` | BTS CSV | ~540k per month |
| `staging.weather_raw` | Open-Meteo CSV | ~168 per airport per week |
| `staging.airports_raw` | OurAirports CSV | 872 (US large + medium with IATA) |

### 2. Cleaned tables — typed, validated, reference-integrity (5 tables)

| Table | Description | Rows |
|---|---|---|
| `airports` | Dimension: 872 US airports, code → name/city/state/lat/lon. Static. | 872 |
| `airlines` | Dimension: carriers that appear in BTS. Static. | 15 |
| `weather_hourly` | One row per (airport, hour). UTC timestamps, typed values. UNIQUE on (airport_code, obs_timestamp). | 840 |
| `flights` | One row per scheduled flight. ~25 typed columns including `TIMESTAMPTZ` columns built from BTS date+HHMM. | ~531k |
| `routes` | Distinct (origin, dest) pairs. Derived from flights. | 5,478 |

### 3. Enriched table — denormalised for the algorithms (1 table)

| Table | Description | Rows |
|---|---|---|
| `flights_enriched` | One row per flight. Weather at origin + destination joined inline; plus derived features (`fog_risk`, `severe_weather`, `hour_of_day`, `day_of_week`, `month`, `season`). The table the prediction algorithms train on. | ~531k |

### 4. System table (1 table)

| Table | Description |
|---|---|
| `job_log` | Audit trail. Every procedure self-logs: name, start/end time, status (RUNNING/OK/FAILED), rows processed, errors. |

---

## The procedures — what runs the cleaning

Each cleaning step is a **stored procedure**: PL/pgSQL code that lives
inside Postgres. You trigger one with `CALL refresh_X();`.

| # | Procedure | What it does | Source → Target | Pattern |
|---|---|---|---|---|
| 1 | `refresh_airports()` | Cast text to types; uppercase IATA; extract state from `iso_region` | `staging.airports_raw` → `airports` | UPSERT |
| 2 | `refresh_airlines()` | Distinct carriers from BTS, joined to a small in-procedure name lookup | `staging.flights_raw` → `airlines` | UPSERT |
| 3 | `refresh_weather_hourly()` | Cast text to typed columns; parse `'2023-01-02T00:00'` as UTC `TIMESTAMPTZ` | `staging.weather_raw` → `weather_hourly` | TRUNCATE+INSERT |
| 4 | `refresh_flights()` | Cast 25 columns; build 4 `TIMESTAMPTZ`s from date+HHMM via `hhmm_to_ts()`; FK-filter to known airports/airlines | `staging.flights_raw` → `flights` | TRUNCATE+INSERT (also wipes `flights_enriched`) |
| 5 | `refresh_routes()` | Distinct (origin, dest) pairs | `flights` → `routes` | TRUNCATE+INSERT |
| 6 | `refresh_flights_enriched()` | Join flights ↔ weather_hourly twice (origin + dest at scheduled hour); compute `fog_risk`, `severe_weather`, time-bucket features | `flights` × `weather_hourly` × 2 → `flights_enriched` | TRUNCATE+INSERT |
| 7 | `run_pipeline()` | Master orchestrator — runs all six in dependency order | (everything) → (everything) | wraps the above |

Plus one helper function:

- **`hhmm_to_ts(date_text, hhmm_text)`** — combines a BTS `FlightDate` and HHMM time string (`'2023-01-09'` + `'0855'`) into a UTC `TIMESTAMPTZ`. Handles BTS's `'2400'` edge case (= midnight of next day). Used inside `refresh_flights()`.

### Why two patterns (UPSERT vs TRUNCATE+INSERT)?

- **Static dimension tables** (`airports`, `airlines`) are referenced by other tables via foreign keys. `TRUNCATE` would fail once flights/routes have data. So those use `INSERT … ON CONFLICT DO UPDATE` (UPSERT) — idempotent without ever wiping the table.
- **Fact tables** (`weather_hourly`, `flights`, `routes`, `flights_enriched`) are wiped and rebuilt each run. Used `TRUNCATE+INSERT` for clarity. `refresh_flights()` truncates `flights` and `flights_enriched` together because the latter has an FK to the former.

### Idempotency rule

Every procedure is **safe to re-run** any number of times. The only
ordering caveat: after `refresh_flights()`, you must also call
`refresh_flights_enriched()` (because flights wiped the enriched
table). `run_pipeline()` handles this automatically.

---

## How to run a job

In **DataGrip**, connected to `uganda@192.168.203.7`:

```sql
-- Run the entire cleaning + enrichment pipeline (~7 minutes):
CALL run_pipeline();

-- Or run just one step:
CALL refresh_airports();
CALL refresh_airlines();
CALL refresh_weather_hourly();
CALL refresh_flights();              -- ~5 min, also clears flights_enriched
CALL refresh_routes();
CALL refresh_flights_enriched();     -- ~16 sec

-- Inspect the audit trail:
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
ORDER BY start_time DESC
LIMIT 10;
```

Every run is logged in `job_log`. If a procedure fails, its row shows
`status='FAILED'` with the error message in the `errors` column.

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
python scripts/fetch_bts.py        # ~50 MB zip → CSV (one month)
python scripts/fetch_weather.py    # Open-Meteo per airport in config.py
python scripts/fetch_airports.py   # OurAirports → US filtered

# Step 2 — load CSVs into Postgres staging tables
python scripts/load_bts.py         # → staging.flights_raw   (~540k rows, 201 MB)
python scripts/load_weather.py     # → staging.weather_raw   (~840 rows)
python scripts/load_airports.py    # → staging.airports_raw  (872 rows)

# Step 3 — run the cleaning + enrichment pipeline
# In DataGrip (or psql):
#   CALL run_pipeline();
```

Each load script is **idempotent**: it drops and recreates its target
staging table on every run, then COPYs the CSV in.

Each fetch script is also idempotent — if the output file already
exists, it prints "Already downloaded" and exits. Delete the file in
`data/raw/` to force a re-fetch.

`data/raw/` is gitignored.

---

## Project layout

```
.
├── config.py                              # AIRPORTS dict (5 hubs), date range, year/month
├── requirements.txt                        # pandas, requests, psycopg2-binary, python-dotenv
├── .env.example                            # PG* env var template — copy to .env, fill in
├── scripts/                                # Python — fetch + load
│   ├── fetch_bts.py
│   ├── fetch_weather.py
│   ├── fetch_airports.py
│   ├── load_bts.py
│   ├── load_weather.py
│   ├── load_airports.py
│   └── inspect_data.py
├── sql/                                    # SQL — schemas + procedures
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
│   └── 014_proc_run_pipeline.sql
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

## Demo flow (3 minutes — what to show a teacher)

```sql
-- 1. Show the audit trail before
SELECT job_name, status, rows_processed
FROM job_log ORDER BY start_time DESC LIMIT 5;

-- 2. Run the entire pipeline (talk during it — ~7 min)
CALL run_pipeline();

-- 3. Show everything got refreshed
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log ORDER BY start_time DESC LIMIT 8;

-- 4. Show a real result query against the cleaned data
SELECT origin_airport_code AS origin,
       COUNT(*) AS flights,
       ROUND(100.0 * AVG(dep_del15::int), 1) AS pct_delayed
FROM flights
GROUP BY 1
ORDER BY flights DESC
LIMIT 10;
```

Demonstrates: orchestration, audit logging, idempotency, and a real
analytical query.

---

## What scales up later

This pipeline currently runs against **1 month of BTS + 1 week of
weather × 5 hubs**. The same procedures work unchanged for a full
year × top-50 airports — only the input volume grows. Specifically:

- Pull all 12 months of 2023 BTS → loop in `fetch_bts.py`
- Pull weather for top-50 airports × 52 weeks → driven by a SQL-produced
  list (instead of `config.py`), then `fetch_weather.py` runs in a loop
- Push raw rows directly into `staging.*` from Python (skip CSV) — small
  rewrite of the load scripts; CSVs become an offline cache fallback only

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
# Fetch + load (Python)
source .venv/bin/activate
python scripts/fetch_bts.py
python scripts/fetch_weather.py
python scripts/fetch_airports.py
python scripts/load_bts.py
python scripts/load_weather.py
python scripts/load_airports.py

# Then in DataGrip:
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

## If `fetch_bts.py` fails

BTS occasionally blocks scripted downloads. Manual fallback:

1. Go to <https://www.transtats.bts.gov/Tables.asp?gnoyr_VQ=FGJ>
2. Pick "Reporting Carrier On-Time Performance (1987-present)"
3. Filter Year=2023, Month=January, download the prezipped file
4. Unzip and place the CSV at `data/raw/bts_2023_01.csv`
5. Continue with `python scripts/load_bts.py`
