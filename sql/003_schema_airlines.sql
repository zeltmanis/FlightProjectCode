-- =========================================================
-- 003_schema_airlines.sql
--
-- Reference / dimension table — one row per airline that
-- appears in the BTS On-Time data.
--
-- Populated by refresh_airlines() — distinct codes from
-- staging.flights_raw, joined to a small in-procedure name
-- lookup for the major US carriers.
-- =========================================================

CREATE TABLE IF NOT EXISTS airlines (
    airline_code  VARCHAR(10) PRIMARY KEY,
    name          VARCHAR
);

COMMENT ON TABLE  airlines              IS 'US airlines that appear in BTS On-Time Performance data';
COMMENT ON COLUMN airlines.airline_code IS 'IATA code (e.g. AA, DL, 9E)';
COMMENT ON COLUMN airlines.name         IS 'Human-readable name; NULL for codes not in our lookup';
