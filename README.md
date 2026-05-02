# Flight Project — ingestion spike

Python ingestion code for the **Databases & Project Management** course
project: a PostgreSQL-based pipeline that ingests US domestic flight data
+ weather, runs two delay-prediction algorithms, and compares accuracy.

This repo currently holds the **prototype spike** — small Python scripts
that pull 1 week of data for 5 hub airports so we can confirm the data
sources work and size the real project. The full project will scale this
to **1 year × top-50 US airports**, with PostgreSQL doing all the
cleaning, enrichment and prediction.

> **Status**: spike code is live. All three data sources fetched
> successfully. Next phase: stand up the Uganda DB server schemas and
> start ingesting raw rows into `staging.*`.

---

## Architecture in one picture

We use an **ELT** pattern (Extract + Load with Python, Transform with SQL).
Python is thin glue; PostgreSQL does the real work.

```
[ Python — this repo ]                          [ PostgreSQL — Uganda DB server ]
─────────────────────                            ─────────────────────────────────

  scripts/fetch_bts.py        ──COPY──>   staging.flights_raw       ┐
  scripts/fetch_weather.py    ──COPY──>   staging.weather_raw       │  raw
  scripts/fetch_airports.py   ──COPY──>   staging.airports_raw      ┘
                                                       │
                                                       │  stored proc: clean_*()
                                                       ▼
                                             clean.flights / weather / airports
                                                       │
                                                       │  stored proc: enrich_*()
                                                       ▼
                                             enriched.flight_weather
                                                       │
                                                       │  stored proc: predict_a() / predict_b()
                                                       ▼
                                             results.predictions
                                                       │
                                                       │  stored proc: compute_accuracy()
                                                       ▼
                                             results.validation
```

Python only owns the top three rows. **Everything from "clean" downward
is SQL** — that's where the course wants its ≥10 PostgreSQL features
demonstrated (stored procs, CTEs, window functions, triggers, pgTAP tests).

---

## Data sources

Three independent feeds. All free, all public.

| Source | What it gives us | Volume | Refresh |
|---|---|---|---|
| **BTS On-Time Performance** | Every domestic US flight: scheduled & actual times, delays, cancellations, carrier, origin, dest | ~50 MB zip per month → ~250 MB CSV | Monthly (BTS publishes ~6 weeks after the month) |
| **OurAirports** | Reference dimension: IATA + ICAO codes, name, city, lat/lon, type (large/medium) | One CSV, filtered to ~180 KB on save | Effectively static — ingest once, never refresh |
| **Open-Meteo Archive** | Hourly historical weather: temp, precipitation, snow, wind, visibility | ~5 KB per airport per week | Daily lag for the most recent ~5 days; otherwise stable |

### Notes on each source

- **BTS** is the project's heavyweight. The full 2023 download is ~3 GB
  uncompressed; with US-only filtering and dropping unused columns we
  expect 1–2 GB to land in PostgreSQL. Already US-only by source — BTS
  is a US Bureau, doesn't track international flights.
- **OurAirports** is global at the source (~12 MB, 85k rows worldwide).
  `fetch_airports.py` filters on save to `iso_country = US`, type ∈
  {large_airport, medium_airport}, and `iata_code IS NOT NULL`. That
  yields **872 rows** — the universe BTS could ever reference.
- **Open-Meteo** doesn't have a "give me everything" download. We hit
  its API per airport, pulling hourly data for a date range. Free, no
  key, no documented rate limit on the archive endpoint.

### "Top 50 busiest" — derived, not configured

We don't hardcode a list of 50 airports. The "top 50" is computed in
SQL once BTS data is loaded:

```sql
-- proposed clean.dim_airports view
SELECT a.*, RANK() OVER (ORDER BY flight_count DESC) AS rank_busiest
FROM clean.airports a
LEFT JOIN (
  SELECT origin AS iata, COUNT(*) AS flight_count
  FROM clean.flights GROUP BY origin
) f USING (iata);
```

Then `WHERE rank_busiest <= 50` is the filter. Change the number, no
re-fetching needed.

---

## Setup

You need Python 3.11 and a venv:

