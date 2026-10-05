# MVP navigation and configuration increment — 5 October 2026

Navigation is fixed in this order: Dashboard → Reservations → Front Desk → Rooms → Housekeeping → POS → Accounting → Inventory → Reports → Staff → Settings. Role-specific menus retain that relative order. Hash links support refresh, browser back/forward and the current property selector. Database authorization remains the authority for every mutation.

## Screen ownership

- Dashboard retains the existing operational and posted-finance overview.
- Reservations retains booking, deposits, cancellation, no-show, export and availability-calendar workflows. Every active reservation is loaded in pages; the latest 100 historical reservations are included. Operational rooms cannot disappear behind the historical display limit.
- Front Desk retains check-in, walk-ins, guest folios, payments, cashier shifts and the guest directory (now a secondary tab).
- Rooms shows physical rooms classified as Available, Occupied, Reserved, Dirty or Maintenance. Occupancy, cleaning and maintenance remain separate underlying facts. Reserved means a confirmed stay overlapping today; future stays remain in the availability calendar. Occupied takes priority even if the room needs cleaning or has a maintenance issue. Existing room moves and maintenance reporting remain available.
- Housekeeping has a dedicated readiness queue and existing cleaning/inspection controls.
- POS opens in-house folios for audited department charges and payments and retains cashier controls.
- Accounting retains journals, paid expenses and supplier invoices/payments.
- Inventory introduces stock items, units, par levels, on-hand quantities, receipts/issues and a latest-100 immutable movement history. Item locks prevent concurrent issues overdrawing stock; idempotency prevents repeated receiving. This is quantity tracking, not inventory valuation or COGS.
- Reports owns existing historical financial reports, receivables, statement reconciliation and exports.
- Staff retains staff invitations, roles and property access.
- Settings owns hotel details; Room Types; physical Rooms; Floors; existing base/date-effective Rates; tax setup; Payment Methods; fixed-role documentation; and adding properties.

## Database update

New forward migration: `20261005000200_property_configuration_and_stock.sql` (release 016). Apply through the project's usual Supabase migration workflow or run the regenerated full `supabase/repeatable-install.sql` as administrator. The installer supports older deployments and repeat application; original migrations remain unchanged.

Settings writes are limited to owners/managers with property access. Configuration is audited. Room types/floors must belong to the same property. Reserved/in-house rooms cannot be deactivated, renumbered or retyped before moving/closing their active reservations. New rooms start dirty. Existing base prices can only be changed through the audited rate workflow. Existing payment clearing accounts cannot be remapped. Floor registration preserves onboarding and property creation.

Stock reads/writes require owner, manager or accountant plus property access. Balances use a security-invoker view; movements have no direct client write policy and cannot be edited/deleted. Quantity changes require a reason and actor. Neither new configuration nor inventory writes alter posted hotel journals.

## Verification and deployment limits

Lint, TypeScript, production build and 13 navigation/read-retry assertions pass. All 17 migrations apply to an isolated PostgreSQL 16 database with minimal auth/storage stand-ins. The configuration scenario verifies 23 configuration, price-preservation, inventory and role/property assertions. Populated migration replay and repeat installer preserve existing records. Existing booking/supplier concurrency checks pass; added stock races prove serialized issues and exactly-once repeated receipts.

Connected browser reads verify the eleven-section menu, operational Rooms and distinct Housekeeping using the existing local app. Hosted release 016 is installed and recorded in CLI history as of 5 October 2026. Connected owner writes pass for room configuration, cleaning, booking, check-in, folio charge/payment, same-day early checkout and quantity inventory. The hosted database passes 29 configuration/role/property checks and 12 overnight lifecycle/accounting checks in rolled-back transactions. See `connected-mvp-acceptance.md` for evidence and retained synthetic records. Full pgTAP suites have not been rerun in this increment because the local disposable PostgreSQL installation lacks pgTAP; CI retains the suites and also runs the new configuration scenario and navigation tests.

## Next increments

Bulk room creation; housekeeping staff assignment; POS catalog/tickets and standalone cash sales; automatic tax calculations on immutable booking/billing snapshots; purchase orders, receiving locations, stock valuation and COGS. Tax rules currently persist setup only; the UI says they are not automatically added to charges. Existing room-price snapshots and posted journals remain unchanged.

## Navigation correction found in connected testing

Using `window.location.hash` alone left Next.js unaware of the active screen, so server-action refreshes restored an older URL. Navigation now uses Next.js-integrated `history.pushState` and listens for `popstate` alongside `hashchange`. Connected Inventory saves retain `#inventory`; browser back/forward restores the corresponding screen.
