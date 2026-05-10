-- =========================================================
-- 008_schema_flights.sql
--
-- Cleaned flight records, one row per scheduled flight in
-- the BTS On-Time data. Populated by refresh_flights().
--
-- FKs to airlines, airports (via origin and dest) — flights
-- referencing airports/airlines outside our dimension tables
-- are filtered out by the cleaning procedure rather than
-- causing FK violations.
-- =========================================================

CREATE TABLE IF NOT EXISTS flights (
    flight_id              BIGSERIAL PRIMARY KEY,
    flight_date            DATE NOT NULL,
    airline_code           VARCHAR(10) NOT NULL REFERENCES airlines(airline_code),
    origin_airport_code    CHAR(3) NOT NULL REFERENCES airports(airport_code),
    dest_airport_code      CHAR(3) NOT NULL REFERENCES airports(airport_code),

    -- Proper timestamps for joins to weather_hourly
    scheduled_departure    TIMESTAMPTZ,
    actual_departure       TIMESTAMPTZ,
    scheduled_arrival      TIMESTAMPTZ,
    actual_arrival         TIMESTAMPTZ,

    -- BTS HHMM (kept for fidelity)
    scheduled_dep_time     SMALLINT,
    actual_dep_time        SMALLINT,
    scheduled_arr_time     SMALLINT,
    actual_arr_time        SMALLINT,

    -- Delay & status
    dep_delay_minutes      DECIMAL,
    dep_del15              BOOLEAN,
    arr_delay_minutes      DECIMAL,
    arr_del15              BOOLEAN,
    cancelled              BOOLEAN NOT NULL DEFAULT FALSE,
    cancellation_code      CHAR(1)
                           CHECK (cancellation_code IS NULL
                                  OR cancellation_code IN ('A','B','C','D')),
    distance_miles         DECIMAL CHECK (distance_miles >= 0),

    -- Per-reason delay breakdown (BTS-faithful)
    carrier_delay          DECIMAL,
    weather_delay          DECIMAL,
    nas_delay              DECIMAL,
    security_delay         DECIMAL,
    late_aircraft_delay    DECIMAL
);

-- Indexes that match the query patterns we'll actually use
CREATE INDEX IF NOT EXISTS idx_flights_date              ON flights (flight_date);
CREATE INDEX IF NOT EXISTS idx_flights_origin_date       ON flights (origin_airport_code, flight_date);
CREATE INDEX IF NOT EXISTS idx_flights_dest_date         ON flights (dest_airport_code,   flight_date);
CREATE INDEX IF NOT EXISTS idx_flights_airline           ON flights (airline_code);
CREATE INDEX IF NOT EXISTS idx_flights_scheduled_dep_ts  ON flights (scheduled_departure);

COMMENT ON TABLE  flights                  IS 'Cleaned flight records (origin: BTS On-Time Performance)';
COMMENT ON COLUMN flights.scheduled_departure IS 'flight_date + CRSDepTime, in UTC; joins to weather_hourly';
COMMENT ON COLUMN flights.cancellation_code   IS 'A=carrier, B=weather, C=NAS, D=security; NULL when cancelled=false';