```bash
cd FlightProjectCode
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Dependencies are minimal: `pandas`, `requests`. (No psycopg2 yet — that
comes when we wire the scripts to push directly into Postgres.)

## Run order

```bash
python scripts/fetch_bts.py        # downloads Jan 2023 BTS (~50 MB zip → CSV)
python scripts/fetch_weather.py    # Open-Meteo hourly for 5 airports × 7 days
python scripts/fetch_airports.py   # OurAirports → US large+medium with IATA (~180 KB)
python scripts/inspect_data.py     # prints row counts, null rates, samples
```

Each script is **idempotent** — if the output file already exists, it
prints "Already downloaded" and exits. To re-run from scratch, delete
the file in `data/raw/` first.

## Output structure

```
data/raw/
├── bts_2023_01.csv                            # ~243 MB — January 2023 flights
├── weather_2023-01-02_to_2023-01-08.csv       # ~35 KB — hourly weather, 5 airports
└── airports_us.csv                            # ~181 KB — US airports dimension
```

`data/raw/` is gitignored — we don't commit raw data to the repo.

---

## Project layout

```
.
├── config.py                 # AIRPORTS dict (5 hubs), date range, year/month
├── requirements.txt
├── scripts/
│   ├── fetch_bts.py          # BTS On-Time Performance, one month
│   ├── fetch_weather.py      # Open-Meteo, one week × 5 airports
│   ├── fetch_airports.py     # OurAirports, US large+medium with IATA
│   └── inspect_data.py       # diagnostic: counts, nulls, sample rows
├── data/raw/                 # (gitignored) raw CSVs from the fetchers
└── README.md                 # this file
```

## Conventions and decisions

1. **ELT**, not ETL. Python only downloads + saves; all transforms are SQL.
2. **US only**. BTS is US-only by source; OurAirports is filtered to US;
   weather is pulled per US airport.
3. **Top 50 is derived in SQL**, not hardcoded. The fetch keeps all 872
   US large+medium airports.
4. **One fetch per source**, all named `scripts/fetch_*.py`, same
   shape: download → filter (if needed) → save to `data/raw/`.
5. **Idempotent**: re-running a fetch is safe. Delete the output file
   to force a re-fetch.
6. **No DB credentials in this repo.** When we wire to Postgres, the
   connection string lives in an environment variable, not a file.

## What scales up later

The spike has hardcoded scope (5 airports, 1 week). The real project will:

- Pull **all 12 months of 2023** BTS data (loop in `fetch_bts.py`)
- Pull **52 weeks × top 50 airports** of weather (driven by a SQL-produced
  list, not by `config.py`)
- Push raw rows directly into `staging.*` via psycopg2 instead of
  saving CSVs. (CSVs will become an offline cache fallback only.)
- Add a single-command runner that does fetch + load + run pipeline.

---

## For teammates

### Cloning the repo

```bash
git clone https://github.com/zeltmanis/FlightProjectCode.git
cd FlightProjectCode
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Running the spike end-to-end

```bash
source .venv/bin/activate
python scripts/fetch_bts.py
python scripts/fetch_weather.py
python scripts/fetch_airports.py
python scripts/inspect_data.py
```

`inspect_data.py` is a good "is everything sane" smoke check — run it
after any fetch to verify row counts and null rates look right.

### Branching / commits

For the spike, direct pushes to `main` with clear commit messages are
fine. Once we start on the real DB schema and stored procs, we'll move
to feature branches + PRs (so Endrit's schema migrations don't collide
with Tim's ingest changes).

### Owners (for questions)

| Area | Owner |
|---|---|
| BTS / Open-Meteo / Python ingestion | Tim |
| PostgreSQL schema, stored procs, pgTAP | Endrit |
| Algorithm A & B, validation, report | Egon |
| Plan, scope, Jira, risk | Edgar |

---

## If `fetch_bts.py` fails

BTS occasionally blocks scripted downloads. Manual fallback:

1. Go to <https://www.transtats.bts.gov/Tables.asp?gnoyr_VQ=FGJ>
2. Pick "Reporting Carrier On-Time Performance (1987-present)"
3. Filter Year=2023, Month=January, download the prezipped file
4. Unzip and place the CSV at `data/raw/bts_2023_01.csv`
5. Rerun `inspect_data.py`
