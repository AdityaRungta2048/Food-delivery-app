# 3. Database Design

Full DDL: [`db/schema.sql`](../db/schema.sql). Verification harness:
[`db/validate_schema.py`](../db/validate_schema.py) — executes the DDL and asserts that the
15 integrity rules the architecture depends on are enforced by SQLite itself, not by
application code. Run it in CI on every schema change.

## 3.1 Governing Principles

| Principle | Rationale |
|-----------|-----------|
| **Money is `INTEGER` in minor units** (paise/cents) | `REAL` cannot represent `0.01` exactly. Summing a bill in floating point produces a total that disagrees with the sum of its printed lines — a defect that surfaces as a customer dispute, not a crash. |
| **Timestamps are `INTEGER` epoch-millis, UTC** | Sortable, arithmetic-friendly, timezone-free. Local rendering is a presentation concern. |
| **Enums are `TEXT` + `CHECK`** | Readable in a `.dump`, and an invalid value fails on write. An `INTEGER` enum saves a few bytes and costs every debugging session. |
| **Invariants live in the schema** | A `UNIQUE` partial index or `CHECK` cannot be bypassed by a new repository method written six months from now. Application-layer validation is a UX affordance; the database is the guarantee. |
| **`remote_id` is separate from `id`** | Local rows must exist before the server has ever seen them. This is what makes offline order placement possible. |
| **Order rows snapshot their inputs** | A restaurant may rename itself or reprice tomorrow. A placed order must render identically forever, so `restaurant_name`, `item_name`, `option_name`, and the address are denormalised into the order at placement time. |

## 3.2 Entity-Relationship Overview

```
                          ┌──────────┐
                          │  users   │
                          └────┬─────┘
             ┌─────────────────┼─────────────────┬──────────────┐
             │                 │                 │              │
      ┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐ ┌─────▼────────┐
      │  addresses  │   │user_sessions│   │    carts    │ │search_history│
      └──────┬──────┘   └─────────────┘   └──────┬──────┘ └──────────────┘
             │                                   │ 1:N
             │                            ┌──────▼──────┐
             │                            │ cart_items  │
             │                            └──────┬──────┘
             │                                   │ 1:N
             │                            ┌──────▼───────────┐
             │                            │cart_item_options │
             │                            └──────────────────┘
             │
             │        ┌──────────────┐         ┌──────────────────┐
             │        │ restaurants  │────────►│ menu_categories  │
             │        └──────┬───────┘   1:N   └────────┬─────────┘
             │               │                          │ 1:N
             │               │                 ┌────────▼─────────┐
             │               │                 │   menu_items     │
             │               │                 └────────┬─────────┘
             │               │                          │ 1:N
             │               │                 ┌────────▼──────────┐
             │               │                 │item_option_groups │
             │               │                 └────────┬──────────┘
             │               │                          │ 1:N
             │               │                 ┌────────▼─────────┐
             │               │                 │  item_options    │
             │               │                 └──────────────────┘
             │               │
      ┌──────▼───────────────▼──────┐
      │           orders            │
      └──┬────────────┬─────────────┘
         │ 1:N        │ 1:N                    │ 1:N
  ┌──────▼──────┐ ┌───▼──────────────────┐ ┌───▼──────────┐
  │ order_items │ │ order_status_history │ │   payments   │
  └──────┬──────┘ └──────────────────────┘ └───┬──────────┘
         │ 1:N                                 │ 1:1 (CASH only)
  ┌──────▼─────────────┐                ┌──────▼────────────┐
  │ order_item_options │                │ cash_collections  │
  └────────────────────┘                └───────────────────┘

  ┌──────────────┐   Cross-cutting: durable write-ahead queue for every
  │ sync_outbox  │   local mutation that must reach [API_ENDPOINT].
  └──────────────┘
```

## 3.3 Table Notes

### Identity
- **`users`** — one row expected; multi-account is out of scope for v1. Carries `cod_blocked`
  and `cod_block_reason`, mirrored from the server, so the client can hide COD *before*
  checkout rather than failing at submission.
