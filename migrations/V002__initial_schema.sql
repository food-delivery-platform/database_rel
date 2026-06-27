-- =============================================================================
-- Food Delivery Platform — relational schema (PostgreSQL / Supabase)
-- Based on docs/ARCHITECTURE.md
--
-- Auth: AWS Cognito User Pool. This DB stores app profile & business data;
--       passwords and primary identity live in Cognito (link via cognito_sub).
--
-- NOT in this file:
--   • DynamoDB — courier_locations, order_events (high-throughput append log)
--   • MongoDB  — sessions, catalog_cache, active_orders cache
--   • AI/knowledge base (pgvector) — see schema_knowledge.sql (later)
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "citext";

-- =============================================================================
-- ENUMS
-- =============================================================================

CREATE TYPE user_role AS ENUM (
    'CUSTOMER',
    'RESTAURANT',
    'SHOP',
    'COURIER',
    'ADMIN',
    'OPS'
    );

CREATE TYPE venue_type AS ENUM (
    'RESTAURANT',
    'SHOP'
    );

-- Order lifecycle.
-- В ARCHITECTURE.md (§5) используются более короткие имена — маппинг:
--   AWAITING_PAYMENT, AWAITING_RESTAURANT  →  PENDING
--   RESTAURANT_ACCEPTED                    →  CONFIRMED
--   PREPARING                              →  PREPARING
--   READY_FOR_PICKUP                       →  READY
--   PICKED_UP                              →  PICKED_UP
--   EN_ROUTE                               →  ON_THE_WAY
--   DELIVERED                              →  DELIVERED
--   CANCELLED                              →  CANCELLED
--   DELIVERY_FAILED                        →  FAILED
-- PENDING в архитектуре объединяет «ждём оплату» и «ждём ресторан»; здесь разделено для ясности.
CREATE TYPE order_status AS ENUM (
    'AWAITING_PAYMENT',      -- ARCHITECTURE: PENDING (до успешной оплаты)
    'AWAITING_RESTAURANT',   -- ARCHITECTURE: PENDING (оплата прошла, ждём ресторан, §14 Step Functions: Wait for restaurant)
    'RESTAURANT_ACCEPTED',   -- ARCHITECTURE: CONFIRMED (ресторан принял, order.confirmed)
    'PREPARING',             -- ARCHITECTURE: PREPARING
    'READY_FOR_PICKUP',      -- ARCHITECTURE: READY
    'PICKED_UP',             -- ARCHITECTURE: PICKED_UP
    'EN_ROUTE',              -- ARCHITECTURE: ON_THE_WAY
    'DELIVERED',             -- ARCHITECTURE: DELIVERED
    'CANCELLED',             -- ARCHITECTURE: CANCELLED
    'DELIVERY_FAILED'        -- ARCHITECTURE: FAILED
    );

-- Payment lifecycle (Payment Service, Stripe).
-- CUSTOMER_ACTION_REQUIRED ≈ Stripe status requires_action (3D Secure и т.п.).
CREATE TYPE payment_status AS ENUM (
    'PENDING',                      -- платёж создан, идёт обработка
    'CUSTOMER_ACTION_REQUIRED',     -- Stripe requires_action: 3DS, подтверждение в банке
    'SUCCEEDED',                    -- ARCHITECTURE: payment.confirmed
    'FAILED',                       -- ARCHITECTURE: payment.failed
    'REFUNDED',                     -- полный возврат (отмена заказа, §14 refund flow)
    'PARTIALLY_REFUNDED'            -- частичный возврат
    );

-- Статус предложения доставки конкретному курьеру (Delivery Service, Assignment Engine, §15).
CREATE TYPE assignment_status AS ENUM (
    'OFFERED',    -- заказ предложен курьеру (nearest available courier)
    'ACCEPTED',   -- курьер принял задачу
    'DECLINED',   -- курьер отклонил
    'EXPIRED',    -- курьер не ответил в срок
    'COMPLETED',  -- доставка по этому назначению завершена
    'CANCELLED'   -- назначение отменено (переназначение другому курьеру, §15 graceful shutdown)
    );

