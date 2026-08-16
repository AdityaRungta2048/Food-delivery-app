# 1. System Architecture

## 1.1 Architectural Decision

**Recommendation: MVVM with a Clean-Architecture layer split and an offline-first repository.**

The dominant complexity in this application is not screen rendering — it is **concurrent,
long-lived, externally-mutated state**. A user may have three orders in flight from three
restaurants, each advancing through its own status machine driven by server events, while
simultaneously building a fourth cart. Any architecture that binds order state to a screen
lifecycle will lose that state on rotation, backgrounding, or navigation.

MVVM solves this because:

- `ViewModel` survives configuration changes and is scoped to a navigation graph, not a `View`.
- `Flow`/`StateFlow` expresses *"the current set of active orders"* as a continuously-emitting
  stream rather than a one-shot fetch, which is exactly the shape of the multi-order problem.
- The Repository layer becomes the **single source of truth (SSOT)**. The local SQLite database
  — not the network response — is what the UI observes. Network results are written to SQL;
  the UI updates as a consequence of the write. This makes offline behaviour, retry, and
  multi-screen consistency fall out of the design instead of being bolted on.

MVP was rejected: it requires the Presenter to hold a `View` reference, which reintroduces
lifecycle coupling. MVI was considered and partially adopted — the **unidirectional data flow**
and immutable `UiState` objects are borrowed from MVI, but a full reducer/intent pipeline adds
ceremony disproportionate to the screen count here.

---

## 1.2 Layer Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  PRESENTATION LAYER                            (Kotlin + XML, Main thread)    │
│                                                                              │
│   MainActivity (single Activity, NavHost container)                          │
│        │                                                                     │
│        ├── Fragment ──► ViewBinding ──► XML layout (ConstraintLayout)        │
│        │      │                                                              │
│        │      │ collects                    emits                            │
│        │      ▼                                                              │
│        │   StateFlow<XxxUiState>  ◄──────  ViewModel                         │
│        │   SharedFlow<XxxEvent>   ◄──────  (one-shot: nav, snackbar, dialog) │
│        │      │                                                              │
│        │      └── sends UserAction / calls VM methods ──►                    │
│        │                                                                     │
│   RecyclerView + ListAdapter + DiffUtil  (all list surfaces)                 │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ suspend fun / Flow<T>
                                │ (no Android types cross this boundary)
┌───────────────────────────────▼──────────────────────────────────────────────┐
│  DOMAIN LAYER                                  (pure Kotlin, no framework)   │
│                                                                              │
│   UseCases:  PlaceOrderUseCase, ValidateCartUseCase,                         │
│              ObserveActiveOrdersUseCase, ResolveCodEligibilityUseCase, …     │
│   Models:    Order, Cart, MenuItem, Money, DeliveryAddress                   │
│   Policies:  OrderStateMachine, CodPolicy, PricingEngine                     │
│                                                                              │
│   ▸ 100% unit-testable with plain JUnit — no Robolectric, no Android SDK.    │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ Repository interfaces (defined in domain,
                                │ implemented in data → dependency inversion)
