-- =========================================================
-- 001_schema_airports.sql
--
-- Reference / dimension table — one row per US airport that
-- BTS could ever reference (large_airport + medium_airport
-- with a published IATA code).
--
-- Populated by refresh_airports() from staging.airports_raw.
-- =========================================================

CREATE TABLE IF NOT EXISTS airports (
    airport_code  CHAR(3)  PRIMARY KEY,
    icao_code     VARCHAR(4),
    name          VARCHAR NOT NULL,
    city          VARCHAR,
    state         CHAR(2),
    latitude      DECIMAL  CHECK (latitude  BETWEEN  -90 AND  90),
    longitude     DECIMAL  CHECK (longitude BETWEEN -180 AND 180),
    timezone      VARCHAR
);

COMMENT ON TABLE  airports                IS 'Cleaned US airport dimension (origin: OurAirports CSV)';
COMMENT ON COLUMN airports.airport_code   IS 'IATA code, uppercased; e.g. ATL';
COMMENT ON COLUMN airports.state          IS 'Two-letter US state, parsed from iso_region (US-CA → CA)';
COMMENT ON COLUMN airports.timezone       IS 'IANA timezone, e.g. America/New_York; populated later';
