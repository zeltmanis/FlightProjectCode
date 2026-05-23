"""Load all weather_{airport}_{year}.csv files into staging.weather_raw.

Drops and recreates the staging table, then COPYs every per-(airport,
year) CSV file in data/raw/. Idempotent.

Usage:
    python scripts/load_weather.py
"""

import csv
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]

RAW_DIR = ROOT / "data" / "raw"
# Tight pattern matches per-(airport, year) files like
# weather_ATL_2022.csv but NOT the old spike blob
# weather_2023-01-02_to_2023-01-08.csv.
PATTERN = "weather_???_2*.csv"


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def read_header(path: Path) -> list[str]:
    with path.open("r", newline="") as f:
        return next(csv.reader(f))


def main() -> None:
    load_dotenv(ROOT / ".env")

    files = sorted(RAW_DIR.glob(PATTERN))
    if not files:
        sys.exit(f"No files matching {PATTERN} in {RAW_DIR}. "
                 f"Run fetch_weather.py first.")

    # All files should share the same column order — sanity check.
    columns = read_header(files[0])
    for f in files[1:]:
        if read_header(f) != columns:
            sys.exit(f"Column mismatch: {f.name} differs from "
                     f"{files[0].name}")

    print(f"Found {len(files)} files; columns: {len(columns)}")
    total_size = sum(f.stat().st_size for f in files)
    print(f"Total size: {total_size / 1e6:.1f} MB\n")

    conn = psycopg2.connect(
        host=os.environ["PGHOST"], port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"], user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"], connect_timeout=10,
    )
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            print("[1/3] Creating staging schema if missing...")
            cur.execute("CREATE SCHEMA IF NOT EXISTS staging;")

            print("[2/3] Dropping & recreating staging.weather_raw...")
            cur.execute("DROP TABLE IF EXISTS staging.weather_raw;")
            col_defs = ",\n    ".join(
                f"{quote_ident(c)} TEXT" for c in columns
            )
            cur.execute(
                f"CREATE TABLE staging.weather_raw ({col_defs});"
            )

            print("[3/3] COPY-ing files...")
            running_total = 0
            for path in files:
                with path.open("r") as f:
                    cur.copy_expert(
                        "COPY staging.weather_raw FROM STDIN "
                        "WITH (FORMAT csv, HEADER true, QUOTE '\"')",
                        f,
                    )
                cur.execute("SELECT COUNT(*) FROM staging.weather_raw;")
                (n_total,) = cur.fetchone()
                added = n_total - running_total
                running_total = n_total
                print(f"        {path.name}: +{added:,} rows")

            print(f"\nLoaded: {running_total:,} rows into staging.weather_raw")

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
