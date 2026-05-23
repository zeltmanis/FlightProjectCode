"""One-shot migration runner for the 2026-05-23 scale-up.

Applies the two updated procedure files (refresh_airlines,
refresh_flights) to Postgres, then calls them in order.

This exists because the staging.flights_raw shape changed
(110 raw BTS cols → 14 cleaned cols), which broke the old
procedures. Once everyone has run this once, the old
load_bts.py is obsolete and the predictions phase can begin.

Usage:
    python scripts/apply_and_refresh.py
"""

import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[1]
SQL_FILES = [
    ROOT / "sql" / "004_proc_refresh_airlines.sql",
    ROOT / "sql" / "009_proc_refresh_flights.sql",
]


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
            for sql_file in SQL_FILES:
                print(f"[apply]  {sql_file.relative_to(ROOT)}", flush=True)
                cur.execute(sql_file.read_text())

            print("[call]   refresh_airlines() ...", flush=True)
            cur.execute("CALL refresh_airlines();")
            cur.execute("SELECT COUNT(*) FROM airlines;")
            (n_airlines,) = cur.fetchone()
            print(f"         airlines: {n_airlines} rows", flush=True)

            print("[call]   refresh_flights() (this can take 5-15 min) ...",
                  flush=True)
            cur.execute("CALL refresh_flights();")
            cur.execute("SELECT COUNT(*) FROM flights;")
            (n_flights,) = cur.fetchone()
            print(f"         flights:  {n_flights:,} rows", flush=True)

            print("[audit]  recent job_log entries:", flush=True)
            cur.execute("""
                SELECT job_name, status, rows_processed,
                       end_time - start_time AS duration
                FROM job_log
                ORDER BY start_time DESC
                LIMIT 5;
            """)
            for r in cur.fetchall():
                print(f"         {r[0]:25} {r[1]:8} "
                      f"rows={r[2]!s:>10} dur={r[3]}", flush=True)

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
