# 2. UI/UX Design Blueprint

## 2.1 Design Principles

1. **Time-to-food is the only metric that matters.** Every screen is judged by whether it
   shortens the path from launch to a placed order. Target: **≤ 5 taps** from cold start to
   checkout for a repeat order, **≤ 2 taps** for a one-tap reorder.
2. **The list is the product.** Restaurant and dish discovery happens in vertically-scrolling
   card feeds. These must be flawless: no jank, no layout shift, image placeholders reserved
   before load.
3. **Never lose the user's cart.** Carts survive process death because they live in SQLite,
   not in memory. This is a persistence guarantee expressed as a UX promise.
4. **Live orders are ambient, not modal.** An in-progress order is always reachable from a
   persistent pill above the bottom navigation — the user never has to go hunting.
5. **Cash is a first-class payment method**, not a fallback. COD gets explicit affordances:
   exact-change prompts, amount confirmation, and a collect-on-doorstep summary.

---

## 2.2 Navigation Architecture

**Single Activity + Navigation Component**, one nested graph per bottom-navigation destination
so each tab keeps an independent back stack.

```
                          MainActivity
                     (NavHostFragment + BottomNavigationView + LiveOrderPill)
                                   │
        ┌──────────┬───────────────┼───────────────┬──────────────┐
        │          │               │               │              │
   ┌────▼───┐ ┌────▼───┐     ┌─────▼────┐    ┌─────▼────┐   ┌─────▼────┐
   │  HOME  │ │ SEARCH │     │   CART   │    │  ORDERS  │   │ ACCOUNT  │
   │  graph │ │  graph │     │  graph   │    │  graph   │   │  graph   │
   └────┬───┘ └────┬───┘     └─────┬────┘    └─────┬────┘   └─────┬────┘
        │          │               │               │              │
   Home Feed   Search       Cart List         Orders List    Profile
        │       Results      (multi-cart)          │          Addresses
        ▼          │               │               ▼          Payment Prefs
   Restaurant ◄────┘          Checkout        Order Tracking  Help
     Detail                        │               │
        │                          ▼               ▼
        ▼                    Payment Method   Order Detail
   Item Customiser                 │               │
   (bottom sheet)                  ▼               ▼
                             Order Confirm    Rate & Reorder

  AUTH graph — separate, launched as a top-level destination when the session is
  invalid. Uses popUpTo(inclusive = true) so the user cannot back-navigate into
  an authenticated screen after logout.
```

### Navigation rules

- **Bottom nav** is visible on the five root destinations only; hidden on Checkout, Tracking,
  and all Auth screens via a `NavController.OnDestinationChangedListener`.
- **Deep links** are declared in the graph for `[APP_SCHEME]://order/{orderId}` so a push
  notification taps straight through to Tracking with a correctly-synthesised back stack.
- **Cart tab badge** reflects total item count across *all* carts, sourced from a single
  `Flow` in `MainViewModel`.
- **Back from Checkout** returns to the cart with state intact — never to Home.

---

## 2.3 Screen-by-Screen Wireframes

### 2.3.1 Splash / Session Resolver

```
┌─────────────────────────────┐
│                             │   • Not a timed splash. Resolves in parallel:
│                             │       – read session token (EncryptedSharedPrefs)
│          [LOGO]             │       – validate expiry / silent refresh
│                             │       – warm the Room instance
│      ●  ●  ●  (pulse)       │   • Branch:
│                             │       valid   → Home (feed pre-populated from cache)
│                             │       expired → Auth graph
└─────────────────────────────┘   • Hard ceiling [SPLASH_TIMEOUT_MS]; on timeout
  Layout: ConstraintLayout,       proceed offline with cached data rather than block.
  centred logo, indeterminate
  progress with alpha animation
```

### 2.3.2 Authentication — Phone Entry

