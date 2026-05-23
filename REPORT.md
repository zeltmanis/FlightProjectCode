# Predicting US Flight Delays — a PostgreSQL Capstone

*Databases & Project Management, 02 Semester*

**Author**: Edgar Z (lead builder)
**Team**: Tim (Data Eng), Endrit (DB Eng), Egon (Prediction)
**Date**: *to be set on submission*

> **Note to teammates**: this document is **not the README**.
> `README.md` tells you *how to run the project*; this document tells you
> *what we built and why*. Read this first if you want to understand the
> design, defend it in Q&A, or extend it. Worked examples and references
> back to the actual tables/procedures are in every section.

---

## Abstract

*To be written last.*

---

## 1. Introduction

US domestic flights are delayed often enough that "is my flight likely
to be late?" is a question travellers ask routinely. The US Bureau of
Transportation Statistics (BTS) publishes the underlying data —
scheduled and actual times for every commercial flight, with a delay
breakdown — going back decades. Open-Meteo publishes matching hourly
historical weather for any latitude/longitude.

This project asks: **given two years of BTS history (2022-2023) and
matching weather, can we build a simple, fully explainable delay
predictor for the third year (2024) using only SQL?**

The answer is yes, and the artefact is a stored procedure
`predict_for_airport(airport, date)` that returns a ranked list of
flights with predicted delays and a human-readable explanation. The
"model" is a single PostgreSQL table; the prediction is a JOIN.

---

## 2. Problem statement

For each scheduled flight on a given day at a given airport, predict
three things — one continuous, two categorical:

- **late-likelihood bucket** *(categorical)*: how likely is the flight
  to be late at all, based on history of the same bucket? Three
  values:
  - **low** — historical late rate `< 20%`
  - **average** — historical late rate `20–50%`
  - **high** — historical late rate `≥ 50%`
  ("Late" uses the FAA OTP-15 cutoff, `arr_delay_minutes > 15`.)
- **magnitude bucket** *(categorical)*: if the flight is delayed, how
  badly? Five values:
  - **short** — delay `≤ 30 min`
  - **average** — `30 < delay ≤ 180 min` (up to 3 h)
  - **long** — `180 < delay ≤ 480 min` (up to 8 h)
  - **extreme** — `delay > 480 min`
  - **cancelled** — flight never flew (separate state, not a "very long delay")
- **expected delay in minutes** *(continuous)*: the median historical
  delay for the bucket, so the viewer can see the raw magnitude
  alongside the label.

Plus a **`sample_size`** column for transparency: when fewer than 10
historical flights match the bucket, we suppress the prediction
entirely with `"no data"`, since the percentages would be statistical
noise. This is the *honest* default — telling the user we don't know
when we don't.

The prediction must be made **only from information that would be
available in advance** of the flight: scheduled departure/arrival
times, route, carrier, and the forecast weather. Actual departure or
arrival times must not appear in the prediction inputs (it would make
the model circular). This discipline is enforced by column selection
in the prediction procedure.

---

## 3. Data sources

| Source | What it gives us | Years used | Per-airport coverage |
|---|---|---|---|
| **BTS On-Time Performance** | Every domestic US flight: scheduled & actual times, delays, cancellations, carrier, origin, dest | 2022 + 2023 + 2024 | All US |
| **OurAirports** | Reference dimension: IATA + ICAO codes, name, city, lat/lon, type | static | All US large + medium with IATA |
| **Open-Meteo Archive** | Hourly historical weather: temp, humidity, precipitation, snow, wind, cloud cover | 2022 + 2023 + 2024 | Top-10 airports |

The BTS files were pre-cleaned (column-pruned from ~110 columns to 14)
during the parallel Algorithms capstone project. Reusing that work
saves us a 9 GB raw download; we still perform all type casting,
validation, FK enforcement, and derived-feature generation in
Postgres, so the ELT story holds.

**Scope decision (locked 2026-05-23)**: we focus on the **top 10 US
airports by volume** (with one swap to add a hurricane-exposed Florida
hub):

> ATL, DFW, DEN, ORD, CLT, LAX, LAS, PHX, SEA, MCO

We further restrict to flights where *both* origin **and** destination
are in this top-10 set. That gives us a clean closed network of 90
possible routes, each with substantial training volume, and every
flight has matching weather at both endpoints.

---

## 4. Architecture

We use an **ELT** pattern (Extract + Load with Python, Transform with
SQL). Python is thin glue: fetch, COPY into staging. PostgreSQL does
all the real work — casting, validation, joining, deriving, training,
predicting, validating.

