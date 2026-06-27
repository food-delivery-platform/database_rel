-- Coarse courier position removed from PostgreSQL; live GPS stream lives in DynamoDB (courier_locations).

ALTER TABLE couriers
    DROP COLUMN IF EXISTS last_lat,
    DROP COLUMN IF EXISTS last_lng,
    DROP COLUMN IF EXISTS last_location_at;