┌───────────────────────────────▼──────────────────────────────────────────────┐
│  DATA LAYER                                    (IO dispatcher)               │
│                                                                              │
│   ┌────────────────────────────────────────────────────────────────────┐     │
│   │  Repository Implementations  (the SSOT arbiter)                    │     │
│   │    • Reads  → always from LOCAL. Returns Flow<T> backed by Room.   │     │
│   │    • Writes → LOCAL first (optimistic) → enqueue to OUTBOX →       │     │
│   │               sync worker pushes to REMOTE → reconcile LOCAL.      │     │
│   └───────────┬────────────────────────────────────┬───────────────────┘     │
│               │                                    │                         │
│   ┌───────────▼──────────────┐        ┌────────────▼─────────────────┐       │
│   │  LOCAL SOURCE            │        │  REMOTE SOURCE               │       │
│   │  Room / SQLite           │        │  ApiService → [API_ENDPOINT] │       │
│   │  DB: [DATABASE_NAME]     │        │  DTOs + Mappers              │       │
│   │  DAOs return Flow<T>     │        │  Auth interceptor            │       │
│   │  EncryptedSharedPrefs    │        │  Token-refresh authenticator │       │
│   │    (tokens, Keystore)    │        │                              │       │
│   └──────────────────────────┘        └──────────────────────────────┘       │
│                                                                              │
│   ┌────────────────────────────────────────────────────────────────────┐     │
│   │  WorkManager                                                       │     │
│   │    • OutboxSyncWorker      — flushes pending writes when online    │     │
│   │    • OrderPollingWorker    — refreshes active orders (fallback)    │     │
│   │    • CatalogRefreshWorker  — periodic menu/restaurant cache warm   │     │
│   └────────────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────────────┘
                                ▲
                                │ push (order status transitions)
                     ┌──────────┴───────────┐
                     │  FCM / Push Receiver │ ──► writes to Room ──► UI updates
                     └──────────────────────┘
```

### Reading the diagram

The critical property is the **single downward arrow of dependency**: Presentation knows
Domain, Domain knows nothing, Data implements Domain's interfaces. A push notification does
not talk to a `ViewModel`; it writes a row to SQLite, and every `Flow` observing that table
re-emits. This is why three simultaneously-tracked orders stay consistent across the Orders
tab, the home-screen live pill, and the notification tray without any cross-screen messaging.

---

## 1.3 Module Structure

A Gradle multi-module layout keeps build times low and enforces the layer boundaries at
compile time (a violation becomes a build error, not a code-review comment).

```
[APP_NAME]/
├── app/                         → Application class, MainActivity, nav_graph, DI wiring
├── core/
│   ├── core-ui/                 → Base classes, shared XML styles, custom Views, extensions
│   ├── core-domain/             → Money, Result<T>, error taxonomy, state-machine primitives
│   ├── core-database/           → Room database, DAOs, entities, migrations, type converters
│   ├── core-network/            → Retrofit/OkHttp setup, interceptors, DTO base types
│   └── core-testing/            → Fakes, test dispatchers, DAO test rules
└── feature/
    ├── feature-auth/            → Login, OTP, registration, session recovery
    ├── feature-discovery/       → Home, search, filters, restaurant detail
    ├── feature-cart/            → Multi-cart, item customisation, checkout
    ├── feature-orders/          → Order list, live tracking, order detail, reorder
    ├── feature-payment/         → COD flow, payment-method selection, settlement UI
    └── feature-account/         → Profile, addresses, order history, settings
