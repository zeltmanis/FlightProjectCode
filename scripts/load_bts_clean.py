"""Load 2022-2024 BTS flights (pre-cleaned in the Algorithms project)
into staging.flights_raw, filtered to top-10-to-top-10 routes.

Source CSVs at:
    /Users/private/Desktop/UNIVERSITY/02_Semester/Algorithms and data/
        Capstone/data/cleaned/flights_{year}.csv

Each cleaned CSV has 14 columns (vs. ~110 in raw BTS):
    FlightDate, Reporting_Airline, Origin, Dest,
    CRSDepTime, DepTime, DepDelayMinutes,
    CRSArrTime, ArrTime, ArrDelayMinutes,
    Cancelled, CancellationCode, WeatherDelay, NASDelay

We replace staging.flights_raw with a matching 14-column TEXT schema
and stream the filtered rows in. Re-running is safe: the table is
dropped & rebuilt every time.

Usage:
    python scripts/load_bts_clean.py
"""

import csv
import io
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[1]

CLEANED_DIR = Path(
    "/Users/private/Desktop/UNIVERSITY/02_Semester/"
    "Algorithms and data/Capstone/data/cleaned"
)
YEARS = [2022, 2023, 2024]

TOP10 = {
    "ATL", "DFW", "DEN", "ORD", "CLT",
    "LAX", "LAS", "PHX", "SEA", "MCO",
}

# 14 staging columns in the order they appear in the cleaned CSV
STAGING_COLUMNS = [
    "flight_date",
    "reporting_airline",
    "origin",
    "dest",
    "crs_dep_time",
    "dep_time",
    "dep_delay_minutes",
    "crs_arr_time",
    "arr_time",
    "arr_delay_minutes",
    "cancelled",
    "cancellation_code",
    "weather_delay",
    "nas_delay",
]


def recreate_staging_table(cur) -> None:
    cur.execute("CREATE SCHEMA IF NOT EXISTS staging;")
    cur.execute("DROP TABLE IF EXISTS staging.flights_raw CASCADE;")
    col_defs = ",\n    ".join(f"{c} TEXT" for c in STAGING_COLUMNS)
    cur.execute(
        f"CREATE TABLE staging.flights_raw (\n    {col_defs}\n);"
    )


def filtered_buffer(csv_path: Path) -> io.StringIO:
    """Stream the CSV, keep rows where Origin AND Dest are in TOP10.

    Returns an in-memory CSV (no header) ready for COPY.
    """
    out = io.StringIO()
    writer = csv.writer(out)

    with csv_path.open("r", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        try:
            origin_idx = header.index("Origin")
            dest_idx = header.index("Dest")
        except ValueError:
            sys.exit(f"Header mismatch in {csv_path}: {header}")

        kept = 0
        scanned = 0
        for row in reader:
            scanned += 1
            if row[origin_idx] in TOP10 and row[dest_idx] in TOP10:
                writer.writerow(row)
                kept += 1

        print(f"        {csv_path.name}: scanned {scanned:,}, kept {kept:,}")

    out.seek(0)
    return out


def main() -> None:
    load_dotenv(ROOT / ".env")

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
            print("[1/3] Recreating staging.flights_raw (14-column shape)...")
            recreate_staging_table(cur)

            print("[2/3] Streaming filtered rows from cleaned CSVs...")
            for year in YEARS:
                csv_path = CLEANED_DIR / f"flights_{year}.csv"
                if not csv_path.exists():
                    sys.exit(f"Missing: {csv_path}")

                buffer = filtered_buffer(csv_path)
                cur.copy_expert(
                    "COPY staging.flights_raw FROM STDIN "
                    "WITH (FORMAT csv, HEADER false, QUOTE '\"')",
                    buffer,
                )

            cur.execute("SELECT COUNT(*) FROM staging.flights_raw;")
            (total,) = cur.fetchone()
            print(f"[3/3] Total in staging.flights_raw: {total:,} rows")

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
