-- =========================================================
-- 007_func_hhmm_to_ts.sql
--
-- Helper function that combines a BTS flight date (DATE-as-text,
-- e.g. '2023-01-15') with a BTS HHMM time string (e.g. '0855',
-- '2245') and returns a TIMESTAMPTZ in UTC.
--
-- Special cases:
--   - Empty or NULL hhmm  → NULL (e.g. cancelled flight has
--                          no actual_departure)
--   - HHMM = '2400'       → midnight of the next day
--                          (BTS uses 2400 occasionally for
--                          flights crossing midnight)
--
-- IMMUTABLE so PostgreSQL can cache results within a query.
-- =========================================================

CREATE OR REPLACE FUNCTION hhmm_to_ts(date_text TEXT, hhmm_text TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF date_text IS NULL OR date_text = '' THEN RETURN NULL; END IF;
    IF hhmm_text IS NULL OR hhmm_text = '' THEN RETURN NULL; END IF;

    -- BTS sometimes formats HHMM as '855.00'; strip the decimal portion.
    hhmm_text := SPLIT_PART(hhmm_text, '.', 1);
    hhmm_text := LPAD(hhmm_text, 4, '0');

    IF hhmm_text = '2400' THEN
        RETURN ((date_text::DATE + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE 'UTC');
    END IF;

    RETURN (TO_TIMESTAMP(date_text || ' ' || hhmm_text, 'YYYY-MM-DD HH24MI')
            AT TIME ZONE 'UTC');
END;
$$;

COMMENT ON FUNCTION hhmm_to_ts(TEXT, TEXT) IS
    'Combine BTS flight_date + HHMM string into UTC timestamp. NULL on empty input. 2400 → midnight next day.';
