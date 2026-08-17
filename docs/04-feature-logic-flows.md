# 4. Feature Logic Flows

Step-by-step process definitions for the three core features. These are **logic
specifications** — control flow, state transitions, and failure handling — not
implementations.

---

## 4.1 Secure User Authentication

### 4.1.1 Design posture

Phone + OTP is the primary factor. This is deliberate: a food-delivery account's most
sensitive capability is placing a COD order to a saved address, and the phone number is
already the operational contact for every delivery. Passwords add a credential-stuffing
surface and a reset flow without adding proportionate protection.

**Non-negotiables**

| Rule | Reason |
|------|--------|
| OTP is generated, hashed, and verified **server-side only** | A client-verified OTP is theatre; the code must never appear in a client-reachable response |
| Access token short-lived (`[ACCESS_TOKEN_TTL]`, ~15 min); refresh token long-lived and **rotated on every use** | Limits the blast radius of a stolen token; rotation makes replay detectable |
| Tokens in `EncryptedSharedPreferences` + Android Keystore | Never in SQLite, never in plain `SharedPreferences`, never in logs |
| Certificate pinning on `[API_ENDPOINT]` | Defeats interception by a user-installed or malicious root CA |
| SMS Retriever API for autofill | Zero SMS-read permission — a privacy win and a Play policy requirement |
| Rate limiting on both client and server | Client throttling is UX; the server limit is the control |

### 4.1.2 Registration / login flow

```
[START] User opens app
    │
    ▼
┌─────────────────────────────────────────┐
│ SPLASH: resolve session                 │
│  • read tokens from EncryptedSharedPrefs│
│  • warm Room instance in parallel       │
└───────────────┬─────────────────────────┘
                │
        ┌───────▼────────┐
        │ Token present? │
        └───┬────────┬───┘
         NO │        │ YES
            │        ▼
            │   ┌─────────────────────┐
            │   │ Access token valid? │
            │   └───┬─────────────┬───┘
            │    NO │             │ YES
            │       ▼             └────────────► [HOME]
            │  ┌──────────────────────┐
            │  │ Refresh token valid? │
            │  └───┬──────────────┬───┘
            │   NO │              │ YES
            │      │              ▼
            │      │   ┌────────────────────────────┐
            │      │   │ POST /auth/refresh          │
            │      │   │ (single-flight: concurrent  │
            │      │   │  401s await one refresh)    │
            │      │   └───┬────────────────────┬────┘
            │      │       │ 200                │ 401
            │      │       ▼                    │
            │      │  persist rotated pair ──► [HOME]
            │      │                            │
            │      ▼                            │
            └──►┌──────────────────────────────▼──┐
                │ CLEAR SESSION                   │
                │  • wipe encrypted prefs         │
                │  • wipe user-scoped tables      │
                │    (single transaction)         │
                └───────────────┬─────────────────┘
                                ▼
                ┌───────────────────────────────┐
                │ PHONE ENTRY SCREEN            │
                │ validate E.164 locally        │
                └───────────────┬───────────────┘
                                ▼
                ┌───────────────────────────────┐
                │ Check auth_attempts:          │
                │ ≥ [MAX_OTP_REQUESTS] in       │
                │ [OTP_WINDOW]?                 │
                └───┬───────────────────────┬───┘
                YES │                       │ NO
                    ▼                       ▼
            show cooldown        ┌──────────────────────────┐
            + remaining time     │ POST /auth/otp/request   │
                                 │ INSERT auth_attempts     │
                                 └──────────┬───────────────┘
                                            ▼
                                 ┌──────────────────────────┐
                                 │ OTP SCREEN               │
                                 │ • SMS Retriever autofill │
                                 │ • resend timer countdown │
                                 │ • auto-submit at 6 chars │
                                 └──────────┬───────────────┘
                                            ▼
                                 ┌──────────────────────────┐
                                 │ POST /auth/otp/verify    │
                                 └──┬──────────────────┬────┘
                                    │ 200              │ 4xx
                                    ▼                  ▼
                    ┌───────────────────────┐   ┌──────────────────────┐
                    │ persist token pair    │   │ shake + inline error │
                    │ UPSERT users          │   │ increment attempts   │
                    │ INSERT user_sessions  │   │ ≥ MAX → lock out,    │
                    │ enqueue catalog warm  │   │ offer voice/alt call │
                    └───────────┬───────────┘   └──────────────────────┘
                                ▼
                    ┌───────────────────────┐
                    │ is_new_user?          │
                    └──┬────────────────┬───┘
                   YES │                │ NO
                       ▼                ▼
              [PROFILE SETUP]        [HOME]
              name + address
              (address is required
               before first checkout,
               not before browsing)
```