```
[ Python — this repo ]                  [ PostgreSQL — Uganda DB server ]
─────────────────────                    ─────────────────────────────────

  fetch_bts.py     ─COPY─▶  staging.flights_raw       ┐
  fetch_weather.py ─COPY─▶  staging.weather_raw       │  raw, all TEXT
  fetch_airports.py─COPY─▶  staging.airports_raw      ┘
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
                                model_route_hour_weather        (the model)
                                          │
                                          │  predict_flights()
                                          ▼
                                predictions
                                          │
                                          │  validate_predictions()
                                          ▼
                                validation_results
```

Why ELT and not ETL? Because (a) the database has the heavy machinery
for cleaning and joining at scale (indexes, FKs, set-based ops); (b)
keeping transforms in SQL means they're version-controlled migration
files we can read, test, and replay; (c) it makes the entire pipeline
debuggable in DataGrip without re-running Python.

---

## 5. Data ingestion

Three independent fetch scripts, three load scripts. Each is idempotent
— re-running them rebuilds the staging table from the CSV without
side-effects on cleaned data.

### 5.1 Flights — `load_bts_clean.py`

Reads the pre-cleaned BTS CSVs (one per year) from the Algorithms
project's `data/cleaned/` directory, filters in Python to
top-10-to-top-10 routes, and `COPY`s the result into
`staging.flights_raw` (14 TEXT columns). The Python is essentially:

```python
for row in csv.reader(f):
    if row[ORIGIN] in TOP10 and row[DEST] in TOP10:
        writer.writerow(row)
```

After load, `staging.flights_raw` is fully text — empty strings for
NULLs, `"800"` for HHMM times, `"0.0"` / `"1.0"` for booleans. The
cleaning procedure handles all of that.

### 5.2 Weather — `fetch_weather.py` + `load_weather.py`

*Documented in `README.md`; design rationale unchanged from the
original spike. To extend: refetch for 2022-2024 × top-10 airports.*

### 5.3 Airports — `fetch_airports.py` + `load_airports.py`

*Static dimension; one-time fetch from OurAirports.*

---

## 6. Cleaning procedures

*This is where the ELT story lives.* Every staging table is text-only;
each `refresh_*()` procedure casts types, validates, enforces FKs,
derives fields, and writes to a cleaned table.

### 6.1 `refresh_flights()`

Reads `staging.flights_raw`, writes to `flights`. The casts are:

| Staging (TEXT) | Cleaned (typed) | Notes |
|---|---|---|
| `flight_date` | `DATE` | direct cast |
| `reporting_airline` | `VARCHAR(10)` REFERENCES airlines | FK-filter |
| `origin`, `dest` | `CHAR(3)` REFERENCES airports | FK-filter |
| `crs_dep_time` | `SMALLINT` HHMM, then `TIMESTAMPTZ` via `hhmm_to_ts()` | unpadded — `"800"` becomes `0800` |
| `dep_time` | float text → cast to `SMALLINT` (drop `.0`) | `"757.0"` → 757 |
| `cancelled` | `BOOLEAN` (test `= '1.0'`) | |
| `cancellation_code` | `CHAR(1)`, empty string → NULL | |
| `arr_delay_minutes` | `DECIMAL` | |
| `arr_del15` | computed: `arr_delay_minutes > 15` | derived (BTS originally had this column; cleaned CSVs dropped it) |

Procedure self-logs in `job_log` (start/end time, status,
`rows_processed`). On exception, status is `FAILED` with the error
message captured.

*The original 110-column `refresh_flights()` was simpler in some ways
(BTS already had `arr_del15` and `distance_miles`) and harder in
others (more casts). The new version is shorter; we drop columns we
no longer have rather than trying to reconstruct them.*

### 6.2 `refresh_flights_enriched()`

Joins `flights` × `weather_hourly` twice — once on
`(origin, scheduled_departure)` and once on
`(dest, scheduled_arrival)`. Computes derived weather features and a
**weather bucket** used by the prediction model.

The weather bucket is a `CASE` expression over the origin's weather at
the scheduled departure hour:

```sql
CASE
  WHEN origin_snowfall  > 0       THEN 'snow'
  WHEN origin_precip_mm >= 2      THEN 'heavy_rain'
  WHEN origin_precip_mm >  0      THEN 'light_rain'
  WHEN origin_fog_risk            THEN 'fog'
  ELSE 'clear'
END
```

*(Exact thresholds and bucket names are open — to tune against real
data once 3 years are loaded. See §8.)*

---

## 7. Predictive model

### 7.1 Design — "the model is a table"

