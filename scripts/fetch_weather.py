"""Fetch Open-Meteo Archive hourly weather for the top-10 airports × WEATHER_YEARS.

One CSV per (airport, year, quarter) saved to data/raw/. Idempotent —
skips files that already exist on disk. Re-running after a partial
failure picks up exactly where it left off.

Why quarters: Open-Meteo's archive endpoint returns 504 Gateway Timeout
on full-year requests for some airports. Quarterly slices (~2,200
hourly rows per call) are reliable. The tradeoff is more API calls
(120 instead of 30); since each takes 1-3 seconds, the total fetch
is still ~5 minutes.

Note on `visibility`: the Open-Meteo Archive API silently returns NULL
for the `visibility` parameter. We use `cloud_cover` and
`relative_humidity_2m` as proxies.

Usage:
    python scripts/fetch_weather.py
"""

import sys
import time
from pathlib import Path

import pandas as pd
import requests

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import AIRPORTS, WEATHER_YEARS

URL = "https://archive-api.open-meteo.com/v1/archive"
HOURLY = [
    "temperature_2m",
    "relative_humidity_2m",
    "precipitation",
    "snowfall",
    "windspeed_10m",
    "cloud_cover",
    "weathercode",
]

OUT_DIR = ROOT / "data" / "raw"
SLEEP_BETWEEN = 0.5         # seconds — polite to Open-Meteo's free tier
MAX_RETRIES   = 3
BACKOFF_BASE  = 3.0          # seconds; 3, 6, 12

QUARTERS = [
    ("Q1", "01-01", "03-31"),
    ("Q2", "04-01", "06-30"),
    ("Q3", "07-01", "09-30"),
    ("Q4", "10-01", "12-31"),
]


def out_path(code: str, year: int, q_label: str) -> Path:
    return OUT_DIR / f"weather_{code}_{year}_{q_label}.csv"


def fetch_one(code: str, lat: float, lon: float,
              start: str, end: str) -> pd.DataFrame:
    params = {
        "latitude":   lat,
        "longitude":  lon,
        "start_date": start,
        "end_date":   end,
        "hourly":     ",".join(HOURLY),
        "timezone":   "UTC",
    }
    last_exc: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            r = requests.get(URL, params=params, timeout=120)
            r.raise_for_status()
            df = pd.DataFrame(r.json()["hourly"])
            df.insert(0, "airport_code", code)
            return df
        except (requests.HTTPError, requests.Timeout,
                requests.ConnectionError) as e:
            last_exc = e
            if attempt < MAX_RETRIES:
                backoff = BACKOFF_BASE * (2 ** (attempt - 1))
                print(f"           attempt {attempt} failed ({e!r}); "
                      f"backing off {backoff:.0f}s")
                time.sleep(backoff)
            else:
                raise
    raise RuntimeError("unreachable") from last_exc


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    total = len(AIRPORTS) * len(WEATHER_YEARS) * len(QUARTERS)
    i = 0
    skipped = 0
    fetched = 0
    for code, info in AIRPORTS.items():
        for year in WEATHER_YEARS:
            for q_label, md_start, md_end in QUARTERS:
                i += 1
                path = out_path(code, year, q_label)
                if path.exists():
                    print(f"[{i:>3}/{total}] {code} {year} {q_label}: "
                          f"already on disk, skip")
                    skipped += 1
                    continue
                print(f"[{i:>3}/{total}] {code} {year} {q_label}: "
                      f"fetching ...")
                start = f"{year}-{md_start}"
                end   = f"{year}-{md_end}"
                df = fetch_one(code, info["lat"], info["lon"], start, end)
                df.to_csv(path, index=False)
                print(f"            saved {path.name} ({len(df):,} rows)")
                fetched += 1
                time.sleep(SLEEP_BETWEEN)

    print(f"\nDone. {fetched} fetched, {skipped} already on disk. "
          f"Files in {OUT_DIR}")


if __name__ == "__main__":
    main()
