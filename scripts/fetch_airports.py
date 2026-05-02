"""Download OurAirports reference data and keep only the US subset we need.

This is the third raw source alongside BTS flights and Open-Meteo weather.
It maps IATA codes to airport name, type, country and lat/lon — needed for
weather lookups (so we don't have to hand-maintain coordinates) and for
nice display in reports.

OurAirports publishes a single global CSV (~13 MB, 85k rows worldwide).
Since this project only ever cares about US airports, we filter on save
to:
  - iso_country = US
  - type in (large_airport, medium_airport)
  - iata_code populated

That's ~870 rows — the universe BTS could ever reference. The "top 50
busiest" filter happens later in SQL, against actual BTS flight counts.
"""

import io
from pathlib import Path

import pandas as pd
import requests

ROOT = Path(__file__).resolve().parents[1]

URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
OUT_DIR = ROOT / "data" / "raw"
OUT_PATH = OUT_DIR / "airports_us.csv"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT_PATH.exists():
        print(f"Already downloaded: {OUT_PATH}")
        return

    print(f"Downloading {URL}")
    headers = {"User-Agent": "Mozilla/5.0 (university project)"}
    r = requests.get(URL, headers=headers, timeout=60)
    r.raise_for_status()
    print(f"Got {len(r.content) / 1e6:.2f} MB worldwide CSV; filtering to US...")

    df = pd.read_csv(io.BytesIO(r.content), low_memory=False)
    us = df[
        (df["iso_country"] == "US")
        & (df["type"].isin(["large_airport", "medium_airport"]))
        & (df["iata_code"].notna())
    ].copy()

    us.to_csv(OUT_PATH, index=False)
    print(
        f"Saved: {OUT_PATH} "
        f"({OUT_PATH.stat().st_size / 1024:.0f} KB, {len(us):,} rows)"
    )


if __name__ == "__main__":
    main()
