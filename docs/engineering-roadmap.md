# Coastline PMS engineering roadmap

This roadmap builds the six product modules on a shared, tenant-safe operational and accounting foundation. A module is complete only when its database rules, role checks, UI, audit trail and automated verification agree.

## Current baseline

- **Property management:** reservations, availability, check-in/out, deposits, folios, room moves, early checkout and housekeeping are implemented. Migrations 008–010 add approved rate overrides, complimentary stays, maintenance work orders/room blocks, date-effective rates and immutable nightly booking prices. All fifteen migrations apply and replay on isolated PostgreSQL 16 with minimal auth/storage stand-ins. Repository concurrency tests for bookings, supplier invoices and payments pass and are included in CI. Hosted migrations 000–012 are installed; Kings dashboard and department/supplier finance reads have been checked in the connected browser. Owner supplier invoice/receipt, partial payment, historical balance, reversal and void were checked in Kings. Separate staff-role/property acceptance and the remaining connected workflows are pending. Repeat installation and exact record-preservation checks pass locally.
- **Hotel POS:** no POS catalog, tickets, tables, cashier shifts or department sales workflow exists. Staff can add extra charges manually to guest folios.
- **Accounting and finance:** double-entry journals, paid expenses, historical P&L and trial balance exist. Migrations 011–014 add department accounting, supplier payables, guest receivables aging, balance sheet, cash flow, immutable CSV statement imports, exact transaction matching, reviewed exceptions and completion audit. Direct bank feeds and many-to-one settlement matching remain open.
- **Owner dashboard:** current occupancy and operational/financial summaries exist; historical reports exist by property. ADR, margins and consolidated multi-property comparisons are not complete.
- **Inventory and procurement:** not implemented.
- **Staff management and audit:** fixed roles, property-scoped access, invitations, owner role changes and audit events exist. Cashier shifts, approvals and payroll are missing.

## Build sequence

### Phase 0 — Engineering foundation

1. Make lint, type checks and production builds run consistently in local development and CI.
2. Add a disposable test-database workflow that applies every migration from an empty database; pgTAP covers organization/property isolation, pricing approval, maintenance, nightly rate changes, snapshot immutability and balanced nightly postings. The repository concurrency test checks same-room booking serialization. Extend accounting and role coverage with each module.
3. Add seeded, clearly synthetic test data. Never use the Kings pilot workspace for automated tests.
4. Add browser-level smoke coverage for sign-in, onboarding, booking, check-in, folio, payment, checkout, staff permissions and reports.
5. Record schema migration, environment, backup/restore and release procedures. Use forward-fix migrations; never edit a migration already applied to a shared environment.

**Gate:** a clean checkout installs from the lockfile; CI passes lint, typecheck, database integration and browser smoke checks; tenant-isolation tests prove one hotel's data cannot leak into another hotel.

### Phase 1 — Property management completion

1. Model date-effective rate plans, manual discounts and complimentary stays with a required reason and staff audit record.
2. Add a maintenance work-order lifecycle that is separate from housekeeping cleanliness and reservation state.
3. Preserve the existing date-overlap lock, property-local business dates, room readiness, deposit ledger and one-room reservation behavior.
4. Add role tests for creating, moving, cancelling and checking in stays, including simultaneous attempts to book the same room.

**Gate:** availability and booking agree under concurrency; discounts and complimentary stays have an actor, reason and amount; check-in/out and maintenance transitions survive reload and are auditable.

### Phase 2 — Accounting foundation expansion

1. Add department and source dimensions to accounting postings without bypassing the immutable, balanced journal.
2. Add supplier records, supplier bills and payable settlement, plus a receivable aging view for unpaid guest folios.
3. Generate balance sheet and cash-flow reports from posted journals and opening balances.
4. Extend CSV statement matching to direct bank feeds and controlled many-to-one settlement matching where a bank batches transactions.
5. Keep all amounts in integer kobo and date reports by property-local accounting date.