### 4.1.3 Token refresh under concurrency

Multiple in-flight requests can 401 simultaneously. Without care, each triggers its own
refresh, and because refresh tokens **rotate**, the losers of that race present an
already-consumed token and are logged out — a notorious source of "randomly signed out" bug
reports.

```
OkHttp Authenticator (single instance, app-scoped)
    │
    ▼
Mutex.withLock {
    if (tokenChangedSinceThisRequestWasBuilt())
        return retryWithCurrentToken()        // another thread already refreshed
    result = refreshTokenApi.refresh(current) // exactly one network refresh
    when (result) {
        Success -> { persistRotatedPair(); retryWithNewToken() }
        Failure -> { clearSessionAndTables(); emitForceLogoutEvent(); return null }
    }
}
```

Key points: a single app-scoped `Mutex`; a re-check **inside** the lock so waiters reuse the
freshly-persisted token instead of refreshing again; and forced logout emitted as a
`SharedFlow` event that `MainActivity` observes to navigate to the Auth graph with
`popUpTo(inclusive = true)`.

### 4.1.4 Session termination

| Trigger | Action |
|---------|--------|
| User logout | Revoke server-side, then wipe encrypted prefs + all user-scoped tables in **one** transaction. Catalog cache may be retained (not user data). |
| Refresh failure / revoked | Same wipe, plus a "Signed out — please sign in again" banner on the login screen. |
| Account deletion | Wipe local, call `[API_ENDPOINT]/account/delete`, cancel all WorkManager work by tag. |

Any pending `sync_outbox` rows are **surfaced before logout**, not silently discarded:
if an unsynced order exists, warn the user and offer to retry first.

---

## 4.2 Multi-Cart and Multi-Order Handling

### 4.2.1 Model

Two distinct concurrency problems, often conflated:

- **Multi-cart** — N *unplaced* carts, one per restaurant, held simultaneously.
  Enforced by `idx_carts_one_open_per_restaurant`.
- **Multi-order** — N *placed* orders progressing through independent state machines
  simultaneously. Enforced by the `orders` state machine plus `v_active_orders`.

Checkout is always scoped to exactly **one** cart. A "combined checkout" across restaurants
is out of scope: delivery routing, per-restaurant fees, and independent preparation times
make a single blended ETA misleading.

### 4.2.2 Add-to-cart flow

```
[User taps ADD on a menu item]
    │
    ▼
┌────────────────────────────────────┐
│ Item has option groups?            │
└──┬─────────────────────────────┬───┘
   │ YES                          │ NO
   ▼                              │
┌─────────────────────────┐       │
│ Open customiser sheet   │       │
│ • enforce min/max per   │       │
│   group before enabling │       │
│   the CTA               │       │
└──────────┬──────────────┘       │
           └──────────┬───────────┘
                      ▼
        ┌──────────────────────────────────┐
        │ Open cart for this restaurant?   │
        └──┬───────────────────────────┬───┘
        NO │                           │ YES
           ▼                           │
   ┌──────────────────────┐            │
   │ INSERT INTO carts    │            │
   │ (status='OPEN')      │            │
   └──────────┬───────────┘            │
              └───────────┬────────────┘
                          ▼
        ┌─────────────────────────────────────────┐
        │ config_signature =                      │
        │   hash(itemId + sorted optionIds +      │
        │        trimmed instructions)            │
        └─────────────────┬───────────────────────┘
                          ▼
        ┌─────────────────────────────────────────┐
        │ INSERT INTO cart_items … ON CONFLICT     │
        │   (cart_id, config_signature)            │
        │   DO UPDATE SET quantity =               │
        │     quantity + excluded.quantity         │
        │ INSERT cart_item_options (snapshot Δ)    │
        │  ── all inside ONE transaction ──        │
        └─────────────────┬───────────────────────┘
                          ▼
        Trigger touches carts.updated_at
                          ▼
        Flow over v_cart_summary re-emits
                          ▼
        Cart badge, summary bar, and Cart tab
        all update — no cross-screen messaging
```