CREATE TYPE notification_channel AS ENUM (
    'SMS',
    'EMAIL',
    'PUSH'
    );

CREATE TYPE notification_status AS ENUM (
    'PENDING',
    'SENT',
    'FAILED',
    'SKIPPED'
    );

-- =============================================================================
-- USERS (Cognito-linked)
-- =============================================================================

-- Local mirror of Cognito users. Created/updated on first login or post-confirmation trigger.
-- cognito_sub = Cognito attribute "sub" (immutable).
CREATE TABLE users
(
    id            uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    cognito_sub   text        NOT NULL UNIQUE,
    email         citext,
    phone         text,
    display_name  text,
    avatar_url    text,
    role          user_role   NOT NULL DEFAULT 'CUSTOMER',
    is_active     boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,

    CONSTRAINT users_email_unique UNIQUE (email)
);

COMMENT ON TABLE users IS
    'App user record linked to AWS Cognito via cognito_sub. Auth tokens issued by Cognito; no password stored here.';
COMMENT ON COLUMN users.cognito_sub IS 'Cognito User Pool "sub" claim — primary identity key';
COMMENT ON COLUMN users.role IS 'Единственная роль пользователя (RBAC); должна совпадать с группой в Cognito';

CREATE TABLE addresses
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label       text, -- "Home", "Work"
    line1       text        NOT NULL,
    line2       text,
    city        text        NOT NULL,
    district    text,
    postal_code text,
    country     text        NOT NULL DEFAULT 'TR',
    latitude    numeric(10, 7),
    longitude   numeric(10, 7),
    is_default  boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_addresses_user_id ON addresses (user_id);
CREATE INDEX idx_addresses_city ON addresses (city);

-- =============================================================================
-- CATALOG (restaurants + shops)
-- =============================================================================

-- Unified venue: 300 restaurants + 10 000 shops (architecture scale)
CREATE TABLE venues
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    owner_id    uuid        NOT NULL REFERENCES users (id),
    address_id  uuid        NOT NULL REFERENCES addresses (id),
    venue_type  venue_type  NOT NULL,
    name        text        NOT NULL,
    slug        text UNIQUE,
    description text,
    cuisine_tags text[]              DEFAULT '{}',
    is_open     boolean     NOT NULL DEFAULT true,
    rating      numeric(3, 2) CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5)),
    image_url   text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    UNIQUE (address_id)
);

COMMENT ON COLUMN venues.address_id IS
    'Физический адрес заведения; строка в addresses, обычно user_id = owner_id';

CREATE INDEX idx_venues_owner_id ON venues (owner_id);
CREATE INDEX idx_venues_address_id ON venues (address_id);
CREATE INDEX idx_venues_type_open ON venues (venue_type, is_open);

-- Расписание работы по дням недели (Catalog Service).
-- day_of_week: ISO 8601 — 1 = понедельник, 7 = воскресенье.
-- Выходной = нет строки для этого дня. Несколько интервалов в день — несколько строк (будущее: slot).
CREATE TABLE venue_opening_hours
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    venue_id    uuid        NOT NULL REFERENCES venues (id) ON DELETE CASCADE,
    day_of_week smallint    NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
    opens_at    time        NOT NULL,
    closes_at   time        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CHECK (closes_at > opens_at)
);

CREATE INDEX idx_venue_opening_hours_venue_id ON venue_opening_hours (venue_id);
CREATE UNIQUE INDEX idx_venue_opening_hours_venue_day_opens
    ON venue_opening_hours (venue_id, day_of_week, opens_at);

COMMENT ON TABLE venue_opening_hours IS
    'Часы работы заведения. is_open на venues — ручной переключатель «принимаем заказы сейчас»; '
    'эта таблица — регулярное расписание для отображения и проверки «открыт ли по расписанию».';

