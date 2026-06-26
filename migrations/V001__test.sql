-- Smoke test: первый прогон Flyway / GitHub Action.
-- Должна накатиться до V002__initial_schema.sql.

CREATE TABLE flyway_pipeline_check (
    applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO flyway_pipeline_check DEFAULT VALUES;

COMMENT ON TABLE flyway_pipeline_check IS 'CI smoke test; можно удалить таблицу позже вместе с этой миграцией';