**No "clear your cart?" dialog exists anywhere in this flow.** Browsing a second restaurant
opens a second cart. This removes a well-documented abandonment point at the cost of one
foreign key.

### 4.2.3 Checkout and order placement

```
[User taps "Place Order"]
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 1 — RE-VALIDATE  (GET [API_ENDPOINT]/carts/validate)    │
│   compare snapshots against live catalog:                    │
│     • unit_base_price vs menu_items.base_price               │
│     • is_available on every item and selected option         │
│     • restaurant.is_open, min_order_value                    │
│     • coupon validity window and min spend                   │
└───────────────┬──────────────────────────────────────────────┘
                │
        ┌───────▼─────────┐
        │ Drift detected? │
        └───┬─────────┬───┘
        YES │         │ NO
            ▼         │
  ┌───────────────────────────────┐
  │ SET carts.needs_revalidation=1│
  │ Show a diff sheet:            │
  │  "Paneer Tikka ₹280 → ₹300"   │
  │  "Mint chutney unavailable"   │
  │ User must Accept or Remove.   │
  │ Checkout is BLOCKED until 0.  │  ← never silently reprice
  └───────────────┬───────────────┘
                  │ resolved
                  ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 2 — PRICE  (PricingEngine, pure domain, integer math)   │
│   item_total   = Σ (base + options) × qty                    │
│   discount     = coupon rule, capped at max_discount         │
│   delivery_fee = restaurant fee, waived per offer/tier       │
│   tax          = [TAX_RATE] applied per jurisdiction rules   │
│   grand_total  = item + packaging + delivery + tax + tip     │
│                  − discount                                  │
│   ▸ Server recomputes and is authoritative. A mismatch       │
│     beyond tolerance aborts with a re-validation prompt.     │
└───────────────┬──────────────────────────────────────────────┘
                ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 3 — PAYMENT SELECTION                                   │
│   COD eligibility → § 4.3.1                                  │
└───────────────┬──────────────────────────────────────────────┘
                ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 4 — LOCAL COMMIT   ── ONE TRANSACTION ──                │
│   idempotencyKey = UUID.randomUUID()   ← generated ONCE      │
│   INSERT orders (status='PLACED', sync_state='PENDING',      │
│                  idempotency_key, + snapshots)               │
│   INSERT order_items, order_item_options                     │
│   INSERT payments (method, status)                           │
│   INSERT cash_collections            (if CASH)               │
│   UPDATE carts SET status='CONVERTED'                        │
│   INSERT sync_outbox (entity='ORDER', op='CREATE', payload)  │
│                                                              │
│   ▸ Commit or roll back as a unit. A crash mid-way cannot    │
│     leave an order without its outbox row, or a converted    │
│     cart without an order.                                   │
└───────────────┬──────────────────────────────────────────────┘
                ▼
        Navigate to Confirmation (optimistic — the order is
        already visible in Active with a "Placing…" sync chip)
                ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 5 — SYNC   (OutboxSyncWorker, NETWORK_CONNECTED)        │
│   POST [API_ENDPOINT]/orders                                 │
│   Header: Idempotency-Key: <same UUID on every retry>        │
│                                                              │
│   2xx  → UPDATE orders SET remote_id, order_number,          │
│                            sync_state='SYNCED'               │
│          DELETE FROM sync_outbox                             │
│                                                              │
│   409  → server already has it (a prior attempt landed).     │
│          Adopt the returned order. NOT an error.             │
│                                                              │
│   4xx  → permanent: status='REJECTED', sync_state='FAILED',  │
│          restore the cart, show the reason. No retry.        │
│                                                              │
│   5xx / timeout → retry with exponential backoff.            │
│          After [MAX_SYNC_ATTEMPTS]: 'FAILED' + a manual      │
│          "Retry" affordance on the order card.               │
└──────────────────────────────────────────────────────────────┘
```

The `409` branch is what makes the whole design safe. Without it, a response lost on the
return path leaves the client convinced the order failed while the restaurant is already
cooking.

### 4.2.4 Concurrent order tracking