We deliberately *don't* call out to Python ML libraries. The model is
a single PostgreSQL table — but with **rich aggregates per bucket** so
we can emit both the likelihood and magnitude predictions in §2:

```sql
model_route_hour_weather (
    origin            CHAR(3),
    dest              CHAR(3),
    hour_of_day       SMALLINT,
    weather_bucket    VARCHAR(20),

    -- magnitude (continuous)
    avg_delay         DECIMAL,        -- mean arrival delay
    median_delay      DECIMAL,        -- 50th percentile (used for exp_delay)
    delay_p90         DECIMAL,        -- 90th percentile (worst-case)

    -- likelihood (P(late) and P(cancelled))
    pct_late          DECIMAL,        -- P(arr_delay > 15)
    pct_cancelled     DECIMAL,        -- P(cancelled)

    -- magnitude distribution (sums to 1.0 across the 5 states)
    pct_short         DECIMAL,        -- 0–30 min
    pct_average       DECIMAL,        -- 30–180 min
    pct_long          DECIMAL,        -- 180–480 min
    pct_extreme       DECIMAL,        -- >480 min
    -- pct_cancelled already above; together: short + avg + long + extreme + cancelled = 1.0

    sample_size       INTEGER,
    PRIMARY KEY (origin, dest, hour_of_day, weather_bucket)
)
```

Every row is one prediction rule: *"for flights from ATL to LAX
departing around 14:00 in thunderstorm conditions, 72% of historical
flights were late, the median delay was 180 minutes, and 41% of late
flights were in the 'long' bucket. Sample size: 287."*

All 11 statistics come from **one aggregate query** using Postgres's
`COUNT(*) FILTER (WHERE ...)` and `PERCENTILE_CONT(...)` — pure SQL,
no extensions needed. Worked example in §7.2.

This is the **same shape as a k-NN lookup table** (Sedgewick & Wayne
§3.1), except the bucket is given by the GROUP BY rather than by
distance. Three reasons this is the right model for *this* project:

1. **It's pure SQL.** No external libraries, no opaque artefact. Every
   line is auditable.
2. **It's defensible.** A grader can ask "why did you predict 45 min
   for this flight?" and the answer is a single `SELECT` from the
   model table.
3. **It demonstrates the database course content** — JOINs,
   aggregates, GROUP BY, indexes. The thing we're being graded on.

### 7.2 Training — `refresh_model_route_hour_weather()`

Pseudocode:

```sql
TRUNCATE model_route_hour_weather;
INSERT INTO model_route_hour_weather
SELECT
    origin, dest, hour_of_day, weather_bucket,

    -- magnitude
    AVG(arr_delay_minutes)                                            AS avg_delay,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY arr_delay_minutes)    AS median_delay,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY arr_delay_minutes)    AS delay_p90,

    -- likelihood (P(late), P(cancelled))
    COUNT(*) FILTER (WHERE arr_delay_minutes > 15)::decimal / COUNT(*) AS pct_late,
    COUNT(*) FILTER (WHERE cancelled)::decimal           / COUNT(*) AS pct_cancelled,

    -- magnitude distribution
    COUNT(*) FILTER (WHERE NOT cancelled
                     AND arr_delay_minutes <= 30)::decimal  / COUNT(*) AS pct_short,
    COUNT(*) FILTER (WHERE NOT cancelled
                     AND arr_delay_minutes BETWEEN 30 AND 180)::decimal / COUNT(*) AS pct_average,
    COUNT(*) FILTER (WHERE NOT cancelled
                     AND arr_delay_minutes BETWEEN 180 AND 480)::decimal / COUNT(*) AS pct_long,
    COUNT(*) FILTER (WHERE NOT cancelled
                     AND arr_delay_minutes > 480)::decimal / COUNT(*) AS pct_extreme,

    COUNT(*) AS sample_size
FROM flights_enriched
WHERE EXTRACT(YEAR FROM flight_date) IN (2022, 2023)
GROUP BY origin, dest, hour_of_day, weather_bucket
HAVING COUNT(*) >= 10;          -- §2 minimum: ten historical flights
```

Note we **don't** filter out cancelled rows here — they're real
historical events and contribute to `pct_cancelled`. The
`PERCENTILE_CONT` line skips them implicitly because `arr_delay_minutes`
is NULL for cancelled flights, and aggregate functions ignore NULLs.

The `HAVING COUNT(*) >= 10` clause is the §2 minimum-sample rule:
buckets with fewer than 10 historical observations are silently
dropped from the model. The prediction step's `LEFT JOIN` will then
return NULL for them, surfacing as `"no data, can't predict"` in the
output.

