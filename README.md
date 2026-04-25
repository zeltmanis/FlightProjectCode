# Flight Project — Prototype Spike

Goal: pull 1 week of US flight data + matching weather for 5 airports, look at
the shape, decide whether to scale up to top-50 / full-year.

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Run (in order)

```bash
python scripts/fetch_bts.py        # downloads Jan 2023 BTS (~50 MB zip → CSV)
python scripts/fetch_weather.py    # hits Open-Meteo for 5 airports, Jan 2–8
python scripts/inspect_data.py     # prints row counts, null rates, samples
```

## What's in scope for the spike

- **Airports**: ATL, ORD, DFW, DEN, LAX (top 5 US hubs, varied weather profiles)
- **Week**: 2023-01-02 to 2023-01-08 (post-holiday Mon–Sun)
- **Sources**: BTS On-Time Performance (monthly CSV) + Open-Meteo Archive API

## What we want to learn

1. What columns does BTS actually give us? Which are useful, which are noise?
2. Row counts per day per airport — is "5 airports × 7 days" the right size?
3. Null rates on delay/cancellation fields.
4. Does Open-Meteo hourly weather join cleanly to BTS scheduled-departure times?
5. Any timezone gotchas (BTS = local, Open-Meteo = UTC by default).

## If `fetch_bts.py` fails

BTS occasionally blocks scripted downloads. Manual fallback:

1. Go to <https://www.transtats.bts.gov/Tables.asp?gnoyr_VQ=FGJ>
2. Pick "Reporting Carrier On-Time Performance (1987-present)"
3. Filter Year=2023, Month=January, download the prezipped file
4. Unzip and place the CSV at `data/raw/bts_2023_01.csv`, then rerun `inspect_data.py`