```
                      ┌──────────────────────────┐
                      │  ORDER STATUS SOURCES    │
                      └──────────────────────────┘
        ┌──────────────────┬─────────────────────┬───────────────────┐
        ▼                  ▼                     ▼                   ▼
  FCM push          OrderPollingWorker    Foreground refresh   User pull-to-
  (primary,         (fallback, [POLL_     (on Tracking screen  refresh
   near-real-time)   INTERVAL], only      resume)
                     while ≥1 active)
        └──────────────────┴─────────────────────┴───────────────────┘
                                   │
                                   ▼
              ┌────────────────────────────────────────┐
              │ OrderStateMachine.canTransition(       │
              │     current, incoming)                 │
              │  • forward-only along the happy path   │
              │  • terminal states frozen              │
              │  • duplicate event → no-op             │
              └───────┬────────────────────────┬───────┘
                 REJECT                     ACCEPT
                      │                        │
                 log + drop                    ▼
                              ┌────────────────────────────────┐
                              │ UPDATE orders SET status …     │
                              │ (trigger writes status history)│
                              └────────────────┬───────────────┘
                                               ▼
                              ┌────────────────────────────────┐
                              │ Flow over v_active_orders       │
                              │ re-emits ONCE for all consumers │
                              └────────────────┬───────────────┘
                    ┌──────────────┬───────────┴──────┬─────────────────┐
                    ▼              ▼                  ▼                 ▼
              Orders tab     Home live pill    Tracking screen   Ongoing
              (list of N)    (ViewPager2 of    (if that order    notification
                              N pills)          is open)         (per order)
```

**Why this scales to N orders:**

1. **One query, not N subscriptions.** `v_active_orders` is a single indexed read backed by
   the partial index `idx_orders_active`.
2. **The state machine is the only writer of `status`.** Out-of-order delivery — push arriving
   after poll has already advanced the order — is idempotent by construction.
3. **Notifications use `orderId` as the notification ID**, so N orders produce N independently
   updatable notifications, grouped under one summary.
4. **The ETA countdown is a separate 1 Hz `Flow` combined at the domain layer**, so a
   per-second redraw never touches SQLite.
5. **`WhileSubscribed(5_000)`** keeps the stream alive across rotation and short tab switches
   but tears it down when the user genuinely leaves.

### 4.2.5 Cancellation

```
User taps Cancel
    │
    ▼
status ∈ {PLACED, CONFIRMED}?  ──NO──► Disable the control; offer "Help with
    │                                   this order" (support flow) instead
   YES
    ▼
Confirmation dialog (destructive, states any cancellation fee)
    │
    ▼
POST [API_ENDPOINT]/orders/{id}/cancel      ← server-authoritative; a local-only
    │                                          cancel would desync the restaurant
    ├─ 200  → UPDATE orders SET status='CANCELLED', cancelled_at, reason
    │         UPDATE payments SET status='FAILED'   (cash: never collected)
    │         UPDATE cash_collections SET collection_status='WAIVED'
    │
    └─ 409  → the order already advanced past the cancellable window;
              refresh state and explain why
```

---

## 4.3 Cash Payment (COD) Processing Logic

Cash is the highest-risk payment method operationally: the platform bears settlement risk,
couriers carry float, and there is no chargeback mechanism. The logic below is therefore
deliberately conservative.

### 4.3.1 COD eligibility

Evaluated by `ResolveCodEligibilityUseCase` at checkout, **before** the payment selector
renders. Every rejection produces a user-facing reason — COD is never silently disabled.