### 7.3 Prediction — `predict_flights()`

For each 2024 flight, look up the matching model row by joining on the
four bucket keys. The procedure derives the **late_likelihood** and
**magnitude** labels from the model's per-bucket aggregates:

```sql
INSERT INTO predictions
SELECT
    f.flight_id,
    f.flight_date, f.origin, f.dest, f.scheduled_departure,

    -- continuous estimate (median, more robust than mean to outliers)
    m.median_delay                                              AS exp_delay,

    -- late-likelihood bucket (§2)
    CASE
      WHEN m.pct_late < 0.20 THEN 'low'
      WHEN m.pct_late < 0.50 THEN 'average'
      ELSE                        'high'
    END                                                         AS late_likelihood,
    m.pct_late                                                  AS late_pct,

    -- magnitude bucket (§2): pick the most-likely category for this bucket
    CASE GREATEST(m.pct_short, m.pct_average, m.pct_long,
                  m.pct_extreme, m.pct_cancelled)
      WHEN m.pct_cancelled THEN 'cancelled'
      WHEN m.pct_extreme   THEN 'extreme'
      WHEN m.pct_long      THEN 'long'
      WHEN m.pct_average   THEN 'average'
      ELSE                      'short'
    END                                                         AS magnitude,

    m.sample_size,

    -- human-readable explanation traceable back to the model row
    'route=' || f.origin || '→' || f.dest ||
        ', hour=' || f.hour_of_day ||
        ', weather=' || f.weather_bucket ||
        ': ' || ROUND(m.pct_late * 100, 0) || '% late historically, ' ||
        'median ' || ROUND(m.median_delay, 0) || ' min '         ||
        '(n=' || m.sample_size || ')'                           AS explanation

FROM flights_enriched f
LEFT JOIN model_route_hour_weather m
  ON  m.origin         = f.origin
  AND m.dest           = f.dest
  AND m.hour_of_day    = f.hour_of_day
  AND m.weather_bucket = f.weather_bucket
WHERE EXTRACT(YEAR FROM f.flight_date) = 2024;
```

`LEFT JOIN` so that flights whose (route × hour × weather) bucket
doesn't exist in 2022-2023 still appear in `predictions` (with all
model-derived columns NULL). The demo procedure renders those as
`"no data, can't predict"` — the *honest* fallback.

**No look-ahead bias**: the SELECT reads only `f.origin`, `f.dest`,
`f.hour_of_day`, `f.weather_bucket`, `f.scheduled_departure` — never
`f.arr_delay_minutes` or `f.cancelled`. The model trained on
2022-2023 cannot peek at the 2024 outcome it is predicting.

### 7.4 Validation — `validate_predictions()`

```sql
INSERT INTO validation_results (run_id, metric, value)
SELECT
    current_run_id,
    'mean_absolute_error',
    AVG(ABS(p.predicted_delay - f.arr_delay_minutes))
FROM predictions p
JOIN flights f USING (flight_id)
WHERE p.predicted_delay IS NOT NULL
  AND NOT f.cancelled;
```

Also bucketed accuracy: proportion of predictions within ±5 / ±10 /
±15 minutes of actual.

---

## 8. Open design decisions

*To be settled as we build.*

- **Weather bucket thresholds**: do we treat 1 mm/hr as "light rain"
  or "still essentially clear"? Tune against 2022-2023 distribution.
- **Carrier as a 5th grouping key**: more refined predictions but
  smaller buckets. Worth comparing on a holdout.
- **Minimum `sample_size` for a usable prediction**: 5? 20? 50?
- **Cancellation prediction**: treated as out-of-scope for the
  capstone (most cancellations are operational, not weather-driven).

---

## 9. Resilience and the `job_log` audit trail

Every refresh procedure self-logs to `job_log`:

```sql
INSERT INTO job_log (job_name, start_time, status) VALUES (...);
-- do the work
UPDATE job_log SET end_time = NOW(), status = 'OK', rows_processed = ...
WHERE job_id = current_job_id;

-- on exception:
EXCEPTION WHEN OTHERS THEN
    UPDATE job_log SET end_time = NOW(), status = 'FAILED', errors = SQLERRM
    WHERE job_id = current_job_id;
    RAISE;
```

This gives us a **per-run audit trail** queryable in DataGrip:

```sql
SELECT job_name, status, rows_processed,
       end_time - start_time AS duration
FROM job_log
ORDER BY start_time DESC
LIMIT 20;
```

