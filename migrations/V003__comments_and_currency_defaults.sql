-- English comments (replace any Russian or outdated text); default currency USD.

COMMENT ON TABLE users IS
    'App user record linked to AWS Cognito via cognito_sub. Auth tokens issued by Cognito; no password stored here.';

COMMENT ON COLUMN users.cognito_sub IS
    'Cognito User Pool "sub" claim — primary identity key';

COMMENT ON COLUMN users.role IS
    'Single user role (RBAC); must match Cognito group';

COMMENT ON COLUMN venues.address_id IS
    'Physical venue address; row in addresses, typically user_id = owner_id';

COMMENT ON TABLE venue_opening_hours IS
    'Venue opening hours. is_open on venues is a manual toggle for accepting orders now; this table is the regular schedule for display and for checking whether the venue is open by schedule.';

COMMENT ON COLUMN menu_items.is_active IS
    'Whether the dish is offered for sale at this venue at all (catalog listing, not day-to-day stock).';

COMMENT ON COLUMN orders.courier_id IS
    'Current courier assigned to the order; assignment and reassignments are recorded in order_status_history (actor_id, actor_type = COURIER).';

COMMENT ON TABLE flyway_pipeline_check IS
    'CI smoke test from V001; safe to drop when the pipeline is verified.';

COMMENT ON COLUMN notification_log.event_id IS
    'Idempotency key for one send attempt (unique per channel and recipient); reuse on SQS retry to skip duplicate delivery.';

ALTER TABLE menu_items ALTER COLUMN currency SET DEFAULT 'USD';
ALTER TABLE orders ALTER COLUMN currency SET DEFAULT 'USD';
ALTER TABLE payments ALTER COLUMN currency SET DEFAULT 'USD';
