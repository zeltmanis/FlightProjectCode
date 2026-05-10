-- =========================================================
-- 010_schema_routes.sql
--
-- Reference / dimension table — one row per (origin, dest)
-- pair that appears in flights. Derived, not ingested.
--
-- Used by predictions: rather than predicting per-flight,
-- algorithms predict per-route per-day, so each prediction
-- gets a stable route_id reference.
-- =========================================================

CREATE TABLE IF NOT EXISTS routes (
    route_id              BIGSERIAL PRIMARY KEY,
    origin_airport_code   CHAR(3) NOT NULL REFERENCES airports(airport_code),
    dest_airport_code     CHAR(3) NOT NULL REFERENCES airports(airport_code),
    UNIQUE (origin_airport_code, dest_airport_code)
);

CREATE INDEX IF NOT EXISTS idx_routes_origin ON routes (origin_airport_code);
CREATE INDEX IF NOT EXISTS idx_routes_dest   ON routes (dest_airport_code);

COMMENT ON TABLE routes IS
    'Distinct (origin, dest) pairs from flights — derived dimension table';
