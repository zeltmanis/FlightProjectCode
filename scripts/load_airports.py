"""Load the OurAirports US-filtered CSV into staging.airports_raw.

Pure ELT: every column is loaded as TEXT, in the order the CSV header
declares. Cleaning, casting, and the dimension table (clean.airports)
are built later by stored procedures.

Usage:
    python scripts/load_airports.py
"""

import csv
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]

CSV_PATH = ROOT / "data" / "raw" / "airports_us.csv"


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def main() -> None:
    if not CSV_PATH.exists():
        sys.exit(f"Missing: {CSV_PATH}. Run fetch_airports.py first.")

    load_dotenv(ROOT / ".env")

    with CSV_PATH.open("r", newline="") as f:
        columns = next(csv.reader(f))
    print(f"Airports CSV: {CSV_PATH.name}")
    print(f"Columns: {len(columns)}")
    print(f"File size: {CSV_PATH.stat().st_size / 1024:.0f} KB")

    conn = psycopg2.connect(
        host=os.environ["PGHOST"], port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"], user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"], connect_timeout=10,
    )
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            print("\n[1/4] Creating staging schema if missing...")
            cur.execute("CREATE SCHEMA IF NOT EXISTS staging;")

            print("[2/4] Dropping & recreating staging.airports_raw...")
            cur.execute("DROP TABLE IF EXISTS staging.airports_raw;")
            col_defs = ",\n    ".join(f"{quote_ident(c)} TEXT" for c in columns)
            cur.execute(f"CREATE TABLE staging.airports_raw ({col_defs});")

            print("[3/4] COPY-ing CSV...")
            with CSV_PATH.open("r") as f:
                cur.copy_expert(
                    "COPY staging.airports_raw FROM STDIN "
                    "WITH (FORMAT csv, HEADER true, QUOTE '\"')",
                    f,
                )

            print("[4/4] Counting rows...")
            cur.execute("SELECT COUNT(*) FROM staging.airports_raw;")
            (n,) = cur.fetchone()
            print(f"\nLoaded: {n:,} rows into staging.airports_raw")

        conn.commit()
        print("Committed.")
    except Exception:
        conn.rollback()
        print("Rolled back.")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
