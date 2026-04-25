"""Download BTS On-Time Performance for one month and extract the CSV."""

from pathlib import Path
import io
import sys
import zipfile

import requests

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import YEAR, MONTH

URL = (
    "https://transtats.bts.gov/PREZIP/"
    f"On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{YEAR}_{MONTH}.zip"
)

OUT_DIR = ROOT / "data" / "raw"
OUT_PATH = OUT_DIR / f"bts_{YEAR}_{MONTH:02d}.csv"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT_PATH.exists():
        print(f"Already downloaded: {OUT_PATH}")
        return

    print(f"Downloading {URL}")
    headers = {"User-Agent": "Mozilla/5.0 (university project)"}
    r = requests.get(URL, headers=headers, timeout=180)
    r.raise_for_status()
    print(f"Got {len(r.content) / 1e6:.1f} MB zip, extracting...")

    with zipfile.ZipFile(io.BytesIO(r.content)) as z:
        csv_names = [n for n in z.namelist() if n.lower().endswith(".csv")]
        if not csv_names:
            raise RuntimeError(f"No CSV in zip: {z.namelist()}")
        with z.open(csv_names[0]) as src, OUT_PATH.open("wb") as dst:
            dst.write(src.read())

    print(f"Saved: {OUT_PATH} ({OUT_PATH.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