**Gate:** each report reconciles to the trial balance; journal debits equal credits; correction workflows preserve the original posting and its audit link; statement imports are idempotent.

### Phase 3 — Staff management, shifts and controls

1. Add cashier shift open/close with opening float, cash/card/transfer totals, counted amount and variance reason.
2. Add configurable approval rules for discounts, complimentary stays and refunds; separate request, approval and posting actors.
3. Extend audit views to filter by staff member, property, action and period.
4. Add payroll as a categorized expense workflow only after local payroll needs and permissions are specified.

**Gate:** shifts cannot close with unexplained variance unless an authorized override is recorded; users cannot approve their own restricted adjustment when separation of duties is required; all permissions are verified at the database boundary.

### Phase 4 — Hotel POS

1. Add department, product/menu items, prices and active periods.
2. Add cashier tickets with line items, void/discount reasons, service date, tender and idempotency key.
3. Support cash, card/POS and transfer payments, splitting tender where needed.
4. Post sales either directly to an account or to a guest folio; link every posted sale to balanced journal lines.
5. Add room-service/laundry ticket paths and receipt print views.

**Gate:** no completed ticket can be lost or posted twice; a folio sale appears once in the guest balance and once in the ledger; cash sales reconcile to shift tender totals and department reports.

### Phase 5 — Inventory and procurement

1. Add supplier directory, units, stock items, storage locations and par levels.
2. Add purchase orders/receiving, stock transfers, adjustments and waste with staff, reason and audit event.
3. Maintain an immutable stock-movement ledger; derive on-hand balance from movements.
4. Link purchase receiving and consumption to expense/COGS accounting with a documented costing method.
5. Add low-stock alerts and supplier/usage reports.

**Gate:** on-hand stock equals the sum of movements; duplicate receiving is prevented; every stock adjustment has an actor and reason; stock cost posts once to the ledger.

### Phase 6 — Owner dashboard completion

1. Build daily, weekly and monthly summaries from posted accounting and operational facts.
2. Add operating profit and margin, occupancy, ADR, RevPAR, open folio receivables and unpaid supplier bills.
3. Support property-level and consolidated views, with the date basis shown beside each metric.
4. Drill every total down to source records and export date-bounded reports.

**Gate:** dashboard totals match the underlying reports for the same property and date range; users only see properties they may access; empty periods and reversals are explained correctly.

### Phase 7 — Pilot release and operations

1. Apply migrations to a production-like staging project and complete role-based acceptance with a hotel owner, front desk user, accountant and housekeeper.
2. Verify authentication email settings, allowed redirect URLs, domain, secrets, storage privacy and row-level security.
3. Configure database and receipt-file backups, perform a restore drill, and configure public uptime monitoring.
4. Use a separate clean production organization. Keep Kings as test data until an explicit data migration is planned.
5. Release with a rollback/forward-fix decision, support contact, known-limits page and daily close procedure.

**Gate:** a live booking-to-checkout flow and an accounting close pass on staging; backup restore and monitoring alerts are demonstrated; no known tenant or role isolation failures remain.

## Engineering rules for every phase

- Tenant and property identifiers are validated server-side and in database policies; the browser is never the authority for access.
- Mutations use authenticated database functions, constraints and transactions for invariants, with idempotency on money and stock events.
- Posted journals and stock movements are immutable. Corrections create linked reversals or adjustment movements.
- Every migration is additive/forward-fix, reviewed, applied to a disposable database first and tested for existing-data safety.
- Every role is tested for both permitted and forbidden actions. Hiding a button is not an authorization check.
- Every money amount is integer kobo. Every business date uses the property's configured timezone.
- User-visible errors are actionable and do not expose secrets, SQL, or another tenant's data.
- Each phase includes migration review, lint, typecheck, build, database integration tests, browser smoke tests and a manual hotel workflow review before rollout.
