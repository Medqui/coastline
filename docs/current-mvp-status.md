# Coastline PMS — Current MVP status

## Implemented

- Organization and property setup, switching among authorized properties, and property-scoped access.
- Seven-day staff invitation links, invitation acceptance, owner role changes, and an access audit trail.
- Date-range room availability, room move history, and early checkout with a local departure date.
- Room operations, reservations, guest stays, folios, deposits, partial payments, refunds on open folios, and checkout.
- Double-entry posted journals, named expense categories, private expense receipt upload and viewing, historical profit and loss, and trial balance.
- CSV bank-statement import, exact transaction matching, reviewed exceptions, audited completion, report exports, and `/api/health`.
- Backup, restore drill, availability-monitoring, and daily close instructions in `docs/operations-runbook.md`.

## Not yet automated

- Invitation links must be shared by the owner; no email delivery is configured.
- Statement import uses CSV rather than a direct bank feed, and matching currently requires one exact signed statement amount per ledger movement.
- Database backup scheduling, storage-file backup, and restore drills must be configured and operated in Supabase.
- Reservations remain one room per booking.

## Deployment step

The current application requires migrations 000–014. Hosted migrations are only documented through 012; migrations 013–014 are verified on disposable PostgreSQL and still require hosted deployment before the new accounting and statement screens are used. Use the latest repeatable installer for SQL Editor installation; see `supabase/README.md`.

## Verification

- Production Next.js build passes.
- Both new migrations apply cleanly to a temporary local PostgreSQL database and can be rerun.
- Local SQL scenarios pass for property creation and access scoping, invitation acceptance and role change, availability, room move, early checkout, categorized P&L, balanced trial balance, reconciliation completion, receipt attachment, and front desk financial-data isolation.

## Bank-statement matching — migration 014

Owners and accountants can import an immutable CSV statement, automatically match unique exact signed amounts within three days, manually match remaining lines, flag reviewed exceptions and void an incorrect match with a reason. Managers have read-only access; front desk users cannot read or mutate statement matching. A matching-enabled reconciliation cannot complete until every statement line and every in-period ledger movement is matched.

Verification: all fifteen migrations apply and replay safely over populated fixtures, the statement scenario passes import idempotency, immutability, auto-match, completion, exception, audit and role-boundary checks, and the existing booking/supplier concurrency regressions still pass. Lint, TypeScript and the production build pass. Direct bank feeds and many-to-one settlement matching remain open.

## Property module update — migrations 008 and 009

Approved rate overrides and complimentary stays now require an owner or manager and an audit reason. Maintenance reports, lifecycle updates, room blocks, calendar visibility and booking/check-in/room-move guards are implemented. Staff instructions are updated.

All ten migrations applied to a disposable PostgreSQL 16 instance with minimal Supabase auth/storage stand-ins. The three real pgTAP suites passed 47 assertions. A simultaneous same-room booking test stored one reservation and rejected the conflicting attempt. Lint, TypeScript and production build passed. These checks do not verify hosted Supabase auth/storage or a connected browser workflow; those remain pending after the migration bundle is installed. Date-effective rates and the remaining modules are still open in the engineering roadmap.

## Date-effective rates — migration 010

Room rates can now be scheduled by room type and date. The booking form reviews each nightly price, protects against a stale quote, and saves immutable prices for the stay. Existing bookings retain their agreed prices after changes or retirement of rate schedules. Completed room-night postings use these saved amounts.

A clean local PostgreSQL install of migrations 000–010 and all four real pgTAP suites passed 83 assertions. The repository concurrency test verified one stored reservation, two saved nightly prices and no revenue journal for a quote. The tests use minimal auth/storage stand-ins; hosted Supabase/PostgREST and connected browser acceptance remain pending.


## Department accounting and supplier payables — migrations 011 and 012

Finance staff can manage supplier contacts and record invoices with category, department, accounting date, due date and private receipt. Owners and accountants can make partial settlements, reverse incorrect payments and void unpaid invoices with linked journal corrections. Managers can enter invoices but cannot settle or correct them. Posted financial facts cannot be edited or deleted. Guest folio extras and paid expenses now retain department dimensions; account and department P&L totals reconcile. Historical journals stay unchanged, with source-based allocation explained in the UI.

Supplier balances and aging use the selected as-of date, so later reversals and voids preserve prior reports. Server-side summary totals include all records; the displayed bills and payment lists contain the latest 100. Concurrent payments lock the invoice and cannot overpay it. Receipt uploads can be retried against an existing invoice without recording the cost again.

Verification: all thirteen migrations and six pgTAP suites pass 209 assertions on isolated PostgreSQL 16 with minimal Supabase auth/storage stand-ins. Real concurrent booking, invoice and payment checks pass, including safe repeated payment submissions. A forward upgrade preserves three historical journals, one paid expense, two guest charges and unchanged P&L/trial balance. Lint, TypeScript and production build pass. Hosted migrations 009–012 are now installed and the connected Kings dashboard and finance screens load. Local checks do not establish connected write, receipt upload or full role-based acceptance; those checks remain pending. The remaining accounting reports and the other four module expansions remain in the roadmap.


## Repeatable migration installation — 4 October 2026

The versioned migrations now tolerate the known previously installed objects. The generated full installer runs 000–012 in one transaction with an administrator-only release/checksum marker and an advisory lock. Repeating the same installer skips its payload; newer or conflicting recorded releases are rejected.

Verification: fresh installation and full replay pass all 209 pgTAP assertions. The replay regression preserves exact stored hotel records, including operational and posted finance facts, and retains pricing access restrictions. Seven historical/partial installation baselines upgrade successfully. Concurrent installers produce one release marker; conflicting checksum and newer installer/CLI history checks fail safely. Lint, TypeScript and the production build pass. These local checks use minimal Supabase auth/storage stand-ins. No new supplier or financial fixture was written to hosted Kings during this migration update.


## Connected owner accounting acceptance — 4 October 2026

In the authorized Kings test hotel, a synthetic supplier invoice with private PNG receipt, partial payment, historical balance, linked payment reversal and invoice void were verified in the browser. The receipt bytes loaded at the fixture's 240 × 80 dimensions. The account and Restaurant P&L matched; the partial-payment trial balance had ₦9,600 on each side. The corrections preserve the original facts and remove the current cost/payable effect. Kings owner overview returned to ₦6,000 revenue and net income, with 5% current occupancy.

One temporary finance read failure recovered on refresh. Read queries now retry recognized temporary transport/gateway failures up to three attempts; authorization/schema errors and mutations are excluded. Reconciliation reload failures clear old lists and display an explicit error. Eight retry regressions, lint, TypeScript and production build pass. Remote CI has not run.

Separate hosted staff-role/property tests, attachment replacement/retry, historical reporting after the void, private-storage denial, reconciliation and the full stay lifecycle remain pending. See `docs/connected-accounting-acceptance.md`. The expanded owner dashboard and the remaining module requirements are still open.