- **`user_sessions`** — **metadata only**. Access and refresh tokens are never written to
  SQLite; see [§ 3.6](#36-security-of-data-at-rest).
- **`auth_attempts`** — client-side OTP throttling ledger. A cheap abuse brake and a good UX
  signal ("try again in 30s"); the server remains the authoritative limiter.
- **`addresses`** — a partial unique index (`WHERE is_default = 1 AND is_deleted = 0`) permits
  many addresses but exactly one default. Soft-deleted rather than hard-deleted, because
  historical orders reference them.

### Catalog
Read-mostly cache. `restaurants.cached_at` drives TTL eviction; a `CatalogRefreshWorker`
purges rows older than `[CATALOG_TTL_MS]` that are not referenced by an active order.

The **option group → option** split is what makes item customisation composable:
`min_select`/`max_select` on the group express "choose exactly one size" (`1,1`),
"pick up to three toppings" (`0,3`), or "at least two sides" (`2,4`) without a bespoke rule
per item. The UI renders a group as a `RadioGroup` when `max_select = 1` and a checkbox list
otherwise — a purely data-driven decision.

### Cart — the multi-cart core
```sql
CREATE UNIQUE INDEX idx_carts_one_open_per_restaurant
    ON carts(user_id, restaurant_id) WHERE status = 'OPEN';
```
This single line is the multi-cart feature. A user may hold N open carts, but never two for
the same restaurant. Because it is a partial index, a cart that moves to `CONVERTED` or
`ABANDONED` no longer occupies the slot, so the user can immediately start a fresh cart at
the same restaurant after checking out. No repository bug or race can violate it.

`cart_items.config_signature` is a stable hash of
`(menu_item_id + sorted option ids + instructions)`. Adding "Paneer Tikka, Large, extra
cheese" twice bumps `quantity` on one row; adding it once *without* cheese creates a second,
distinct row. The `UNIQUE(cart_id, config_signature)` index makes the merge behaviour a
storage guarantee rather than a code convention, and lets add-to-cart be a single
`INSERT … ON CONFLICT DO UPDATE SET quantity = quantity + excluded.quantity`.

`unit_base_price` and `unit_options_price` are **snapshots at add-to-cart time**. Comparing
them against the live catalog is precisely how price drift is detected at re-validation
(see [§ 4.2](04-feature-logic-flows.md#42-multi-cart-and-multi-order-handling)).

### Orders
- The table-level `CHECK` enforces
  `grand_total = item_total + packaging + delivery + tax + tip − discount`. A bill that does
  not add up cannot be persisted.
- `idempotency_key` is `UNIQUE` and generated **once on device, before the first submit
  attempt**. Retrying a timed-out submission with the same key is what prevents duplicate
  orders on a flaky connection — the single most important correctness property in the system.
- `idx_orders_active` is a **partial index** covering only live statuses. The active-orders
  query is the hottest read in the app (it backs the Orders tab, the home-screen live pill,
  and every push-triggered refresh), and the index stays small because delivered orders leave
  it automatically.
- `order_status_history` is append-only with a `UNIQUE(order_id, to_status, occurred_at)`
  dedupe index, so the same transition arriving via both push and poll produces one row.

### Payments and cash
`payments` is **1:N** with `orders`, not 1:1 — a failed card attempt followed by a COD
fallback is two rows, and the history matters for support. A partial unique index permits at
most one *live* attempt (`PENDING`, `AWAITING_COLLECTION`, `AUTHORIZED`) per order, which
neutralises double-tap and racing-retry bugs at the storage layer.

`cash_collections` is split out rather than folded into `payments` because its columns
(`change_requested_for`, `amount_collected`, `change_returned`, `reconciled`) are meaningless
for prepaid methods and would otherwise be a wide band of `NULL`s on every card transaction.

### Sync
`sync_outbox` is written **in the same transaction as the local mutation**, which makes a
crash between "order saved" and "order queued for upload" impossible. `next_attempt_at`
carries the exponential-backoff target so `OutboxSyncWorker` can select ready work with a
single indexed range scan.

## 3.4 Indexing Strategy

Indices are added to serve a named query, never speculatively — each one is write
amplification on a mobile device with slow flash.

| Index | Query it serves |
|-------|-----------------|
| `idx_orders_active` (partial) | The active-order stream; the hottest read in the app |
| `idx_orders_history` | Orders → History tab, paged by `placed_at DESC` |
| `idx_carts_one_open_per_restaurant` (partial, unique) | Multi-cart invariant |
| `idx_cart_items_config` (unique) | Add-to-cart upsert / line merge |
| `idx_menu_items_restaurant` | Restaurant detail menu load |
| `idx_payments_one_live_attempt` (partial, unique) | Double-submit protection |
| `idx_outbox_ready` | Sync worker's "what is due now" scan |
| `idx_restaurants_open_rating` | Home feed default sort |

Validate with `EXPLAIN QUERY PLAN` in DAO tests; assert `SEARCH … USING INDEX` and fail the
test on `SCAN`. Room's `@Query` is compile-time verified for syntax, but not for plan quality.

## 3.5 Migration Policy

1. Every schema change ships an explicit `Migration(from, to)` — `fallbackToDestructiveMigration()`
   is banned in release builds. It silently discards the user's carts and unsynced orders.
2. `exportSchema = true`; the generated JSON is committed and diffed in review.
3. Triggers and views are **not** managed by Room. Recreate them in `RoomDatabase.Callback.onCreate`
   and in any migration that rebuilds a table (`ALTER TABLE … RENAME` drops attached triggers).
4. `MigrationTestHelper` tests every `n → n+1` path with seeded data, plus the full
   `1 → latest` chain.
5. Additive changes (new nullable column, new table) are preferred. Destructive changes are
   staged: add → dual-write → backfill → stop reading old → drop in a later release.

## 3.6 Security of Data at Rest

**Never stored in SQLite:** access tokens, refresh tokens, OTP codes, passwords or hashes,
card PANs, CVVs, payment tokens, or UPI handles.

| Asset | Storage |
|-------|---------|
| Access / refresh tokens | `EncryptedSharedPreferences` (Jetpack Security), master key in the **Android Keystore**, `StrongBox` when available |
| Session metadata | `user_sessions` — opaque non-secret handle, expiry timestamps only |
| Payment instruments | Not stored client-side. `payments.gateway_reference` holds a gateway lookup key with no instrument data |
| Order/cart PII (address, phone) | SQLite; optionally SQLCipher (below) |

**Database encryption:** SQLite is unencrypted by default and readable on a rooted device.
The app's private data directory protects it from other apps under normal conditions.
If the threat model includes rooted or physically-compromised devices, adopt **SQLCipher**
(`net.zetetic:android-database-sqlcipher`) via Room's `openHelperFactory`, with the passphrase
held in the Keystore. This is the one place where a third-party dependency may be warranted
beyond the list in [§ 1.6](01-architecture.md#16-dependency-justification); it costs roughly
5–15% on query throughput, so make it a deliberate, measured decision rather than a default.

**Additional hardening:** `android:allowBackup="false"` and an empty
`data_extraction_rules.xml` so order history and addresses are never swept into a cloud
backup; wipe all user-scoped tables and the encrypted preferences on logout, in one
transaction; never log SQL parameters or bodies in release builds (`HttpLoggingInterceptor`
gated on `BuildConfig.DEBUG`).