```
┌──────────────────────────────────────────────────────────────────┐
│ RULE                                    │ FAILURE MESSAGE        │
├─────────────────────────────────────────┼────────────────────────┤
│ users.cod_blocked = 0                   │ "Cash unavailable on   │
│                                         │  your account"         │
├─────────────────────────────────────────┼────────────────────────┤
│ restaurants.accepts_cod = 1             │ "This restaurant is    │
│                                         │  prepaid only"         │
├─────────────────────────────────────────┼────────────────────────┤
│ grand_total ≤ COALESCE(                 │ "Cash unavailable      │
│   restaurant.cod_max_order_value,       │  above ₹[LIMIT]"       │
│   [COD_MAX_ORDER_VALUE])                │                        │
├─────────────────────────────────────────┼────────────────────────┤
│ Address is within the COD serviceable   │ "Cash unavailable at   │
│ zone (server-evaluated)                 │  this address"         │
├─────────────────────────────────────────┼────────────────────────┤
│ Count of the user's live COD orders <   │ "You already have      │
│ [MAX_CONCURRENT_COD_ORDERS]             │  [N] cash orders in    │
│   ← the multi-order risk brake          │  progress"             │
├─────────────────────────────────────────┼────────────────────────┤
│ No unresolved SHORT_PAID or REFUSED     │ "Please settle your    │
│ collection in history                   │  previous order"       │
├─────────────────────────────────────────┼────────────────────────┤
│ Order is not scheduled beyond           │ "Cash unavailable for  │
│ [COD_SCHEDULING_LIMIT]                  │  scheduled orders"     │
└─────────────────────────────────────────┴────────────────────────┘

ALL rules must pass. The client evaluates every locally-knowable rule for instant
feedback; the SERVER re-evaluates all of them at submission and is authoritative.
Client-side eligibility is a UX optimisation, never a control.
```

The concurrent-COD cap is the specific point where multi-order handling and cash risk
intersect: three simultaneous ₹2,000 cash orders is a materially different exposure from one,
and the check is a simple count over `v_active_orders WHERE payment_method = 'CASH'`.

### 4.3.2 Cash collection state machine

```
   [Order placed with method = CASH]
              │
              ▼
     ┌──────────────────┐
     │ payments.status  │
     │   = PENDING      │   local commit, not yet server-acked
     └────────┬─────────┘
              │ order synced and CONFIRMED by the restaurant
              ▼
     ┌──────────────────────┐
     │ AWAITING_COLLECTION  │  cash_collections.collection_status = 'AWAITING'
     │ amount_due frozen    │  ← amount_due NEVER changes after this point
     └────────┬─────────────┘
              │
              │ courier marks delivery in the courier app
              ▼
      ┌───────────────────────────┐
      │ Amount collected vs due?  │
      └──┬─────────┬──────────┬───┘
   equal │   less  │  refused │
         ▼         ▼          ▼
  ┌───────────┐ ┌────────────┐ ┌──────────────┐
  │ COLLECTED │ │ SHORT_PAID │ │   REFUSED    │
  │ payments  │ │ flag for   │ │ order →      │
  │ .COLLECTED│ │ support;   │ │ CANCELLED;   │
  │ order →   │ │ block      │ │ increment    │
  │ DELIVERED │ │ future COD │ │ refusal      │
  └───────────┘ └────────────┘ │ counter;     │
                               │ may set      │
                               │ cod_blocked  │
                               └──────────────┘
              │
              │ order cancelled before dispatch
              ▼
        ┌──────────┐
        │  WAIVED  │  nothing owed, nothing collected
        └──────────┘

  ENFORCED IN SQL (trg_cash_requires_delivery):
    collection_status may become 'COLLECTED' only when the parent order is
    OUT_FOR_DELIVERY or DELIVERED. Cash cannot be marked collected for an
    order that was never dispatched — verified by SchemaInvariantsTest.
```

### 4.3.3 Client-side responsibilities

The client **never** confirms cash receipt — the courier app is the system of record for
collection, and the platform ledger reconciles. The client's job is to make the cash
obligation impossible to miss:

| Surface | Behaviour |
|---------|-----------|
| Checkout | COD selected → "Please keep exact change if possible". Optional denomination picker writes `change_requested_for` so the courier can carry change. |
| Confirmation | High-contrast block: "Pay ₹X in cash on delivery." |
| Tracking | Persistent COD panel with `amount_due`; the most-glanced element for cash orders. |
| Home live pill | Cash icon (💵) plus the amount when the order is `OUT_FOR_DELIVERY`. |
| Notification | On transition to `OUT_FOR_DELIVERY`: "Arriving in ~10 min. Keep ₹X ready." |
| Orders list | Per-order payment badge, so a user with three live orders can see which need cash. |
| Post-delivery | A receipt showing `amount_collected` and `change_returned` once the courier settles. |

**Amount immutability:** once `collection_status = 'AWAITING'`, `amount_due` is frozen. Tips,
coupons, and item edits are all rejected past that point. A cash figure that changes between
confirmation and doorstep is a dispute generator.

