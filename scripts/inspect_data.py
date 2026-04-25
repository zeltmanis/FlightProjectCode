"""Quick look at what we downloaded — row counts, null rates, samples."""

from pathlib import Path
import sys

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import AIRPORTS, MONTH, WEEK_END, WEEK_START, YEAR

RAW = ROOT / "data" / "raw"


def banner(label: str) -> None:
    print()
    print("=" * 70)
    print(label)
    print("=" * 70)


def inspect_bts() -> None:
    path = RAW / f"bts_{YEAR}_{MONTH:02d}.csv"
    if not path.exists():
        print(f"Missing: {path}. Run fetch_bts.py first.")
        return

    banner(f"BTS — {path.name} (whole month)")
    df = pd.read_csv(path, low_memory=False)
    print(f"Rows: {len(df):,}")
    print(f"Columns: {len(df.columns)}")

    codes = list(AIRPORTS.keys())
    week = df[
        (df["FlightDate"] >= WEEK_START)
        & (df["FlightDate"] <= WEEK_END)
        & (df["Origin"].isin(codes))
    ].copy()

    banner(f"BTS — filtered to {codes} between {WEEK_START} and {WEEK_END}")
    print(f"Rows: {len(week):,}")
    print()
    print("Flights per origin per day:")
    print(week.groupby(["Origin", "FlightDate"]).size().unstack(fill_value=0))

    keep = [
        "FlightDate", "Reporting_Airline", "Origin", "Dest",
        "CRSDepTime", "DepTime", "DepDelay", "DepDelayMinutes", "DepDel15",
        "Cancelled", "CancellationCode",
    ]
    keep = [c for c in keep if c in week.columns]

    banner("BTS — null rates on key columns (% of filtered rows)")
    print(week[keep].isna().mean().mul(100).round(1).to_string())

    banner("BTS — sample 5 rows")
    print(week[keep].head().to_string(index=False))


def inspect_weather() -> None:
    path = RAW / f"weather_{WEEK_START}_to_{WEEK_END}.csv"
    if not path.exists():
        print(f"Missing: {path}. Run fetch_weather.py first.")
        return

    banner(f"Weather — {path.name}")
    df = pd.read_csv(path)
    print(f"Rows: {len(df):,}")
    print(f"Columns: {list(df.columns)}")

    banner("Weather — rows per airport (expect 24 × 7 = 168 each)")
    print(df["airport_code"].value_counts())

    banner("Weather — null rates (%)")
    print(df.isna().mean().mul(100).round(1).to_string())

    banner("Weather — sample 5 rows")
    print(df.head().to_string(index=False))


def main() -> None:
    inspect_bts()
    inspect_weather()


if __name__ == "__main__":
    main()