```
┌─────────────────────────────┐
│ ←                           │  Layout: ConstraintLayout
│                             │  • TextInputLayout (Material, outlined box)
│  Enter your                 │      – prefix "+[CC]" via prefixText
│  phone number               │      – inputType="phone", maxLength via filter
│                             │      – digits-only InputFilter
│  We'll send a 6-digit code  │  • Real-time validation → error shown on the
│                             │    TextInputLayout, not a Toast
│  ┌───────────────────────┐  │  • MaterialButton "Continue":
│  │ +[CC] │ 98765 43210   │  │      enabled = uiState.isPhoneValid
│  └───────────────────────┘  │      shows inline ProgressBar while requesting OTP
│                             │  • Legal text with clickable spans (Terms/Privacy)
│  ┌───────────────────────┐  │  • windowSoftInputMode="adjustResize";
│  │      Continue      →  │  │    ScrollView wrapper so the CTA stays reachable
│  └───────────────────────┘  │    on small screens with the IME open
│                             │
│  By continuing you agree to │  Accessibility: labelFor set, contentDescription
│  the Terms and Privacy…     │  on the CTA, 48dp minimum touch targets.
└─────────────────────────────┘
```

### 2.3.3 Authentication — OTP Verification

```
┌─────────────────────────────┐
│ ←                           │  • Six single-character EditTexts inside a custom
│                             │    OtpInputView (LinearLayout subclass) that
│  Verify your number         │    manages focus advance/reverse and paste.
│  Code sent to +[CC] 98765…  │  • SMS Retriever API auto-fills — no SMS read
│      Wrong number?          │    permission requested (privacy + Play policy).
│                             │  • Resend: disabled with a countdown
│   ┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐  │    ("Resend in 0:29"), then enabled.
│   │ 1││ 2││ 3││ 4││ _││ _│  │  • Wrong code → shake animation + inline error;
│   └──┘└──┘└──┘└──┘└──┘└──┘  │    after [MAX_OTP_ATTEMPTS] the flow locks out
│                             │    and offers an alternative channel.
│   Resend code in 0:29       │  • Auto-submits on the 6th character.
│                             │
│  ┌───────────────────────┐  │
│  │        Verify         │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

### 2.3.4 Home Feed (primary discovery surface)

```
┌─────────────────────────────┐
│ 📍 Home ▾            🔔  👤 │  ← AppBarLayout, collapsing. Address selector
│ 221B Baker Street           │    opens a bottom sheet of saved addresses.
├─────────────────────────────┤
│ 🔍 Search for dishes…       │  ← Non-focusable "fake" search bar; a tap
├─────────────────────────────┤    navigates to the Search graph (prevents IME
│ ╭────╮ ╭────╮ ╭────╮ ╭────╮ │    thrash and keeps the feed scroll cheap).
│ │ 🍕 │ │ 🍔 │ │ 🍜 │ │ 🍰 │ │
│ ╰────╯ ╰────╯ ╰────╯ ╰────╯ │  ← Horizontal category rail (RecyclerView,
│ Pizza  Burger  Asian  Sweet │    HORIZONTAL LinearLayoutManager)
├─────────────────────────────┤
│  ORDER AGAIN              → │  ← Section header; visible only when the user
│ ┌─────────┐ ┌─────────┐     │    has ≥1 past order (data-driven visibility)
│ │ [img]   │ │ [img]   │     │
│ │ Tandoor │ │ Sushi Co│     │  ← Compact reorder cards; the CTA re-hydrates
│ │ ⟳ Reorder│ │⟳ Reorder│    │    the previous cart in one tap.
│ └─────────┘ └─────────┘     │
├─────────────────────────────┤
│  ALL RESTAURANTS            │
│ ┌─────────────────────────┐ │  ← Restaurant card (MaterialCardView):
│ │ ┌───────┐  Tandoori Hut │ │      • 16:9 image, WebP, placeholder drawable
│ │ │ [img] │  ★4.5 (1.2k)  │ │        sized identically → zero layout shift
│ │ │       │  North Indian │ │      • Rating chip overlaid bottom-left of image
│ │ │  25%  │  ₹300 for two │ │      • Offer ribbon overlaid top-left
│ │ │  OFF  │  🕒 28 min ·  │ │      • ETA + distance row
│ │ └───────┘  2.1 km       │ │      • Greyed out + "Closed" scrim when shut
│ │            [Free delivery]│ │      • Whole card is one clickable surface
│ └─────────────────────────┘ │        with a ripple; no nested clickables
│ ┌─────────────────────────┐ │        except the favourite heart.
│ │ …                       │ │
│ └─────────────────────────┘ │  Container: CoordinatorLayout
│                             │             + AppBarLayout (scroll|snap)
│ ╔═══════════════════════════╗│             + RecyclerView (nestedScrolling)
│ ║ 🛵 Tandoori Hut · 12 min ║│  ← LIVE ORDER PILL — persistent, anchored above
│ ║    Out for delivery    → ║│    the bottom nav. Multiple active orders
│ ╚═══════════════════════════╝│    render as a swipeable ViewPager2 of pills
├─────────────────────────────┤    with a page indicator.
│  🏠     🔍     🛒²    📋   👤│  ← BottomNavigationView, 5 items, cart badge
│ Home  Search  Cart  Orders Me│
└─────────────────────────────┘
```

**Feed composition:** a single `RecyclerView` with a multi-view-type `ListAdapter`
(`VIEW_TYPE_CATEGORY_RAIL`, `VIEW_TYPE_SECTION_HEADER`, `VIEW_TYPE_REORDER_CAROUSEL`,
`VIEW_TYPE_RESTAURANT_CARD`, `VIEW_TYPE_SHIMMER`). Nested horizontal lists share a
`RecycledViewPool` and save/restore their scroll position by key.

### 2.3.5 Restaurant Detail

```
┌─────────────────────────────┐
│ [   HERO IMAGE (collapsing) ]│  ← CollapsingToolbarLayout, parallax hero.
│ ←                    ♡   ⤴  │    Toolbar title cross-fades in on collapse.
├─────────────────────────────┤
│ Tandoori Hut                │  ← Info block: rating, cuisine, ETA, distance,
│ ★4.5 · North Indian · 2.1km │    minimum order, delivery fee.
│ 🕒 28 min · ₹300 for two    │
│ ─────────────────────────── │
│ 🏷 50% OFF up to ₹100       │  ← Offer strip (horizontal RecyclerView)
├─────────────────────────────┤
│ 🔍 Search in menu           │
│ [Veg ○] [Bestseller ○] …    │  ← Filter ChipGroup, single-line scroll
├─────────────────────────────┤
│ RECOMMENDED (8)          ▾  │  ← Sticky section header (ItemDecoration, not
│ ┌─────────────────────────┐ │    a nested RecyclerView)
│ │ 🟢 Paneer Tikka         │ │  ← Menu item row:
│ │ ★4.3 · ₹280       ┌────┐│ │      • Veg/non-veg indicator drawable
│ │ Char-grilled cott…│[img]││ │      • Name, rating, price, truncated desc
│ │                   └────┘│ │      • 80dp thumbnail, right-aligned
│ │                  ┌─────┐│ │      • ADD button overlapping the image's
│ │                  │ ADD ││ │        bottom edge (elevation 2dp)
│ │                  └─────┘│ │      • Once added, ADD morphs into a
│ └─────────────────────────┘ │        [− 2 +] stepper in place (no relayout)
│ ┌─────────────────────────┐ │      • "Customisable" caption when the item
│ │ 🔴 Butter Chicken    …  │ │        has option groups
│ └─────────────────────────┘ │
│                             │
│ ╔═══════════════════════════╗│  ← Cart summary bar slides up when the cart
│ ║ 2 items · ₹560            ║│    for THIS restaurant is non-empty.
│ ║ View Cart              →  ║│    Uses a ViewStub — not inflated until needed.
│ ╚═══════════════════════════╝│
└─────────────────────────────┘
```

### 2.3.6 Item Customiser (modal bottom sheet)

```
┌─────────────────────────────┐
│  ────                       │  ← BottomSheetDialogFragment, drag handle,
│  Paneer Tikka          ✕    │    peekHeight ~60% screen, expandable.
│  ₹280                       │
│ ─────────────────────────── │  • Option groups render as RadioGroup (single
│  Choose size *  Required    │    select) or CheckBox list (multi select).
│  ◉ Half              ₹0     │  • "*" + "Required" label; the CTA stays
│  ○ Full            +₹120    │    disabled until every required group is
│ ─────────────────────────── │    satisfied.
│  Add-ons        Optional    │  • Running total in the CTA recomputes live.
│  ☑ Extra cheese     +₹40    │  • Special-instructions TextInputLayout with a
│  ☐ Mint chutney     +₹20    │    character counter.
│ ─────────────────────────── │  • Scroll container is NestedScrollView so the
│  Special instructions       │    sheet drag gesture composes correctly.
│  ┌───────────────────────┐  │
│  │ No onions please      │  │
│  └───────────────────────┘  │
│                             │
│  ┌───┐  ┌──────────────────┐│
│  │−1+│  │ Add · ₹320       ││
│  └───┘  └──────────────────┘│
└─────────────────────────────┘
```

### 2.3.7 Cart (multi-cart surface)

This is where the "multi-order" requirement first becomes visible to the user. The app holds
**one open cart per restaurant**, concurrently.

```
┌─────────────────────────────┐
│ ←  Your Carts               │
├─────────────────────────────┤
│ ┌─────────────────────────┐ │  ← Cart card, one per restaurant.
│ │ 🍛 Tandoori Hut      ✕  │ │    Collapsed by default when >1 cart exists;
│ │ 2 items · ₹560          │ │    expanding one collapses the others
│ │ ─────────────────────── │ │    (accordion, single-expand).
│ │ Paneer Tikka   [−2+] ₹560│ │
│ │  ↳ Half, Extra cheese   │ │  ← Selected options as a caption line.
│ │ ─────────────────────── │ │
│ │ + Add more items        │ │
│ │ ┌─────────────────────┐ │ │
│ │ │ Checkout · ₹560     │ │ │  ← Per-cart CTA. Checkout is always scoped
│ │ └─────────────────────┘ │ │    to ONE restaurant.
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ 🍕 Sushi Co          ✕  │ │  ← Second concurrent cart, collapsed.
│ │ 3 items · ₹1,240      ▾ │ │
│ └─────────────────────────┘ │
│                             │
│ ⚠ Prices refreshed. 1 item  │  ← Stale-cart banner shown when a re-validation
│   is now unavailable.  Fix →│    detects a price or availability change.
└─────────────────────────────┘

