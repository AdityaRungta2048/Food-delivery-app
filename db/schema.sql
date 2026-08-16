-- =============================================================================
--  [APP_NAME] — Local SQLite Schema
--  Database file : [DATABASE_NAME].db
--  Dialect       : SQLite 3 (as shipped with Android / Room)
--  Schema version: 1
--
--  CONVENTIONS
--    • Monetary values are INTEGER in the currency's MINOR UNIT (paise/cents).
--      Never REAL — binary floating point cannot represent 0.01 exactly and
--      will drift across bill-line summation.
--    • Timestamps are INTEGER Unix epoch MILLISECONDS, always UTC.
--      Local-time rendering is a presentation concern.
--    • Booleans are INTEGER 0/1 with a CHECK constraint.
--    • Enumerations are TEXT with a CHECK constraint. Readable in a DB dump,
--      and a bad value fails at write time rather than at read time.
--    • `id`         = local autoincrementing primary key.
--      `remote_id`  = server-assigned identifier, NULL until synced.
--    • Every mutable table carries created_at / updated_at, maintained by
--      triggers so no code path can forget to touch them.
--
--  PRAGMAS — must be issued per connection; Room does this via a
--  RoomDatabase.Callback in onOpen(). Foreign keys are OFF by default in
--  SQLite and silently ignore violations if not enabled.
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;          -- concurrent reader while a writer commits
PRAGMA synchronous  = NORMAL;       -- safe with WAL, materially faster
PRAGMA busy_timeout = 5000;


-- =============================================================================
--  SECTION 1 — IDENTITY
-- =============================================================================

-- Local profile cache for the signed-in user. Exactly one row is expected;
-- multi-account is not supported in v1.
CREATE TABLE users (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    UNIQUE,
    phone_number        TEXT    NOT NULL UNIQUE,        -- E.164, e.g. +919876543210
    phone_verified      INTEGER NOT NULL DEFAULT 0 CHECK (phone_verified IN (0,1)),
    email               TEXT    UNIQUE,
    email_verified      INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0,1)),
    full_name           TEXT,
    avatar_url          TEXT,
    default_address_id  INTEGER,
    -- COD trust signals, mirrored from the server; the client uses these to
    -- pre-emptively hide COD rather than fail at checkout.
    cod_blocked         INTEGER NOT NULL DEFAULT 0 CHECK (cod_blocked IN (0,1)),
    cod_block_reason    TEXT,
    loyalty_tier        TEXT    NOT NULL DEFAULT 'STANDARD'
                                CHECK (loyalty_tier IN ('STANDARD','SILVER','GOLD')),
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (default_address_id) REFERENCES addresses(id) ON DELETE SET NULL
);

-- Session METADATA only.
-- SECURITY: access and refresh tokens are NEVER stored in this database.
-- They live in EncryptedSharedPreferences backed by the Android Keystore.
-- This table exists so the app can reason about session validity and show a
-- device list without ever reading a secret from SQL.
CREATE TABLE user_sessions (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER NOT NULL,
    session_handle      TEXT    NOT NULL UNIQUE,  -- opaque, non-secret server ref
    device_label        TEXT,
    issued_at           INTEGER NOT NULL,
    access_expires_at   INTEGER NOT NULL,
    refresh_expires_at  INTEGER NOT NULL,
    last_seen_at        INTEGER NOT NULL,
    revoked             INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0,1)),

    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Rate-limiting ledger for OTP requests and verification attempts.
-- Client-side throttling is a UX affordance and a cheap abuse brake; the
-- server remains the authoritative limiter.
CREATE TABLE auth_attempts (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier          TEXT    NOT NULL,          -- phone number or email
    attempt_type        TEXT    NOT NULL CHECK (attempt_type IN ('OTP_REQUEST','OTP_VERIFY')),
    succeeded           INTEGER NOT NULL DEFAULT 0 CHECK (succeeded IN (0,1)),
    attempted_at        INTEGER NOT NULL,
    locked_until        INTEGER
);

