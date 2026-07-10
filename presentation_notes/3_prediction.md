# Speaker guide — Prediction  (~2–3 min)

**Slides 11–14:** The model is a table → Predicting 2024 → Validation → Demo.

## The one-sentence point
> The "model" is just a **table of averages** from past flights (2022–2023). To predict a 2024 flight we **look up its bucket** — route + hour + weather — and read off what usually happened. No AI, no black box; every prediction traces to one row.

## What to say (the story)
- **The model is a cheat-sheet.** Take every past flight, sort into buckets by **route + hour + weather**; for each bucket record *how often late*, *typical delay*, and *how many flights we saw*. Built with **one `GROUP BY`** → 3,888 rows.
- **Prediction = one lookup.** Join each 2024 flight to its bucket and read the numbers. If a bucket has **< 10 past flights**, we honestly say *"not enough history."* Coverage: **98.5%** of 484k flights.
- **Two answers per flight:** *late-likelihood* (low / average / high) and *delay size* (short / average / long / …).
- **Validation (2024 holdout):** on average we're **~17 min off**; **78% within ±15 min**, **86% within ±30 min**. For a pure-SQL lookup trained in ~13 s, honest numbers.

## Live demo — predict, then check it against reality
> **Good demo pick: `LAX` on `2024-02-09`** (a light-rain evening — 148 departures, and the model got **125 within 15 min**). Verified to work well.

```sql
-- 1. PREDICT every LAX departure that day, ranked by late-likelihood
SELECT * FROM predict_for_airport('LAX', DATE '2024-02-09');
```
**Point at:** the `late_likelihood` + `late_pct` columns, `magnitude`/`exp_delay`, and especially the **`explanation`** column — e.g. *"LAX→LAS, hour=19, weather=light_rain: 43% late historically, median 14m (n=74)."* Say: *"Every prediction explains itself — it's just history for that bucket."* Scroll to a low-likelihood clear-weather flight vs a higher rainy-hour one.

```sql
-- 2. EVALUATE — how did those predictions do vs what actually happened?
SELECT * FROM evaluate_for_airport('LAX', DATE '2024-02-09');
```
**Point at:** the `predicted` vs `actual_min` and the `verdict` column. Then summarise the day:
```sql
SELECT verdict, count(*) FROM evaluate_for_airport('LAX', DATE '2024-02-09')
GROUP BY verdict ORDER BY 2 DESC;
-- within 15 min: 125 | within 30: 9 | within 60: 8 | off by more: 4 | no prediction: 2
```
Say: *"On this day, 125 of 148 within 15 minutes — and where we were wrong, we can see it, because the actuals are right there."*

## Backup dates / airports (if LAX/Feb-9 looks flat live)
Any big hub works; try a few and pick one with a weather story:
```sql
SELECT * FROM predict_for_airport('ATL', DATE '2024-01-15');
SELECT * FROM predict_for_airport('ORD', DATE '2024-02-09');
SELECT * FROM predict_for_airport('DFW', DATE '2024-07-04');
```
Rule of thumb for a lively demo: pick a date where the weather bucket isn't `clear` for the evening rush — the late-likelihood spread is more interesting.

## If they ask
- *Isn't this just a big GROUP BY?* → yes — and that's the point: it's fully explainable and reproducible, unlike a black-box model.
- *Why does error grow for "high" predictions?* → delay *variance* grows with severity; big delays are inherently harder to pin to the minute. We still get the *bucket* right 84% of the time.
- *Overfitting?* → we train on 2022–2023 and validate on an untouched **2024 holdout** — the numbers above are out-of-sample.
- *`< 10` rule?* → thin buckets are unreliable, so we return "no prediction" instead of guessing.