Empty state: illustration + "Nothing here yet" + "Browse restaurants" CTA
             routing to the Home graph.
```

**Rationale for multi-cart over single-cart:** the single-cart model (used by some competitors)
forces a destructive "clear your cart?" dialog when the user explores a second restaurant —
a well-documented abandonment point. Persisting parallel carts in SQL costs one extra
foreign key and removes that dialog entirely.

### 2.3.8 Checkout

```
┌─────────────────────────────┐
│ ←  Checkout                 │
├─────────────────────────────┤
│ DELIVER TO                  │
│ 🏠 Home                Change│  ← Tapping "Change" opens the address bottom
│ 221B Baker Street…          │    sheet; selection returns via SavedStateHandle.
│ 🕒 Deliver now  ▾           │  ← Scheduling selector (now / later).
├─────────────────────────────┤
│ ORDER SUMMARY (2)        ▾  │  ← Collapsible; collapsed by default.
├─────────────────────────────┤
│ 🏷 Apply coupon           → │
│ ✓ SAVE50 applied      −₹50  │
├─────────────────────────────┤
│ BILL DETAILS                │  ← Every line item explicit. No hidden fees —
│ Item total          ₹560    │    this is a trust surface and a legal one.
│ Delivery fee         ₹30    │
│ Taxes & charges      ₹42    │
│ Coupon discount     −₹50    │
│ ───────────────────────────  │
│ TO PAY              ₹582    │
├─────────────────────────────┤
│ PAYMENT                     │
│ ◉ 💵 Cash on Delivery       │  ← COD default when eligible.
│    Please keep exact change │  ← Contextual hint, shown for COD only.
│ ○ 💳 Card / UPI             │
│ ⓘ COD unavailable above     │  ← Reason surfaced inline when COD is blocked,
│   ₹[COD_MAX_ORDER_VALUE]    │    never as a silent disable.
├─────────────────────────────┤
│ ┌─────────────────────────┐ │
│ │ Place Order · ₹582      │ │  ← Single primary action. Enters a loading
│ └─────────────────────────┘ │    state and becomes non-cancellable until the
└─────────────────────────────┘    local transaction commits.
```

### 2.3.9 Order Confirmation

```
┌─────────────────────────────┐
│         ✓  (animated)       │  • AnimatedVectorDrawable check-mark; no
│                             │    third-party animation runtime.
│    Order placed!            │  • Back press and the system back gesture are
│    Order #ORD-000241        │    intercepted → route to Tracking, never to
│                             │    Checkout (prevents accidental re-submission).
│  Tandoori Hut · 28 min      │  • COD block appears only for cash orders and
│                             │    states the exact amount to keep ready.
│ ┌───────────────────────────┐│
│ │ 💵 Pay ₹582 in cash on    ││
│ │    delivery. Keep exact   ││
│ │    change if possible.    ││
│ └───────────────────────────┘│
│                             │
│  ┌────────────────────────┐ │
│  │   Track Order        → │ │
│  └────────────────────────┘ │
│    Back to Home             │
└─────────────────────────────┘
```

### 2.3.10 Order Tracking (live)

```
┌─────────────────────────────┐
│ ←  Order #ORD-000241     ⋮  │
├─────────────────────────────┤
│                             │
│   [ MAP / ROUTE SURFACE ]   │  ← Map fragment placeholder. Behind a
│      🏪 ─ ─ ─ 🛵 ─ ─ ─ 🏠   │    MapProvider interface so the concrete SDK
│                             │    is swappable and the rest of the feature
├─────────────────────────────┤    module compiles without it.
│  Arriving in 12 min         │  ← ETA headline, driven by the 1 Hz ticker Flow.
│  ─────────────────────────  │
│  ✓ Order placed      7:02pm │  ← Vertical stepper (custom View drawing the
│  ✓ Restaurant confirmed     │    rail + nodes in one onDraw pass — cheaper
│  ✓ Food is being prepared   │    and more controllable than nested layouts).
│  ● Out for delivery  7:24pm │      • completed  = filled node
│  ○ Delivered                │      • active     = pulsing node + accent rail
├─────────────────────────────┤      • pending    = hollow node, muted
│ 🛵 Rahul · ★4.8             │
│    [ Call ]   [ Message ]   │  ← Courier block; appears only from
├─────────────────────────────┤    OUT_FOR_DELIVERY onward.
│ 💵 COLLECT ON DELIVERY      │
│    Amount payable  ₹582     │  ← COD panel, high-contrast. This is the
│    Keep exact change ready  │    single most-glanced element for cash orders.
├─────────────────────────────┤
│ Order summary            ▾  │
│ Help with this order     →  │
└─────────────────────────────┘
```

### 2.3.11 Orders List (concurrent order management)

```
┌─────────────────────────────┐
│  Orders                     │
│ ┌────────────┬────────────┐ │  ← TabLayout + ViewPager2 (Active | History).
│ │  ACTIVE 2  │  HISTORY   │ │    The Active tab shows a count badge.
│ └────────────┴────────────┘ │
├─────────────────────────────┤
│ ┌─────────────────────────┐ │  ← Active order card. N of these render
│ │ 🛵 Tandoori Hut         │ │    simultaneously — this is the multi-order
│ │ #ORD-000241 · ₹582 · 💵 │ │    surface. Sorted by soonest ETA.
│ │ ●━━━━━━━━━━━○──○  12 min│ │  ← Inline mini progress rail.
│ │ Out for delivery        │ │
│ │ [ Track ]        [ Help]│ │
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ 🍣 Sushi Co             │ │
│ │ #ORD-000242 · ₹1,240·💳 │ │
│ │ ●━━━○──────○──○   38 min│ │
│ │ Preparing your food     │ │
│ │ [ Track ]        [ Help]│ │
│ └─────────────────────────┘ │
└─────────────────────────────┘

