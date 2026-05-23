"""One-shot setup for the predictions layer (2026-05-23).

Applies the new schema + procedure files (012 weather_bucket
alter, 015-021 model/predictions/validation/demo) and runs
the procedures in dependency order:

  1. ALTER flights_enriched ADD dep_weather_bucket
  2. Replay 013 refresh_flights_enriched (re-populate with bucket)
  3. Apply 015 schema, 016 training proc
  4. CALL refresh_model_route_hour_weather()
  5. Apply 017 schema, 018 prediction proc
  6. CALL predict_flights()
  7. Apply 019 schema, 020 validation proc
  8. CALL validate_predictions()
  9. Apply 021 demo function

Teammates: run this once after `git pull`. Re-running is safe;
every procedure is TRUNCATE+INSERT inside one transaction.

Usage:
    python scripts/apply_predictions_setup.py
"""

import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[1]

# Apply order matches the SQL file numbering.
SQL_FILES = [
    "sql/013_proc_refresh_flights_enriched.sql",
    "sql/015_schema_model_route_hour_weather.sql",
    "sql/016_proc_refresh_model_route_hour_weather.sql",
    "sql/017_schema_predictions.sql",
    "sql/018_proc_predict_flights.sql",
    "sql/019_schema_validation_results.sql",
    "sql/020_proc_validate_predictions.sql",
    "sql/021_func_predict_for_airport.sql",
    "sql/014_proc_run_pipeline.sql",       # updated to include new steps
]


def main() -> None:
    load_dotenv(ROOT / ".env")

    conn = psycopg2.connect(
        host=os.environ["PGHOST"], port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"], user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"], connect_timeout=10,
    )
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            # Step 1: schema alter for the new dep_weather_bucket column.
            print("[alter]  flights_enriched: ADD COLUMN IF NOT EXISTS "
                  "dep_weather_bucket", flush=True)
            cur.execute("""
                ALTER TABLE flights_enriched
                ADD COLUMN IF NOT EXISTS dep_weather_bucket VARCHAR(20)
                CHECK (dep_weather_bucket IS NULL
                       OR dep_weather_bucket IN
                          ('clear','light_rain','heavy_rain',
                           'snow','fog','thunderstorm'));
            """)

            # Step 2: apply all SQL files.
            for path in SQL_FILES:
                print(f"[apply]  {path}", flush=True)
                cur.execute((ROOT / path).read_text())

            # Step 3: run the new procedures.
            for proc, descr in [
                ("refresh_flights_enriched",         "populates dep_weather_bucket"),
                ("refresh_model_route_hour_weather", "trains the model"),
                ("predict_flights",                  "writes 2024 predictions"),
                ("validate_predictions",             "writes validation_results"),
            ]:
                print(f"[call]   {proc}() — {descr}", flush=True)
                cur.execute(f"CALL {proc}();")

            # Final summary.
            print("\n[summary]", flush=True)
            for tbl in ("flights_enriched", "model_route_hour_weather",
                        "predictions", "validation_results"):
                cur.execute(f"SELECT COUNT(*) FROM {tbl};")
                (n,) = cur.fetchone()
                print(f"         {tbl:30} {n:>10,} rows", flush=True)

        conn.commit()
        print("Committed.", flush=True)
    except Exception:
        conn.rollback()
        print("Rolled back.", flush=True)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
