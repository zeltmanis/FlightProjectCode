"""Load the BTS On-Time Performance CSV into staging.flights_raw on Uganda DB.

Pure ELT: every column is loaded as TEXT, in original BTS order, with no
type coercion. The clean.flights table (built later by a stored proc)
will do the casting, validation, and column subsetting.

Re-running this script is safe: it drops and recreates staging.flights_raw
each time, then COPYs the CSV in. That makes the spike reproducible.

Usage:
    python scripts/load_bts.py
"""

import csv
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import YEAR, MONTH

CSV_PATH = ROOT / "data" / "raw" / f"bts_{YEAR}_{MONTH:02d}.csv"


def read_columns(csv_path: Path) -> list[str]:
    """Read the CSV's first row and return its column names.

    BTS leaves a trailing comma in their CSV header, which produces a
    final empty column. We keep it (so the data rows still match by
    column count during COPY) but rename it to a valid identifier.
    """
    with csv_path.open("r", newline="") as f:
        reader = csv.reader(f)
        cols = next(reader)
    return [c if c else f"_blank_{i}" for i, c in enumerate(cols)]


def quote_ident(name: str) -> str:
    """Double-quote a Postgres identifier, escaping any embedded quotes."""
    return '"' + name.replace('"', '""') + '"'


def main() -> None:
    if not CSV_PATH.exists():
        sys.exit(f"Missing: {CSV_PATH}. Run fetch_bts.py first.")

    load_dotenv(ROOT / ".env")

    columns = read_columns(CSV_PATH)
    print(f"BTS CSV: {CSV_PATH.name}")
    print(f"Columns: {len(columns)}")
    print(f"File size: {CSV_PATH.stat().st_size / 1e6:.1f} MB")

    conn = psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
        connect_timeout=10,
    )
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            print("\n[1/4] Creating staging schema if missing...")
            cur.execute("CREATE SCHEMA IF NOT EXISTS staging;")

            print("[2/4] Dropping & recreating staging.flights_raw...")
            cur.execute("DROP TABLE IF EXISTS staging.flights_raw;")
            col_defs = ",\n    ".join(
                f"{quote_ident(c)} TEXT" for c in columns
            )
            cur.execute(f"""
                CREATE TABLE staging.flights_raw (
                    {col_defs}
                );
            """)

            print("[3/4] COPY-ing CSV into staging.flights_raw "
                  "(this can take a minute)...")
            with CSV_PATH.open("r") as f:
                cur.copy_expert(
                    "COPY staging.flights_raw FROM STDIN "
                    "WITH (FORMAT csv, HEADER true, QUOTE '\"')",
                    f,
                )

            print("[4/4] Counting rows...")
            cur.execute("SELECT COUNT(*) FROM staging.flights_raw;")
            (n,) = cur.fetchone()
            print(f"\nLoaded: {n:,} rows into staging.flights_raw")

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