For the demo we will deliberately induce a failure (e.g. a missing FK
target), show the `FAILED` row with its error message, fix the issue,
re-run, and show the second row succeed. This is the
**failed-job-and-recovery story** required for the capstone.

---

## 10. Testing — pgTAP

*To be filled in. Plan: tests against (a) schema constraints — the
right NOT NULLs, FKs, and CHECKs are in place; (b) procedure
post-conditions — `refresh_flights()` leaves no orphan FK references;
(c) prediction logic — for a hand-crafted training set with known
historical averages, `predict_flights()` produces those exact
averages.*

---

## 11. Demo flow

Targeting 8-12 minutes plus Q&A. Storyboard:

1. **What the project predicts** (30s) — research question + the
   output (a `predict_for_airport(...)` query result). Sample below.
2. **Data architecture** (60s) — the four-layer diagram in §4.
3. **Cleaning step** (90s) — open a raw-ish staging CSV in DataGrip,
   show messy text, run `refresh_flights()`, show the typed cleaned
   table.
4. **Enrichment + bucketing** (60s) — show `flights_enriched` with
   `weather_bucket` populated.
5. **The model** (90s) — explain "the model is a table"; show
   `model_route_hour_weather` populated with `SELECT * FROM ... WHERE
   origin = 'ATL' AND dest = 'LAX' ORDER BY hour_of_day, weather_bucket;`
   Point out the per-bucket aggregates: `pct_late`, `median_delay`,
   `pct_short / average / long`.
6. **A live prediction** (90s) — call `predict_for_airport('LAX',
   DATE '2024-07-15');`, show the ranked output with both
   **late_likelihood** and **magnitude** labels plus explanation.
7. **Validation** (60s) — show the validation_results: MAE across all
   2024 predictions; accuracy of the categorical late_likelihood
   label (was "high" actually late?).
8. **Resilience demo** (60s) — induce a failure, show the job_log
   FAILED row, fix and re-run.
9. **Tests** (45s) — run pgTAP, show green.
10. **Wrap** (30s) — what we'd extend if we had more time.

### Sample demo output (mock)

```
LAX departures on 2024-07-15  (forecast: thunderstorm 14:00-18:00)

flight  route     dep_time  late_likelihood   most_likely_delay   exp_delay  sample  explanation
─────────────────────────────────────────────────────────────────────────────────────────────────
DL142   LAX→ATL   14:30     high (72%)        long (~180m)        +180 min   287     thunderstorm × 14h: 72% late, median 180 min (n=287)
WN428   LAX→LAS   16:00     high (75%)        average (~80m)      +80 min    198     thunderstorm × 16h: 75% late, many short delays (n=198)
UA306   LAX→ORD   15:15     high (68%)        long (~150m)        +150 min   223     thunderstorm × 15h: 68% late, median 150 min (n=223)
AA204   LAX→DFW   11:30     average (38%)     average (~50m)      +50 min    412     clear × 11h: 38% late, mild (n=412)
DL101   LAX→SEA   07:15     low (12%)         short (~10m)        +10 min    531     clear × 7h: almost always on-time (n=531)
B6217   LAX→JFK   23:50     —                 —                   —          4       no data, can't predict (sample_size < 10)
…
```

Sorted by `late_likelihood DESC, exp_delay DESC`. The last row
demonstrates the **honest default**: when the bucket has too little
history, we suppress the prediction rather than guess.

---

## 12. Conventions and decisions

*Mirrors `README.md` §"Conventions and decisions". Recapping here for
self-containment:*

- **ELT not ETL** — Python is thin glue, SQL does the work.
- **All cleaning is idempotent** — re-runnable, transactional.
- **Static dims use UPSERT; fact tables use TRUNCATE+INSERT** — to
  side-step FK constraint blocks on TRUNCATE.
- **Single canonical truth**: keep all rows, filter at query time.
- **Job audit trail**: every procedure self-logs to `job_log`.
- **Model is a table**: no opaque artefacts.

---

## 13. References & further reading

- US BTS, *Reporting Carrier On-Time Performance*:
  <https://www.transtats.bts.gov/Tables.asp?DB_ID=120>
- Open-Meteo Archive API: <https://open-meteo.com/en/docs/historical-weather-api>
- OurAirports: <https://ourairports.com/data/>
- Sedgewick & Wayne, *Algorithms 4th ed.*, §1.3 (queue + stack), §3.1
  (symbol tables / lookup), §3.4 (hash tables).
- pgTAP documentation: <https://pgtap.org/documentation.html>

---

*This document is built incrementally. Last extended: 2026-05-23.*