### 4.3.4 Reconciliation and failure handling

```
Courier settles → server ledger updated → push to client
    │
    ▼
UPDATE cash_collections
   SET amount_collected, change_returned,
       collection_status, collected_at, collected_by
    │
    ▼
amount_collected = amount_due?
    │
    ├─ YES → reconciled = 1, reconciled_at = now
    │        Order → DELIVERED. Rating prompt.
    │
    └─ NO  → reconciled = 0, discrepancy_note set
             Surfaced to support tooling, NOT to the user as an accusation.
             Repeated discrepancies feed users.cod_blocked (server-decided).

DISPUTED CASE — user asserts payment, courier marks SHORT_PAID:
   • Never auto-resolve on the client.
   • Order remains OUT_FOR_DELIVERY or moves to a support-held state.
   • The user gets "Help with this order" with the collection record attached.
   • Resolution is a server/ops decision, mirrored down as a status update.
```

### 4.3.5 Abuse controls

| Control | Mechanism |
|---------|-----------|
| Concurrent COD cap | `[MAX_CONCURRENT_COD_ORDERS]` live cash orders per user |
| Order-value ceiling | Per-restaurant `cod_max_order_value`, falling back to the platform limit |
| Refusal tracking | Repeated `REFUSED` collections set `users.cod_blocked` (server-decided) |
| Address trust | First order to a brand-new address may be forced prepaid, server-side |
| Velocity | Server-side rate limit on COD orders per hour per user/device/address |
| New-account cooldown | COD withheld until `[COD_ACCOUNT_AGE_MIN]` or the first successful delivery |

Every one of these is **evaluated server-side**. The client mirrors the outcome into
`users.cod_blocked` / `cod_block_reason` purely so the UI can explain itself before the user
reaches checkout — a client-side check is an explanation, never an enforcement point.

---

## 4.4 Cross-Cutting Failure Matrix

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Network lost mid-checkout | `sync_state = 'PENDING'` | Optimistic local order; `OutboxSyncWorker` retries with the same idempotency key |
| Duplicate submission | Server sees a repeated `Idempotency-Key` | `409` → adopt the existing order; never create a second |
| Price changed before checkout | Snapshot vs live catalog diff | Blocking diff sheet; user accepts or removes |
| Item unavailable at submit | Server `4xx` with an item code | Order `REJECTED`, cart restored, item flagged |
| App killed mid-transaction | SQLite atomicity | Transaction rolled back; no partial order |
| Push notification missed | `OrderPollingWorker` fallback | Poll reconciles status through the same state machine |
| Out-of-order status event | `OrderStateMachine.canTransition` | Rejected and logged; no regression |
| Token expired mid-request | `401` | Single-flight refresh + retry; force logout only if refresh fails |
| Clock skew on device | Server timestamps preferred for all order events | Device time used only for local UI countdowns |
| Cash mismatch at doorstep | `amount_collected ≠ amount_due` | `SHORT_PAID`, `reconciled = 0`, routed to support — never auto-resolved |

---

## 4.5 Implementation Sequence

| Phase | Scope | Exit criteria |
|-------|-------|---------------|
| 1 — Foundation | Modules, DI, Room + `schema.sql`, networking, design system, `SchemaInvariantsTest` in CI | App builds; DB migrates; all schema invariants pass |
| 2 — Identity | Phone/OTP, token storage and rotation, session resolution, address CRUD | A user can sign in, rotate tokens, and add an address |
| 3 — Discovery | Home feed, search, restaurant detail, menu with options | Catalog browsable offline from cache |
| 4 — Cart | Multi-cart, customiser, re-validation, pricing engine | N parallel carts survive process death |
| 5 — Orders | Checkout, outbox, idempotent submission, tracking, concurrent orders | Order placed offline syncs correctly on reconnect; 3 concurrent orders track independently |
| 6 — Cash | Eligibility rules, COD surfaces, collection state machine, reconciliation | Full COD lifecycle including short-paid and refused paths |
| 7 — Hardening | Certificate pinning, R8, accessibility audit, Macrobenchmark, optional SQLCipher | Performance budgets in [§ 1.7](01-architecture.md#17-performance-budget) met in CI |