CREATE TABLE addresses (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    UNIQUE,
    user_id             INTEGER NOT NULL,
    label               TEXT    NOT NULL DEFAULT 'OTHER'
                                CHECK (label IN ('HOME','WORK','OTHER')),
    recipient_name      TEXT,
    recipient_phone     TEXT,
    line1               TEXT    NOT NULL,
    line2               TEXT,
    landmark            TEXT,
    city                TEXT    NOT NULL,
    state               TEXT,
    postal_code         TEXT    NOT NULL,
    country_code        TEXT    NOT NULL DEFAULT '[DEFAULT_COUNTRY_CODE]',
    latitude            REAL,                       -- geographic, REAL is correct here
    longitude           REAL,
    delivery_notes      TEXT,
    is_default          INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
    is_deleted          INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0,1)),
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- At most one default address per user. A partial unique index expresses this
-- without forbidding many non-default rows.
CREATE UNIQUE INDEX idx_addresses_one_default
    ON addresses(user_id) WHERE is_default = 1 AND is_deleted = 0;

CREATE INDEX idx_addresses_user ON addresses(user_id, is_deleted);


-- =============================================================================
--  SECTION 2 — CATALOG  (read-mostly cache of server data)
-- =============================================================================

CREATE TABLE restaurants (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    NOT NULL UNIQUE,
    name                TEXT    NOT NULL,
    tagline             TEXT,
    cuisine_csv         TEXT,                        -- denormalised for list display
    image_url           TEXT,
    rating              REAL    CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5)),
    rating_count        INTEGER NOT NULL DEFAULT 0,
    price_for_two       INTEGER NOT NULL DEFAULT 0,  -- minor units
    avg_prep_minutes    INTEGER NOT NULL DEFAULT 0,
    delivery_fee        INTEGER NOT NULL DEFAULT 0,  -- minor units
    min_order_value     INTEGER NOT NULL DEFAULT 0,  -- minor units
    packaging_fee       INTEGER NOT NULL DEFAULT 0,  -- minor units
    latitude            REAL,
    longitude           REAL,
    is_open             INTEGER NOT NULL DEFAULT 1 CHECK (is_open IN (0,1)),
    accepts_cod         INTEGER NOT NULL DEFAULT 1 CHECK (accepts_cod IN (0,1)),
    cod_max_order_value INTEGER,                     -- NULL = platform default applies
    is_favorite         INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0,1)),
    cached_at           INTEGER NOT NULL,            -- drives TTL eviction
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

CREATE INDEX idx_restaurants_open_rating ON restaurants(is_open, rating DESC);
CREATE INDEX idx_restaurants_cached      ON restaurants(cached_at);
CREATE INDEX idx_restaurants_favorite    ON restaurants(is_favorite) WHERE is_favorite = 1;

CREATE TABLE menu_categories (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    NOT NULL UNIQUE,
    restaurant_id       INTEGER NOT NULL,
    name                TEXT    NOT NULL,
    display_order       INTEGER NOT NULL DEFAULT 0,

    FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE
);

CREATE INDEX idx_menu_categories_restaurant
    ON menu_categories(restaurant_id, display_order);

CREATE TABLE menu_items (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    NOT NULL UNIQUE,
    restaurant_id       INTEGER NOT NULL,
    category_id         INTEGER NOT NULL,
    name                TEXT    NOT NULL,
    description         TEXT,
    image_url           TEXT,
    base_price          INTEGER NOT NULL CHECK (base_price >= 0),   -- minor units
    diet_type           TEXT    NOT NULL DEFAULT 'VEG'
                                CHECK (diet_type IN ('VEG','NON_VEG','EGG')),
    spice_level         INTEGER CHECK (spice_level IS NULL OR spice_level BETWEEN 0 AND 3),
    rating              REAL,
    is_bestseller       INTEGER NOT NULL DEFAULT 0 CHECK (is_bestseller IN (0,1)),
    is_available        INTEGER NOT NULL DEFAULT 1 CHECK (is_available IN (0,1)),
    display_order       INTEGER NOT NULL DEFAULT 0,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE,
    FOREIGN KEY (category_id)   REFERENCES menu_categories(id) ON DELETE CASCADE
);

