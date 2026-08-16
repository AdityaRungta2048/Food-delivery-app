# [APP_NAME] — Technical Blueprint

A design-and-architecture specification for a native Android food-delivery application
built on **Kotlin + XML + SQL**, covering user authentication, multi-order management,
and cash-on-delivery (COD) workflows.

> This repository contains **specification documents only** — no production source code.
> All environment-specific values are written as placeholders (`[DATABASE_NAME]`,
> `[API_ENDPOINT]`, `[APP_NAME]`, …) and must be resolved during implementation.

## Document Index

| # | Document | Contents |
|---|----------|----------|
| 1 | [docs/01-architecture.md](docs/01-architecture.md) | Layered MVVM architecture, module graph, state management for concurrent orders, threading and offline model |
| 2 | [docs/02-ui-ux-blueprint.md](docs/02-ui-ux-blueprint.md) | Navigation graph, screen-by-screen wireframe descriptions, XML layout strategy, design system |
| 3 | [docs/03-database-schema.md](docs/03-database-schema.md) | Entity-relationship model, table-by-table rationale, indexing and migration policy |
| 4 | [docs/04-feature-logic-flows.md](docs/04-feature-logic-flows.md) | Step-by-step logic flows for authentication, multi-cart/multi-order handling, and COD settlement |
| 5 | [db/schema.sql](db/schema.sql) | Complete SQLite DDL (tables, constraints, indices, triggers, views) |

## Scope Boundaries

**In scope:** client architecture, local persistence design, UI/UX structure, feature logic flows.

**Out of scope:** backend service implementation, payment-gateway integration for prepaid
methods, courier dispatch algorithms, and live map rendering internals. Where the client
depends on these, the contract is described as a placeholder endpoint.

## Technology Constraints

| Concern | Decision |
|---------|----------|
| Language | Kotlin (JVM target 17) |
| UI | XML layouts + View system (`ViewBinding`); **no Jetpack Compose** |
| Persistence | SQLite via Room (AndroidX) |
| Async | Kotlin Coroutines + Flow |
| Navigation | AndroidX Navigation Component, single-activity |
| DI | Hilt (AndroidX) |
| Background work | WorkManager (AndroidX) |

Third-party dependencies are deliberately minimised. Every library listed above is a
first-party AndroidX/JetBrains component; the justification for each is recorded in
[docs/01-architecture.md § 1.6](docs/01-architecture.md#16-dependency-justification).