-- categories for menu_items (dishes).
CREATE TABLE categories
(
    id         uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    venue_id   uuid REFERENCES venues (id) ON DELETE CASCADE, -- NULL = global category
    name       text        NOT NULL,
    sort_order int         NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE NULLS NOT DISTINCT (venue_id, name)
);

CREATE INDEX idx_categories_venue_id ON categories (venue_id);

CREATE TABLE menu_items
(
    id           uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    venue_id     uuid           NOT NULL REFERENCES venues (id) ON DELETE CASCADE,
    category_id  uuid           REFERENCES categories (id) ON DELETE SET NULL,
    name         text           NOT NULL,
    description  text,
    price        numeric(10, 2) NOT NULL CHECK (price >= 0),
    currency     char(3)        NOT NULL DEFAULT 'TRY',
    -- image_url    text,  -- for future
    is_available boolean        NOT NULL DEFAULT true,
    allergens    text[]                  DEFAULT '{}',
    sort_order   int            NOT NULL DEFAULT 0,
    created_at   timestamptz    NOT NULL DEFAULT now(),
    updated_at   timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX idx_menu_items_venue_id ON menu_items (venue_id);
CREATE INDEX idx_menu_items_category_id ON menu_items (category_id);
CREATE INDEX idx_menu_items_available ON menu_items (venue_id, is_available);

-- =============================================================================
-- COURIERS & DELIVERY ASSIGNMENTS
-- =============================================================================
-- Delivery Service (§15): Assignment Engine ищет ближайшего свободного курьера
-- после order.confirmed (RESTAURANT_ACCEPTED) и создаёт запись в assignments.
-- Это не статус заказа, а связь «заказ ↔ курьер» и результат переговоров с курьером.
-- Живой GPS курьера — в DynamoDB courier_locations, не здесь.

CREATE TABLE couriers
(
    id               uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    user_id          uuid        NOT NULL UNIQUE REFERENCES users (id) ON DELETE CASCADE,
    vehicle_type     text        NOT NULL DEFAULT 'bicycle', -- bicycle, scooter, car
    is_available     boolean     NOT NULL DEFAULT false,
    is_verified      boolean     NOT NULL DEFAULT false,
    last_lat         numeric(10, 7),                         -- coarse position; live GPS stream → DynamoDB
    last_lng         numeric(10, 7),
    last_location_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_couriers_available ON couriers (is_available) WHERE is_available = true;

-- Назначение курьера на заказ. Один заказ может иметь несколько записей,
-- если первый курьер отказался и заказ переназначили (§15 reassignment).
CREATE TABLE assignments
(
    id           uuid PRIMARY KEY           DEFAULT gen_random_uuid(),
    order_id     uuid              NOT NULL, -- FK added after orders table
    courier_id   uuid              NOT NULL REFERENCES couriers (id),
    status       assignment_status NOT NULL DEFAULT 'OFFERED',
    offered_at   timestamptz       NOT NULL DEFAULT now(),
    accepted_at  timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,

    UNIQUE (order_id, courier_id)
);

COMMENT ON TABLE assignments IS
    'Delivery Service (§4.7, §15): назначение курьера на заказ. '
    'Assignment Engine пишет сюда после order.confirmed; Stage State Machine обновляет при PICKED_UP→DELIVERED.';

CREATE INDEX idx_assignments_courier_status ON assignments (courier_id, status);
CREATE INDEX idx_assignments_order_id ON assignments (order_id);

-- =============================================================================
-- ORDERS
-- =============================================================================

CREATE TABLE orders
(
    id                               uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    customer_id                      uuid           NOT NULL REFERENCES users (id),
    venue_id                         uuid           NOT NULL REFERENCES venues (id),
    delivery_address_id              uuid           NOT NULL REFERENCES addresses (id),
    status                           order_status   NOT NULL DEFAULT 'AWAITING_PAYMENT',
    subtotal                         numeric(10, 2) NOT NULL CHECK (subtotal >= 0),
    delivery_fee                     numeric(10, 2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    total                            numeric(10, 2) NOT NULL CHECK (total >= 0),
    currency                         char(3)        NOT NULL DEFAULT 'TRY',
    special_instructions             text,
    estimated_delivery_at            timestamptz,
    restaurant_confirmation_deadline timestamptz,
    cancelled_reason                 text,
    created_at                       timestamptz    NOT NULL DEFAULT now(),
    updated_at                       timestamptz    NOT NULL DEFAULT now()
);

ALTER TABLE assignments
    ADD CONSTRAINT assignments_order_id_fkey
        FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE;

CREATE INDEX idx_orders_customer_id ON orders (customer_id);
CREATE INDEX idx_orders_venue_id ON orders (venue_id);
CREATE INDEX idx_orders_status ON orders (status);
CREATE INDEX idx_orders_created_at ON orders (created_at DESC);

-- Price snapshot at order time (menu price may change later)
CREATE TABLE order_items
(
    id                   uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    order_id             uuid           NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    menu_item_id         uuid           NOT NULL REFERENCES menu_items (id),
    quantity             int            NOT NULL CHECK (quantity > 0),
    unit_price           numeric(10, 2) NOT NULL CHECK (unit_price >= 0),
    line_total           numeric(10, 2) NOT NULL CHECK (line_total >= 0),
    special_instructions text,
    menu_item_name       text           NOT NULL, -- snapshot
    created_at           timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX idx_order_items_order_id ON order_items (order_id);

-- Relational audit trail (immutable high-volume log also in DynamoDB order_events)
CREATE TABLE order_status_history
(
    id          uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    order_id    uuid         NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    from_status order_status,
    to_status   order_status NOT NULL,
    actor_id    uuid REFERENCES users (id),             -- NULL = system
    actor_type  text         NOT NULL DEFAULT 'SYSTEM', -- CUSTOMER, RESTAURANT, COURIER, SYSTEM
    note        text,
    created_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX idx_order_status_history_order_id ON order_status_history (order_id, created_at);

-- =============================================================================
-- PAYMENTS
-- =============================================================================

CREATE TABLE payments
(
    id              uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    order_id        uuid           NOT NULL UNIQUE REFERENCES orders (id),
    provider        text           NOT NULL DEFAULT 'stripe',
    provider_ref    text,                           -- Stripe PaymentIntent id
    idempotency_key text           NOT NULL UNIQUE, -- typically order_id
    status          payment_status NOT NULL DEFAULT 'PENDING',
    amount          numeric(10, 2) NOT NULL CHECK (amount >= 0),
    currency        char(3)        NOT NULL DEFAULT 'USD',
    failure_code    text,
    failure_message text,
    paid_at         timestamptz,
    created_at      timestamptz    NOT NULL DEFAULT now(),
    updated_at      timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX idx_payments_status ON payments (status);

CREATE TABLE payment_refunds
(
    id           uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    payment_id   uuid           NOT NULL REFERENCES payments (id),
    provider_ref text,
    amount       numeric(10, 2) NOT NULL CHECK (amount > 0),
    reason       text,
    status       text           NOT NULL DEFAULT 'PENDING', -- PENDING, SUCCEEDED, FAILED
    created_at   timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX idx_payment_refunds_payment_id ON payment_refunds (payment_id);

-- =============================================================================
-- NOTIFICATIONS (audit log)
-- by email\sms
-- =============================================================================


CREATE TABLE notification_log
(
    id           uuid PRIMARY KEY              DEFAULT gen_random_uuid(),
    user_id      uuid                 NOT NULL REFERENCES users (id),
    order_id     uuid                 REFERENCES orders (id) ON DELETE SET NULL,
    event_id     text                 NOT NULL UNIQUE, -- idempotency: skip duplicate sends
    channel      notification_channel NOT NULL,
    template_key text                 NOT NULL,        -- e.g. order.confirmed
    recipient    text                 NOT NULL,        -- email or phone masked in logs if needed
    status       notification_status  NOT NULL DEFAULT 'PENDING',
    error        text,
    sent_at      timestamptz,
    created_at   timestamptz          NOT NULL DEFAULT now()
);

CREATE INDEX idx_notification_log_user_id ON notification_log (user_id);
CREATE INDEX idx_notification_log_order_id ON notification_log (order_id);

-- =============================================================================
-- MONITORING & OPS
-- =============================================================================

-- Service Level Agreement
-- Нормативы на переход из статуса в статус.
CREATE TABLE sla_thresholds
(
    id          uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    from_status order_status NOT NULL,
    to_status   order_status NOT NULL,
    max_minutes int          NOT NULL CHECK (max_minutes > 0),
    is_active   boolean      NOT NULL DEFAULT true,
    updated_at  timestamptz  NOT NULL DEFAULT now(),

    UNIQUE (from_status, to_status)
);

-- SLA thresholds(Monitoring Service, §9). Статусы — локальные имена; в §9 архитектуры:
--   AWAITING_RESTAURANT → RESTAURANT_ACCEPTED  =  PENDING → CONFIRMED (5 min)
--   RESTAURANT_ACCEPTED → READY_FOR_PICKUP     =  CONFIRMED → READY (30 min)
--   READY_FOR_PICKUP → PICKED_UP               =  READY → PICKED_UP (15 min)
--   PICKED_UP → DELIVERED                      =  PICKED_UP → DELIVERED (60 min)
INSERT INTO sla_thresholds (from_status, to_status, max_minutes)
VALUES ('AWAITING_RESTAURANT', 'RESTAURANT_ACCEPTED', 5),
       ('RESTAURANT_ACCEPTED', 'READY_FOR_PICKUP', 30),
       ('READY_FOR_PICKUP', 'PICKED_UP', 15),
       ('PICKED_UP', 'DELIVERED', 60);

-- inbox проблем для ops-команды (админы, диспетчеры).
CREATE TABLE ops_alerts
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    order_id    uuid        REFERENCES orders (id) ON DELETE SET NULL,
    alert_type  text        NOT NULL,                   -- SLA_VIOLATION, DLQ_POISON, PAYMENT_SPIKE, etc.
    severity    text        NOT NULL DEFAULT 'warning', -- info, warning, critical
    message     text        NOT NULL,
    metadata    jsonb       NOT NULL DEFAULT '{}',
    is_resolved boolean     NOT NULL DEFAULT false,
    resolved_at timestamptz,
    resolved_by uuid REFERENCES users (id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ops_alerts_unresolved ON ops_alerts (created_at DESC) WHERE is_resolved = false;

-- =============================================================================
-- ANALYTICS (pre-aggregated reports)
-- =============================================================================

CREATE TABLE analytics_daily_venue_stats
(
    id               uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    venue_id         uuid           NOT NULL REFERENCES venues (id) ON DELETE CASCADE,
    stat_date        date           NOT NULL,
    orders_count     int            NOT NULL DEFAULT 0,
    orders_delivered int            NOT NULL DEFAULT 0,
    orders_cancelled int            NOT NULL DEFAULT 0,
    gross_revenue    numeric(12, 2) NOT NULL DEFAULT 0,
    avg_order_value  numeric(10, 2),
    updated_at       timestamptz    NOT NULL DEFAULT now(),

    UNIQUE (venue_id, stat_date)
);

CREATE INDEX idx_analytics_daily_venue_date ON analytics_daily_venue_stats (stat_date DESC);

-- =============================================================================
-- updated_at helper
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS trigger AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE
    ON users
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_addresses_updated_at
    BEFORE UPDATE
    ON addresses
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_venues_updated_at
    BEFORE UPDATE
    ON venues
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_venue_opening_hours_updated_at
    BEFORE UPDATE
    ON venue_opening_hours
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_menu_items_updated_at
    BEFORE UPDATE
    ON menu_items
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_couriers_updated_at
    BEFORE UPDATE
    ON couriers
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE
    ON orders
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE
    ON payments
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