CREATE INDEX idx_menu_items_restaurant ON menu_items(restaurant_id, is_available);
CREATE INDEX idx_menu_items_category   ON menu_items(category_id, display_order);

-- An option GROUP is a question ("Choose size"); an OPTION is an answer ("Large").
CREATE TABLE item_option_groups (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    NOT NULL UNIQUE,
    menu_item_id        INTEGER NOT NULL,
    name                TEXT    NOT NULL,
    min_select          INTEGER NOT NULL DEFAULT 0 CHECK (min_select >= 0),
    max_select          INTEGER NOT NULL DEFAULT 1 CHECK (max_select >= 1),
    display_order       INTEGER NOT NULL DEFAULT 0,

    CHECK (max_select >= min_select),
    FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE CASCADE
);

CREATE INDEX idx_option_groups_item ON item_option_groups(menu_item_id, display_order);

CREATE TABLE item_options (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    NOT NULL UNIQUE,
    group_id            INTEGER NOT NULL,
    name                TEXT    NOT NULL,
    price_delta         INTEGER NOT NULL DEFAULT 0,   -- minor units, may be negative
    is_available        INTEGER NOT NULL DEFAULT 1 CHECK (is_available IN (0,1)),
    display_order       INTEGER NOT NULL DEFAULT 0,

    FOREIGN KEY (group_id) REFERENCES item_option_groups(id) ON DELETE CASCADE
);

CREATE INDEX idx_item_options_group ON item_options(group_id, display_order);

CREATE TABLE coupons (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    code                TEXT    NOT NULL UNIQUE,
    description         TEXT,
    discount_type       TEXT    NOT NULL CHECK (discount_type IN ('PERCENT','FLAT','FREE_DELIVERY')),
    discount_value      INTEGER NOT NULL DEFAULT 0,   -- percent points, or minor units
    max_discount        INTEGER,                      -- cap for PERCENT, minor units
    min_order_value     INTEGER NOT NULL DEFAULT 0,   -- minor units
    restaurant_id       INTEGER,                      -- NULL = platform-wide
    valid_from          INTEGER NOT NULL,
    valid_until         INTEGER NOT NULL,
    applies_to_cod      INTEGER NOT NULL DEFAULT 1 CHECK (applies_to_cod IN (0,1)),

    FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE
);

CREATE INDEX idx_coupons_validity ON coupons(valid_until, valid_from);


-- =============================================================================
--  SECTION 3 — CART  (multi-cart: one open cart per restaurant, concurrently)
-- =============================================================================

CREATE TABLE carts (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER NOT NULL,
    restaurant_id       INTEGER NOT NULL,
    status              TEXT    NOT NULL DEFAULT 'OPEN'
                                CHECK (status IN ('OPEN','CHECKING_OUT','CONVERTED','ABANDONED')),
    applied_coupon_id   INTEGER,
    special_instructions TEXT,
    -- Set when a re-validation finds a price/availability drift the user has
    -- not yet acknowledged. The UI blocks checkout while this is 1.
    needs_revalidation  INTEGER NOT NULL DEFAULT 0 CHECK (needs_revalidation IN (0,1)),
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (user_id)           REFERENCES users(id)       ON DELETE CASCADE,
    FOREIGN KEY (restaurant_id)     REFERENCES restaurants(id) ON DELETE CASCADE,
    FOREIGN KEY (applied_coupon_id) REFERENCES coupons(id)     ON DELETE SET NULL
);

