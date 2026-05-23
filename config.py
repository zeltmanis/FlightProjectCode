"""Shared configuration for the Flight Project."""

# Top 10 US airports by volume, with LGA → MCO swap (adds Florida
# hurricane-exposed hub for weather signal diversity).
# Locked 2026-05-23.
AIRPORTS = {
    "ATL": {"name": "Hartsfield-Jackson Atlanta", "lat": 33.6407, "lon":  -84.4277},
    "DFW": {"name": "Dallas/Fort Worth",          "lat": 32.8998, "lon":  -97.0403},
    "DEN": {"name": "Denver",                     "lat": 39.8561, "lon": -104.6737},
    "ORD": {"name": "O'Hare Chicago",             "lat": 41.9786, "lon":  -87.9048},
    "CLT": {"name": "Charlotte Douglas",          "lat": 35.2140, "lon":  -80.9431},
    "LAX": {"name": "Los Angeles",                "lat": 33.9416, "lon": -118.4085},
    "LAS": {"name": "Las Vegas Harry Reid",       "lat": 36.0834, "lon": -115.1518},
    "PHX": {"name": "Phoenix Sky Harbor",         "lat": 33.4353, "lon": -112.0059},
    "SEA": {"name": "Seattle-Tacoma",             "lat": 47.4479, "lon": -122.3103},
    "MCO": {"name": "Orlando International",      "lat": 28.4294, "lon":  -81.3090},
}

# Weather coverage matches the BTS scale-up.
WEATHER_YEARS = [2022, 2023, 2024]

# Legacy single-month spike values (used by the original load_bts.py).
# Safe to remove once the demo-sample loader replaces it.
YEAR  = 2023
MONTH = 1
