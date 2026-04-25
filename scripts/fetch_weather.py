"""Pull Open-Meteo hourly archive weather for the configured airports + week."""

from pathlib import Path
import sys

import pandas as pd
import requests

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import AIRPORTS, WEEK_START, WEEK_END

URL = "https://archive-api.open-meteo.com/v1/archive"
HOURLY = [
    "temperature_2m",
    "precipitation",
    "snowfall",
    "windspeed_10m",
    "visibility",
    "weathercode",
]

OUT_DIR = ROOT / "data" / "raw"
OUT_PATH = OUT_DIR / f"weather_{WEEK_START}_to_{WEEK_END}.csv"


def fetch_one(code: str, lat: float, lon: float) -> pd.DataFrame:
    params = {
        "latitude": lat,
        "longitude": lon,
        "start_date": WEEK_START,
        "end_date": WEEK_END,
        "hourly": ",".join(HOURLY),
        "timezone": "UTC",
    }
    r = requests.get(URL, params=params, timeout=60)
    r.raise_for_status()
    df = pd.DataFrame(r.json()["hourly"])
    df.insert(0, "airport_code", code)
    return df


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    frames = []
    for code, info in AIRPORTS.items():
        print(f"Fetching {code} ({info['name']})")
        frames.append(fetch_one(code, info["lat"], info["lon"]))
    out = pd.concat(frames, ignore_index=True)
    out.to_csv(OUT_PATH, index=False)
    print(f"Saved: {OUT_PATH} ({len(out):,} rows)")


if __name__ == "__main__":
    main()