```

Feature modules depend on `core/*` and never on each other. Cross-feature navigation is
performed through the navigation graph by deep-link/action ID, not by direct class reference.

---

## 1.4 State Management for Multi-Order Complexity

### 1.4.1 The order state machine

Order status is modelled as a **sealed hierarchy** in the domain layer, not a loose `String`.
Illegal transitions are rejected by `OrderStateMachine` before they are ever persisted, which
prevents a late-arriving or out-of-order push notification from moving a `DELIVERED` order
back to `PREPARING`.

```
                     ┌──────────────┐
                     │    DRAFT     │  (cart only, never leaves device)
                     └──────┬───────┘
                            │ checkout submitted
                     ┌──────▼───────┐
        ┌────────────│   PLACED     │───────────┐
        │            └──────┬───────┘           │ cancelled by user
        │ rejected           │ accepted          │ (allowed only in PLACED
        │ by restaurant      │                   │  and CONFIRMED)
        │            ┌───────▼──────┐            │
        │            │  CONFIRMED   │────────────┤
        │            └───────┬──────┘            │
        │                    │                   │
        │            ┌───────▼──────┐            │
        │            │  PREPARING   │            │
        │            └───────┬──────┘            │
        │                    │                   │
        │            ┌───────▼──────┐            │
        │            │ READY_FOR_   │            │
        │            │   PICKUP     │            │
        │            └───────┬──────┘            │
        │                    │                   │
        │            ┌───────▼──────┐            │
        │            │ OUT_FOR_     │            │
        │            │  DELIVERY    │            │
        │            └───────┬──────┘            │
        │                    │                   │
        │            ┌───────▼──────┐            │
        │            │  DELIVERED   │  ← terminal (success)
        │            └──────────────┘            │
        │                                        │
        ▼                                        ▼
  ┌──────────┐                            ┌─────────────┐
  │ REJECTED │  ← terminal               │  CANCELLED  │  ← terminal
  └──────────┘                            └─────────────┘

  Transition rule set (enforced in OrderStateMachine.canTransition):
    • Forward-only along the happy path; no status may regress.
    • CANCELLED reachable only from PLACED | CONFIRMED.
    • REJECTED reachable only from PLACED.
    • Terminal states accept no further transitions; duplicate events are no-ops.
    • Every accepted transition appends a row to order_status_history (audit trail).
```

### 1.4.2 Concurrent order tracking

`ObserveActiveOrdersUseCase` exposes one stream for *all* live orders:

```
Room: orderDao.observeActive()            → Flow<List<OrderWithItems>>
        │
        │ map + combine with etaTicker (1 Hz Flow for countdown text)
        ▼
Domain: Flow<List<ActiveOrder>>            (sorted by expected delivery time)
        │
        │ stateIn(viewModelScope, WhileSubscribed(5_000), initial = emptyList())
        ▼
UI:     StateFlow<OrdersUiState>
```

Three design points make this scale to N concurrent orders:

1. **One query, not N observers.** A single `Flow` over a filtered table is cheaper and
   race-free compared with one subscription per order.
2. **`WhileSubscribed(5_000)`** keeps the upstream alive across configuration changes and
   short tab switches, but tears it down when the user genuinely leaves — avoiding a permanent
   polling loop.
3. **The ETA ticker is a separate `Flow` combined at the domain layer**, so a per-second
   countdown redraw never re-queries SQLite.

### 1.4.3 UI state contract

Every screen exposes exactly one immutable state object plus a one-shot event channel:

```kotlin
// Shape only — illustrative, not implementation.
data class OrdersUiState(
    val isLoading: Boolean = false,
    val activeOrders: List<ActiveOrderUi> = emptyList(),
    val pastOrders: List<PastOrderUi> = emptyList(),
    val banner: BannerUi? = null,          // e.g. "1 order needs cash ready"
    val error: ErrorUi? = null
)

sealed interface OrdersEvent {             // consumed once, never replayed
    data class NavigateToTracking(val orderId: Long) : OrdersEvent
    data class ShowSnackbar(val messageRes: Int) : OrdersEvent
}
```

`StateFlow` for state (conflated, replayed to new collectors), `SharedFlow` with
`extraBufferCapacity` for events (never replayed — prevents a navigation command firing twice
after rotation). Fragments collect inside
`viewLifecycleOwner.lifecycleScope.launch { repeatOnLifecycle(STARTED) { … } }`.

---

## 1.5 Threading and Offline Model

| Concern | Policy |
|---------|--------|
| Dispatchers | Injected `CoroutineDispatchers` wrapper (`io`, `default`, `main`). Never hardcode `Dispatchers.IO` — it makes tests non-deterministic. |
| DB access | Room suspend DAOs; `Flow` DAOs run on the Room query executor automatically. No `allowMainThreadQueries()`, ever. |
| Cancellation | All work in `viewModelScope`; long-running writes that must survive navigation go to WorkManager, not a leaked scope. |
| Error model | `Result<T>` with a sealed `AppError` (`Network`, `Http(code)`, `Validation`, `Auth`, `Unknown`). Exceptions are caught at the repository boundary and never leak to the UI. |

### Offline-first write path (Outbox pattern)

```
User taps "Place Order"
        │
        ▼
1. Domain validates cart (prices, availability, COD eligibility)
        │
        ▼
2. INSERT INTO orders (status='PLACED', sync_state='PENDING',
                       idempotency_key=<UUID v4>)          ← local commit, one transaction
   INSERT INTO order_items …
   INSERT INTO sync_outbox (entity='ORDER', op='CREATE', payload=…)
        │
        ▼
3. UI immediately shows the order in "Active" (optimistic)
        │
        ▼
4. OutboxSyncWorker (constraint: NETWORK_CONNECTED, exponential backoff)
   POST [API_ENDPOINT]/orders   with header Idempotency-Key: <same UUID>
        │
        ├─ 2xx → UPDATE orders SET remote_id=…, sync_state='SYNCED'
        │         DELETE FROM sync_outbox WHERE id=…
        │
        ├─ 4xx (permanent, e.g. item unavailable)
        │      → UPDATE orders SET status='REJECTED', sync_state='FAILED'
        │        surface a user-facing reason; do not retry
        │
        └─ 5xx / timeout → retry with backoff; after [MAX_SYNC_ATTEMPTS]
                            mark 'FAILED' and prompt the user
```

The `idempotency_key` is generated **once, on the device, before the first attempt**, and
reused for every retry. This is what makes "place order" safe to retry over a flaky connection
without creating duplicate orders — the single most important correctness property in the
whole system.

---

## 1.6 Dependency Justification

The brief restricts third-party frameworks. Each dependency below is either first-party
AndroidX/JetBrains or otherwise unavoidable; anything replaceable with platform APIs has been
replaced.

| Dependency | Owner | Why it is essential |
|-----------|-------|---------------------|
| Room | Google/AndroidX | Compile-time-verified SQL over SQLite, plus `Flow` observation. Hand-rolling `SQLiteOpenHelper` + `ContentObserver` reimplements this with more defects. **SQL is still written by hand** — Room validates it, it does not hide it. |
| Navigation Component | Google/AndroidX | Single-activity graph, type-safe args, deep links for push notifications. |
| Hilt | Google/AndroidX | Scoped DI; manual factories across ~6 feature modules become unmaintainable. |
| WorkManager | Google/AndroidX | Guaranteed, constraint-aware background execution for the outbox and polling. No platform equivalent. |
| Coroutines / Flow | JetBrains | Kotlin's standard concurrency model. |
| Retrofit + OkHttp | Square | *Only genuinely external choice.* Justified: TLS handling, connection pooling, interceptor-based auth, and certificate pinning are security-critical and error-prone to hand-write on `HttpURLConnection`. |
| Material Components | Google | Provides `BottomNavigationView`, `MaterialCardView`, `BottomSheetBehavior`, motion specs used throughout the XML layouts. |

**Deliberately excluded:** image loaders with heavy transitive graphs (a small in-house
`LruCache` + `HttpURLConnection` decoder covers the thumbnail use case), reactive-stream
libraries (Flow suffices), and any analytics/crash SDK, which is a product decision rather
than an architectural one.

Optional, security-dependent: **SQLCipher** if the threat model requires database encryption
at rest on rooted devices. See [docs/03-database-schema.md § 3.6](03-database-schema.md#36-security-of-data-at-rest).

---

## 1.7 Performance Budget

| Metric | Target | Mechanism |
|--------|--------|-----------|
| Cold start → first meaningful frame | < 1.5 s | App Startup library, deferred DI graph, cached home feed rendered from SQLite before the network returns |
| Restaurant list scroll | 0 dropped frames at 60/120 Hz | `ListAdapter` + `DiffUtil` on a background executor, fixed-size item views, no nested `RecyclerView` without `setRecycledViewPool` sharing |
| Cart badge update | < 16 ms | `Flow` over a `SELECT COUNT(*)` view, `distinctUntilChanged()` |
| DB query (menu of 300 items) | < 20 ms | Covering indices, `@Transaction` relation queries instead of N+1 |
| APK size | < [SIZE_BUDGET] MB | R8 full mode, resource shrinking, WebP assets, no duplicate icon sets |

Layout-specific performance rules are in [docs/02-ui-ux-blueprint.md § 2.7](02-ui-ux-blueprint.md#27-xml-layout-performance-rules).