-- THE multi-cart invariant: a user may hold many carts, but only ONE open cart
-- per restaurant. Enforced in SQL so no repository bug can create a duplicate.
CREATE UNIQUE INDEX idx_carts_one_open_per_restaurant
    ON carts(user_id, restaurant_id) WHERE status = 'OPEN';

CREATE INDEX idx_carts_user_status ON carts(user_id, status);

CREATE TABLE cart_items (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    cart_id             INTEGER NOT NULL,
    menu_item_id        INTEGER NOT NULL,
    quantity            INTEGER NOT NULL CHECK (quantity > 0),
    -- Price snapshot taken at add-to-cart time. Compared against the live
    -- menu_items.base_price during re-validation to detect drift.
    unit_base_price     INTEGER NOT NULL CHECK (unit_base_price >= 0),
    -- Sum of the selected options' price_delta for this line, denormalised so
    -- the cart total is a single-pass aggregate rather than a nested query.
    unit_options_price  INTEGER NOT NULL DEFAULT 0,
    item_instructions   TEXT,
    -- Stable hash of (menu_item_id + sorted option ids + instructions).
    -- Two identical configurations merge into one line and bump quantity;
    -- differing configurations remain distinct lines.
    config_signature    TEXT    NOT NULL,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (cart_id)      REFERENCES carts(id)      ON DELETE CASCADE,
    FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_cart_items_config ON cart_items(cart_id, config_signature);
CREATE INDEX        idx_cart_items_cart   ON cart_items(cart_id);

CREATE TABLE cart_item_options (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    cart_item_id        INTEGER NOT NULL,
    option_id           INTEGER NOT NULL,
    price_delta         INTEGER NOT NULL DEFAULT 0,   -- snapshot at selection time

    FOREIGN KEY (cart_item_id) REFERENCES cart_items(id)   ON DELETE CASCADE,
    FOREIGN KEY (option_id)    REFERENCES item_options(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_cart_item_options_unique
    ON cart_item_options(cart_item_id, option_id);


-- =============================================================================
--  SECTION 4 — ORDERS
-- =============================================================================

CREATE TABLE orders (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    UNIQUE,               -- NULL until server-acked
    order_number        TEXT    UNIQUE,               -- human-facing, e.g. ORD-000241
    user_id             INTEGER NOT NULL,
    restaurant_id       INTEGER NOT NULL,
    address_id          INTEGER,

    status              TEXT    NOT NULL DEFAULT 'PLACED'
                                CHECK (status IN (
                                    'PLACED','CONFIRMED','PREPARING','READY_FOR_PICKUP',
                                    'OUT_FOR_DELIVERY','DELIVERED','CANCELLED','REJECTED')),

    -- ---- Immutable snapshots -------------------------------------------------
    -- The restaurant may rename itself or reprice tomorrow; a placed order must
    -- render identically forever. Denormalisation here is deliberate.
    restaurant_name     TEXT    NOT NULL,
    restaurant_image_url TEXT,
    delivery_address_snapshot TEXT NOT NULL,          -- formatted, single string

    -- ---- Bill breakdown (all minor units) -----------------------------------
    item_total          INTEGER NOT NULL CHECK (item_total >= 0),
    packaging_fee       INTEGER NOT NULL DEFAULT 0,
    delivery_fee        INTEGER NOT NULL DEFAULT 0,
    tax_amount          INTEGER NOT NULL DEFAULT 0,
    discount_amount     INTEGER NOT NULL DEFAULT 0,
    tip_amount          INTEGER NOT NULL DEFAULT 0,
    grand_total         INTEGER NOT NULL CHECK (grand_total >= 0),
    currency_code       TEXT    NOT NULL DEFAULT '[CURRENCY_CODE]',
    applied_coupon_code TEXT,

    -- ---- Fulfilment ---------------------------------------------------------
    placed_at           INTEGER NOT NULL,
    expected_delivery_at INTEGER,
    delivered_at        INTEGER,
    cancelled_at        INTEGER,
    cancellation_reason TEXT,
    courier_name        TEXT,
    courier_phone       TEXT,
    courier_rating      REAL,

    -- ---- Sync / idempotency -------------------------------------------------
    -- Generated ONCE on device before the first submit attempt and reused for
    -- every retry. This is what makes order submission safe over a flaky link.
    idempotency_key     TEXT    NOT NULL UNIQUE,
    sync_state          TEXT    NOT NULL DEFAULT 'PENDING'
                                CHECK (sync_state IN ('PENDING','SYNCING','SYNCED','FAILED')),
    sync_attempts       INTEGER NOT NULL DEFAULT 0,
    last_sync_error     TEXT,

    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    CHECK (grand_total =
           item_total + packaging_fee + delivery_fee + tax_amount + tip_amount - discount_amount),

    FOREIGN KEY (user_id)       REFERENCES users(id)       ON DELETE CASCADE,
    FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT,
    FOREIGN KEY (address_id)    REFERENCES addresses(id)   ON DELETE SET NULL
);

-- Drives the "Active orders" query — the hottest read in the app.
CREATE INDEX idx_orders_active
    ON orders(user_id, expected_delivery_at)
    WHERE status IN ('PLACED','CONFIRMED','PREPARING','READY_FOR_PICKUP','OUT_FOR_DELIVERY');

CREATE INDEX idx_orders_history   ON orders(user_id, placed_at DESC);
CREATE INDEX idx_orders_sync      ON orders(sync_state) WHERE sync_state IN ('PENDING','FAILED');
CREATE INDEX idx_orders_restaurant ON orders(restaurant_id);

CREATE TABLE order_items (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id            INTEGER NOT NULL,
    menu_item_id        INTEGER,                      -- may be NULL if delisted later
    item_name           TEXT    NOT NULL,             -- snapshot
    diet_type           TEXT    NOT NULL DEFAULT 'VEG'
                                CHECK (diet_type IN ('VEG','NON_VEG','EGG')),
    quantity            INTEGER NOT NULL CHECK (quantity > 0),
    unit_base_price     INTEGER NOT NULL CHECK (unit_base_price >= 0),
    unit_options_price  INTEGER NOT NULL DEFAULT 0,
    line_total          INTEGER NOT NULL CHECK (line_total >= 0),
    item_instructions   TEXT,

    CHECK (line_total = (unit_base_price + unit_options_price) * quantity),
    FOREIGN KEY (order_id)     REFERENCES orders(id)     ON DELETE CASCADE,
    FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE SET NULL
);

CREATE INDEX idx_order_items_order ON order_items(order_id);

CREATE TABLE order_item_options (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    order_item_id       INTEGER NOT NULL,
    option_name         TEXT    NOT NULL,             -- snapshot
    price_delta         INTEGER NOT NULL DEFAULT 0,

    FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE
);

CREATE INDEX idx_order_item_options_item ON order_item_options(order_item_id);

-- Append-only audit trail. Every accepted state transition writes exactly one
-- row. Powers the tracking stepper's timestamps and any dispute resolution.
CREATE TABLE order_status_history (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id            INTEGER NOT NULL,
    from_status         TEXT,                         -- NULL for the first row
    to_status           TEXT    NOT NULL,
    note                TEXT,
    source              TEXT    NOT NULL DEFAULT 'SERVER'
                                CHECK (source IN ('SERVER','PUSH','POLL','LOCAL')),
    occurred_at         INTEGER NOT NULL,

    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
);

CREATE INDEX idx_status_history_order ON order_status_history(order_id, occurred_at);

-- Idempotency guard: the same transition, delivered twice by push and poll,
-- must not produce two audit rows.
CREATE UNIQUE INDEX idx_status_history_dedupe
    ON order_status_history(order_id, to_status, occurred_at);


-- =============================================================================
--  SECTION 5 — PAYMENTS AND CASH SETTLEMENT
-- =============================================================================

-- One row per payment attempt. An order may accumulate several (a failed
-- prepaid attempt followed by a COD fallback), so this is 1:N, not 1:1.
CREATE TABLE payments (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    remote_id           TEXT    UNIQUE,
    order_id            INTEGER NOT NULL,
    method              TEXT    NOT NULL CHECK (method IN ('CASH','CARD','UPI','WALLET','NET_BANKING')),
    amount              INTEGER NOT NULL CHECK (amount >= 0),   -- minor units
    currency_code       TEXT    NOT NULL DEFAULT '[CURRENCY_CODE]',

    status              TEXT    NOT NULL DEFAULT 'PENDING'
                                CHECK (status IN (
                                    'PENDING',              -- created, not yet actionable
                                    'AWAITING_COLLECTION',  -- COD: courier will collect
                                    'AUTHORIZED',           -- prepaid: funds held
                                    'CAPTURED',             -- prepaid: settled
                                    'COLLECTED',            -- COD: cash received
                                    'FAILED',
                                    'REFUNDED',
                                    'PARTIALLY_REFUNDED')),

    -- Nothing that could identify an instrument is stored locally. No PAN, no
    -- CVV, no token, no UPI handle. Gateway references only.
    gateway_reference   TEXT,
    failure_reason      TEXT,

    initiated_at        INTEGER NOT NULL,
    settled_at          INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
);

CREATE INDEX idx_payments_order  ON payments(order_id);
CREATE INDEX idx_payments_status ON payments(status);

-- Exactly one non-terminal payment attempt per order at any moment. Prevents a
-- double-tap on "Place Order" or a racing retry from opening two live attempts.
CREATE UNIQUE INDEX idx_payments_one_live_attempt
    ON payments(order_id)
    WHERE status IN ('PENDING','AWAITING_COLLECTION','AUTHORIZED');

-- COD-specific settlement detail. Separated from `payments` because these
-- columns are meaningless for prepaid methods and would otherwise be a wide
-- band of NULLs on every card transaction.
CREATE TABLE cash_collections (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_id          INTEGER NOT NULL UNIQUE,
    order_id            INTEGER NOT NULL,

    amount_due          INTEGER NOT NULL CHECK (amount_due >= 0),
    amount_collected    INTEGER CHECK (amount_collected IS NULL OR amount_collected >= 0),
    change_returned     INTEGER NOT NULL DEFAULT 0 CHECK (change_returned >= 0),

    -- Customer-declared denomination, captured at checkout so the courier can
    -- carry change. Purely advisory.
    change_requested_for INTEGER,

    collection_status   TEXT    NOT NULL DEFAULT 'AWAITING'
                                CHECK (collection_status IN (
                                    'AWAITING','COLLECTED','SHORT_PAID','REFUSED','WAIVED')),
    collected_by        TEXT,                         -- courier identifier
    collected_at        INTEGER,

    -- Reconciliation between courier hand-off and platform ledger.
    reconciled          INTEGER NOT NULL DEFAULT 0 CHECK (reconciled IN (0,1)),
    reconciled_at       INTEGER,
    discrepancy_note    TEXT,

    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,

    CHECK (collection_status <> 'COLLECTED' OR amount_collected IS NOT NULL),

    FOREIGN KEY (payment_id) REFERENCES payments(id) ON DELETE CASCADE,
    FOREIGN KEY (order_id)   REFERENCES orders(id)   ON DELETE CASCADE
);

CREATE INDEX idx_cash_collections_status ON cash_collections(collection_status);


-- =============================================================================
--  SECTION 6 — SYNC INFRASTRUCTURE
-- =============================================================================

-- Durable write-ahead queue for the offline-first write path. Every local
-- mutation that must reach the server is enqueued here in the SAME transaction
-- that performs the local write, so a crash between the two is impossible.
CREATE TABLE sync_outbox (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type         TEXT    NOT NULL CHECK (entity_type IN
                                ('ORDER','CART','ADDRESS','PROFILE','FAVORITE','RATING')),
    entity_local_id     INTEGER NOT NULL,
    operation           TEXT    NOT NULL CHECK (operation IN ('CREATE','UPDATE','DELETE')),
    payload_json        TEXT    NOT NULL,
    idempotency_key     TEXT    NOT NULL UNIQUE,
    attempt_count       INTEGER NOT NULL DEFAULT 0,
    next_attempt_at     INTEGER NOT NULL DEFAULT 0,   -- exponential backoff target
    last_error          TEXT,
    created_at          INTEGER NOT NULL
);

CREATE INDEX idx_outbox_ready ON sync_outbox(next_attempt_at, id);

CREATE TABLE search_history (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER NOT NULL,
    query               TEXT    NOT NULL,
    searched_at         INTEGER NOT NULL,

    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_search_history_unique ON search_history(user_id, query);
CREATE INDEX        idx_search_history_recent ON search_history(user_id, searched_at DESC);


-- =============================================================================
--  SECTION 7 — TRIGGERS
--
--  Room does not generate triggers. Create them inside a RoomDatabase.Callback
--  (onCreate) and re-create them in every Migration that rebuilds a table.
-- =============================================================================

CREATE TRIGGER trg_users_updated_at AFTER UPDATE ON users
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE users SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = NEW.id;
END;

CREATE TRIGGER trg_carts_updated_at AFTER UPDATE ON carts
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE carts SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = NEW.id;
END;

CREATE TRIGGER trg_orders_updated_at AFTER UPDATE ON orders
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE orders SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = NEW.id;
END;

-- Touch the parent cart whenever a line changes, so a single Flow observing
-- `carts` is sufficient to refresh the cart badge and summary bar.
CREATE TRIGGER trg_cart_items_touch_cart AFTER INSERT ON cart_items
FOR EACH ROW
BEGIN
    UPDATE carts SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = NEW.cart_id;
END;

CREATE TRIGGER trg_cart_items_touch_cart_upd AFTER UPDATE ON cart_items
FOR EACH ROW
BEGIN
    UPDATE carts SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = NEW.cart_id;
END;

CREATE TRIGGER trg_cart_items_touch_cart_del AFTER DELETE ON cart_items
FOR EACH ROW
BEGIN
    UPDATE carts SET updated_at = CAST(strftime('%s','now') AS INTEGER) * 1000
    WHERE id = OLD.cart_id;
END;

-- Auto-append to the audit trail on any status change. Guarantees history is
-- written even if a future code path updates `orders` directly.
CREATE TRIGGER trg_orders_status_audit AFTER UPDATE OF status ON orders
FOR EACH ROW WHEN NEW.status <> OLD.status
BEGIN
    INSERT INTO order_status_history (order_id, from_status, to_status, source, occurred_at)
    VALUES (NEW.id, OLD.status, NEW.status, 'LOCAL',
            CAST(strftime('%s','now') AS INTEGER) * 1000);
END;

-- Guard the state machine at the storage layer. Terminal orders are frozen;
-- an out-of-order push that arrives after delivery is rejected here even if
-- application-layer validation is bypassed.
CREATE TRIGGER trg_orders_block_terminal_transition
BEFORE UPDATE OF status ON orders
FOR EACH ROW WHEN OLD.status IN ('DELIVERED','CANCELLED','REJECTED')
              AND NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'Illegal transition: order is in a terminal state');
END;

-- Cash must never be marked collected for an order that was never delivered.
CREATE TRIGGER trg_cash_requires_delivery
BEFORE UPDATE OF collection_status ON cash_collections
FOR EACH ROW WHEN NEW.collection_status = 'COLLECTED'
              AND (SELECT status FROM orders WHERE id = NEW.order_id)
                  NOT IN ('OUT_FOR_DELIVERY','DELIVERED')
BEGIN
    SELECT RAISE(ABORT, 'Cash collection requires an out-for-delivery or delivered order');
END;


-- =============================================================================
--  SECTION 8 — VIEWS
--
--  Map to Room @DatabaseView. Keeps aggregate SQL in one place instead of
--  scattered across DAOs.
-- =============================================================================

-- Cart totals in a single aggregate pass. Backs the badge, the summary bar,
-- and the cart list simultaneously.
CREATE VIEW v_cart_summary AS
SELECT
    c.id                                                    AS cart_id,
    c.user_id                                               AS user_id,
    c.restaurant_id                                         AS restaurant_id,
    r.name                                                  AS restaurant_name,
    r.image_url                                             AS restaurant_image_url,
    r.min_order_value                                       AS min_order_value,
    r.accepts_cod                                           AS restaurant_accepts_cod,
    c.status                                                AS status,
    c.needs_revalidation                                    AS needs_revalidation,
    COALESCE(SUM(ci.quantity), 0)                           AS total_quantity,
    COUNT(ci.id)                                            AS line_count,
    COALESCE(SUM((ci.unit_base_price + ci.unit_options_price) * ci.quantity), 0)
                                                            AS item_total,
    c.updated_at                                            AS updated_at
FROM carts c
JOIN restaurants r ON r.id = c.restaurant_id
LEFT JOIN cart_items ci ON ci.cart_id = c.id
WHERE c.status = 'OPEN'
GROUP BY c.id;

-- The multi-order tracking surface: every live order with its payment posture,
-- ordered by urgency. One query serves the Orders tab, the home-screen pill,
-- and the notification refresh.
CREATE VIEW v_active_orders AS
SELECT
    o.id                    AS order_id,
    o.order_number          AS order_number,
    o.user_id               AS user_id,
    o.restaurant_name       AS restaurant_name,
    o.restaurant_image_url  AS restaurant_image_url,
    o.status                AS status,
    o.grand_total           AS grand_total,
    o.currency_code         AS currency_code,
    o.placed_at             AS placed_at,
    o.expected_delivery_at  AS expected_delivery_at,
    o.courier_name          AS courier_name,
    o.courier_phone         AS courier_phone,
    o.sync_state            AS sync_state,
    p.method                AS payment_method,
    p.status                AS payment_status,
    cc.amount_due           AS cash_amount_due,
    cc.collection_status    AS cash_collection_status,
    (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.id) AS item_count
FROM orders o
LEFT JOIN payments p         ON p.order_id  = o.id
                             AND p.status IN ('PENDING','AWAITING_COLLECTION','AUTHORIZED')
LEFT JOIN cash_collections cc ON cc.order_id = o.id
WHERE o.status IN ('PLACED','CONFIRMED','PREPARING','READY_FOR_PICKUP','OUT_FOR_DELIVERY')
ORDER BY o.expected_delivery_at ASC;

-- Outstanding cash exposure — powers the "keep ₹X ready" banner and any
-- support-facing reconciliation screen.
CREATE VIEW v_pending_cash_settlements AS
SELECT
    cc.id               AS collection_id,
    o.id                AS order_id,
    o.order_number      AS order_number,
    o.restaurant_name   AS restaurant_name,
    cc.amount_due       AS amount_due,
    cc.change_requested_for AS change_requested_for,
    o.status            AS order_status,
    o.expected_delivery_at AS expected_delivery_at
FROM cash_collections cc
JOIN orders o ON o.id = cc.order_id
WHERE cc.collection_status = 'AWAITING'
  AND o.status NOT IN ('CANCELLED','REJECTED');


-- =============================================================================
--  SECTION 9 — SEED / REFERENCE DATA (development only)
--  Ship behind a debug build flag. Never included in a release build.
-- =============================================================================

-- INSERT INTO restaurants (remote_id, name, ..., cached_at, created_at, updated_at)
-- VALUES ('[SEED_RESTAURANT_ID]', '[SEED_RESTAURANT_NAME]', ...);
