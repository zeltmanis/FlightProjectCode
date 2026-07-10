# Speaker guide — Database schema  (~2–3 min)

**Slides 7–9:** Architecture (ELT flow) → The schema (tables & why) → ER diagram.

## The one-sentence point
> Ten tables in **four roles** — dimensions, facts, model, output (plus a system log) — tied together by **nine foreign keys**, so the database itself guarantees the data is consistent.

## What to say (the story)
- **Architecture is ELT, not ETL:** Python only *loads* the raw data; the **database does all the transforms**, in SQL — version-controlled and easy to inspect in DataGrip.
- **Dimensions** (`airports`, `airlines`, `routes`) — small, stable reference data: the *who* and *where*. Shared by everything.
- **Facts** (`flights` 1.4M, `weather_hourly` 263k) — the events. `flights_enriched` is flights **pre-joined** with weather (1:1), so the model query stays fast.
- **Model & output** (`model_route_hour_weather`, `predictions`, `validation_results`) — the results layer.
- **System** (`job_log`) — every batch run; standalone so an audit row survives a rollback.
- **Why this shape?** It's a **star-ish / dimensional** design: small dimensions, one big fact, and the model is a natural *roll-up* of that fact. **Foreign keys enforce integrity** — a flight literally cannot reference an airport or airline code that doesn't exist.

## Live demo — walk the ER diagram, then prove FK integrity
**On the ER-diagram slide:** trace the arrows — *"flights points to airports (twice, origin + dest) and to airlines; predictions and flights_enriched point to flights; the model points to airports."* Arrows go child → parent.

**In DataGrip:** expand `uganda › public` to show the tables; open `flights` → **Keys** to show the real foreign keys.

**Then in a query console:**
```sql
-- the four roles at a glance
SELECT (SELECT count(*) FROM airports)  AS airports_dim,
       (SELECT count(*) FROM flights)   AS flights_fact,
       (SELECT count(*) FROM model_route_hour_weather) AS model_rows;

-- a real join: busiest routes (fact JOIN dimension via FK)
SELECT origin_airport_code, dest_airport_code, count(*) AS flights
FROM flights GROUP BY 1,2 ORDER BY 3 DESC LIMIT 5;

-- FK integrity, proven: no flight can reference a non-existent airport
SELECT count(*) AS orphan_flights
FROM flights f
LEFT JOIN airports a ON a.airport_code = f.origin_airport_code
WHERE a.airport_code IS NULL;      -- → 0, the foreign key makes orphans impossible
```
**Say on the last query:** *"Zero orphans — and it's not luck. The foreign key rejects any flight with an unknown airport at insert time, so bad references never get in."*

**Optional, punchier FK demo (it errors on purpose):**
```sql
BEGIN;
  -- try to add a flight from an airport that doesn't exist
  UPDATE flights SET origin_airport_code = 'ZZZ' WHERE flight_id =
    (SELECT flight_id FROM flights LIMIT 1);
  -- → ERROR: violates foreign key constraint "flights_origin_airport_code_fkey"
ROLLBACK;   -- nothing changed
```

## If they ask
- *Why denormalise `flights_enriched`?* → the model query groups 1.4M rows by route+hour+weather; pre-joining weather once (batch) beats re-joining on every read.
- *Why is `weather_hourly` not FK'd to airports?* → it's matched by code + hour during enrichment (a join key), and we keep it flexible to scale to more airports without reloading; the enrichment `LEFT JOIN` tolerates a miss.
- *Why `job_log` standalone?* → so its audit rows are independent of any work transaction and survive rollbacks.