History tab: date-grouped rows with a Reorder CTA and a "Rate order" prompt
             for the most recent delivered order.
```

---

## 2.4 Design System (XML resources)

All visual constants live in `core-ui` and are referenced by attribute, never hardcoded.

| Resource file | Contents |
|--------------|----------|
| `colors.xml` | Semantic roles only: `color_surface`, `color_on_surface`, `color_primary`, `color_veg`, `color_non_veg`, `color_success`, `color_warning`, `color_cash`. Raw palette values are private. |
| `themes.xml` / `themes-night.xml` | `Theme.[APP_NAME]` extends `Theme.Material3.DayNight.NoActionBar`. Dark mode is a theme swap, not a code path. |
| `type.xml` | `TextAppearance.[APP_NAME].Headline/Title/Body/Caption/Price`, all in `sp`. |
| `dimens.xml` | 4dp spacing scale (`space_xs`=4 … `space_xxl`=32), `corner_radius_card`=12dp, `elevation_card`=2dp. |
| `styles.xml` | `Widget.[APP_NAME].Button.Primary`, `.Card.Restaurant`, `.Chip.Filter`, `.Stepper`. |

**Component inventory:** `RestaurantCardView`, `MenuItemRowView`, `QuantityStepperView`,
`OtpInputView`, `OrderProgressRailView`, `LiveOrderPillView`, `BillBreakdownView` — each a
custom compound `View`/`ViewGroup` with a `merge`-rooted layout so it adds no view-hierarchy
depth.

---

## 2.5 Motion and Feedback

| Interaction | Treatment |
|------------|-----------|
| Add to cart | ADD button morphs into the stepper via `TransitionManager.beginDelayedTransition` with a scoped `ChangeBounds`; cart badge scales 1.0 → 1.2 → 1.0. |
| Screen transitions | Shared-element transition on the restaurant hero image (card → detail). |
| Loading | Shimmer placeholder rows (in-house `ValueAnimator` over a gradient shader) — never a blocking spinner over content. |
| Errors | Inline banner or `Snackbar` with a Retry action. Modal dialogs are reserved for destructive confirmations only. |
| Order status change | The stepper node animates; a subtle haptic (`HapticFeedbackConstants.CONFIRM`) fires on transition to `OUT_FOR_DELIVERY` and `DELIVERED`. |

---

## 2.6 Accessibility and Internationalisation

- Minimum touch target 48×48dp; `contentDescription` on all icon-only controls.
- Veg/non-veg status conveyed by **shape and label**, not colour alone (colour-blind safety).
- Price, ETA, and order status are exposed to TalkBack as a single coherent
  `contentDescription` per card, not as fragmented sibling reads.
- Layouts use `start`/`end` rather than `left`/`right`; RTL verified with
  `android:supportsRtl="true"`.
- All strings in `strings.xml` with plurals (`<plurals name="item_count">`) — never string
  concatenation for counts. Currency and dates formatted via `NumberFormat`/`DateTimeFormatter`
  with the device locale, never hardcoded symbols.
- Text scales to 200% font size without truncation; card heights are `wrap_content`.

---

## 2.7 XML Layout Performance Rules

1. **`ConstraintLayout` as the default root.** Flat hierarchies; target depth ≤ 5 for list items.
2. **No nested weighted `LinearLayout`** — it forces a double measure pass per level.
3. **`ViewStub`** for anything conditionally visible and expensive (cart bar, offer strip,
   courier block, empty states).
4. **`merge`** as the root of every included layout and custom compound view.
5. **`ListAdapter` + `DiffUtil`** everywhere; stable IDs on; payload-based partial binds for
   quantity and ETA changes so a status tick does not rebind an image.
6. **`setHasFixedSize(true)`** on lists whose dimensions do not depend on content.
7. **`RecycledViewPool` sharing** between nested horizontal carousels of the same view type.
8. **Images:** explicit `width`/`height` (never `wrap_content` on a network image),
   WebP assets, downsampled to the target view size, `LruCache` sized to
   `1/8` of available heap.
9. **No `Toast` for validation** — validation lives on the input component.
10. Verify with Layout Inspector (hierarchy depth), the on-device GPU overdraw debug flag
    (target: no more than one layer of red), and a Macrobenchmark scroll test in CI.
