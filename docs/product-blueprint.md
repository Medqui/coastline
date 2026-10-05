# Calabar Hotel PMS — product blueprint

**Working name:** Coastline PMS  
**Product:** Multi-property hotel operations and accounting SaaS for independent hotels in Calabar and nearby Cross River State.  
**Suggested stack:** Next.js App Router + TypeScript, Supabase Auth/Postgres/Storage, server actions or route handlers for trusted mutations.

## Product shape

One hotel team should be able to run the day from a shared operational picture: what rooms are available, who is arriving or departing, what each guest owes, what cash was collected, and what the business earned and spent. Owners should be able to inspect every headline number back to the transactions behind it.

**Product principles**

- Front desk actions stay fast and work well on a laptop or phone.
- A room's operational state (dirty, clean, inspected, out of order) is distinct from its reservation state (available, reserved, occupied).
- Every amount is stored as integer kobo, displayed as NGN, and tied to a date, property, source, and account.
- Operational records may be corrected with an audit trail; posted accounting entries are immutable and corrected by reversal plus replacement.
- The tenant boundary is the hotel organization. A user sees only organizations where they have an active membership, and only properties allowed by that membership.
- Reports show the basis and date range for each number. “Profit” means a named accounting report, not simply cash collected less cash spent.

## Six core product modules

These modules describe the full product direction. The status column separates features already in the current pilot from planned work.

| Module | Scope | Current status |
|---|---|---|
| **1. Property management** | Room inventory and availability, reservations, walk-ins, guest check-in/out, advances, rates, housekeeping and maintenance | **Partial, in pilot.** Rooms, date-range availability, one-room reservations, walk-ins, check-in/out, deposits, basic rates, housekeeping states, room moves and early checkout are implemented. Approved rate overrides, complimentary stays, maintenance work orders/room blocks and date-effective rates with immutable nightly prices are implemented. |
| **2. Hotel POS** | Restaurant/bar sales, laundry and services, room service, cash/transfer/card, and charges to guest rooms | **Planned.** Staff can manually add an extra charge to a folio and record payments. There is no POS menu, table/check workflow, department sales screen or direct POS-to-folio integration. |
| **3. Accounting and finance** | Department revenue, expenses, supplier payments, payables/receivables, general ledger, reconciliation, P&L, balance sheet and cash flow | **Partial, in pilot.** Balanced journals, paid expenses with receipts, guest folios/payments/deposits, historical P&L, trial balance and balance-comparison reconciliation exist. Department P&L, supplier invoices, partial settlements, linked corrections and historical payable aging are implemented. Balance sheet, cash-flow statement, statement import and transaction matching remain planned. Outstanding guest folio balances are visible, but there is no receivables aging module. |
| **4. Owner dashboard** | Daily/weekly/monthly revenue, operating profit/margin, occupancy and average rate, outstanding balances, multi-property comparisons | **Partial, in pilot.** The dashboard shows recognized income, expenses/net income, current occupancy and arrivals. Historical P&L and trial balance are available by property and date range. Supplier payable balances and aging are available in finance. ADR, profit margin and consolidated property comparisons remain planned. |
| **5. Inventory and procurement** | Supplier records, purchases, stock movements, food/beverage inventory, low-stock alerts, adjustments and wastage | **Planned.** Supplier records exist in finance. Stock, purchase receiving and procurement workflows remain planned. |
| **6. Staff management and audit** | Role-based access, cashier shifts and cash close, discount/refund approvals, staff activity and payroll expenses | **Partial, in pilot.** Fixed staff roles, property-scoped invitations, owner role changes and audit events exist. Cashier shifts, shift reconciliation, configurable approval rules for discounts/refunds and payroll are not implemented. |

## Suggested delivery order

1. **Prepare a safe hotel pilot:** confirm live migrations, roles and property boundaries; complete backup/restore setup, monitoring, and a live hotel workflow.
2. **Finish current operations and finance:** refine property setup and housekeeping, validate reports with hotel books, then add discounts/complimentary stays and stronger owner metrics.
3. **Build the POS:** create department menus and cashier sessions, capture payments, and post sales to a guest folio or selected payment account.
4. **Build inventory and procurement:** add suppliers, purchase receiving, stock movements, waste/adjustments and low-stock reports; connect stock costs to accounting.
5. **Add advanced controls and reports:** add shift reconciliation, configurable approvals, supplier payables, receivables aging, balance sheet, cash-flow statement, departmental reporting and cross-property comparisons.

POS and stock activity should create traceable accounting entries, not separate totals outside the ledger.

## Long-term target capabilities

The following list is the full target, not a claim that every item has shipped. Use the module status table above to distinguish current pilot features from planned work.

### Target capabilities

1. **Organization and setup:** create an organization, one or more properties, local address/contact details, NGN currency, configurable check-in/out times, room types, rooms, taxes/fees, payment methods, chart of accounts, and opening balances.
2. **Reservations:** direct booking entry, availability by date, guest profile, room assignment, rate/discount, deposit, source/channel, notes, cancellation/no-show, and confirmation/receipt print view.
3. **Front desk:** arrivals/departures list, check-in/out, room move, walk-in booking, occupancy/room board, guest search, folio review, and payment receipt.
4. **Housekeeping:** room status updates, clean/dirty/inspected/out-of-order states, assignment, and a simple task queue.
5. **Folio and payments:** room charges, taxes/fees, extras, deposits, split/partial payments, refunds, balance due, and a printable folio.
6. **Accounting:** double-entry general ledger, standard account list, posting rules for PMS events, expense entry with category/vendor/receipt, cash and bank accounts, reconciliation-ready payment references, trial balance, income statement, and cash movement report.
7. **Owner dashboard:** occupancy, ADR, RevPAR, room revenue, other revenue, expenses, net income, cash collected, outstanding folio balance, and transaction drill-down for a selected period/property.
8. **Access and audit:** roles, property access, activity history for sensitive changes, export to CSV, and daily backup/export procedure.

### Defer until the first hotels validate the workflow

Online booking engine/channel manager, OTA synchronization, external POS integrations, automated bank feeds, automated tax filing, multi-currency, loyalty, guest messaging automation, advanced budgeting, and native mobile apps. The six requested core modules, including inventory/procurement and payroll expense records, remain in the active scope; the phased sequence is in `docs/engineering-roadmap.md`. Keep integration points in the data model, but avoid building them before staff validate daily use.

## Target roles and core flows

| Role | Main job | Typical permissions |
|---|---|---|
| Owner | Owns the workspace and controls access | All assigned properties, operations, finance, staff invitations and role changes; can reconcile balances |
| Manager | Runs hotel operations | Reservations, room operations, guest records, finance reports and paid expenses for assigned properties; cannot invite staff or change roles |
| Front desk | Handles bookings and guest stays | Reservations, check-in/out, folios, deposits, guest payments, room moves and early checkout; no expense reports |
| Accountant | Records and reviews finances | Paid expenses and receipts, financial reports, reconciliation and guest directory; no front-desk or reservation screens |
| Housekeeping | Prepares rooms | Room board and housekeeping status; no guest records, reservations or finance screens |

**Reservation flow:** Search dates and room type → compare available rooms/rates → create guest and reservation → assign room → record deposit if received → issue confirmation. At arrival: verify reservation → check room readiness → check in → add charges/payments through folio. At departure: settle/record balance → check out → room becomes dirty → housekeeping completes and marks clean/inspected.

**Expense flow:** Select property and payment account → enter date, supplier, category, amount, description and optional receipt → save draft → manager/accountant posts → journal is created → owner can drill from expense report to source and receipt. Refunds and voids use explicit reversal entries and reason codes.

**Owner review flow:** Choose property and date range → see metric cards and trend → inspect room revenue, other income, and expenses → open any amount to see source records and journal lines → export report. Show whether figures use stay date, transaction date, or cash date.

## Accounting and metric rules

Use an accrual-based, double-entry general ledger as the reporting source of truth. PMS folios are guest subledgers; they do not replace the general ledger. For every posted journal, total debits must equal total credits, and each line belongs to one property and account.

Illustrative mappings (final account/tax treatment is configurable and should be confirmed with the hotel's accountant):

- **Room charge posted:** Dr Guest receivable / Cr Room revenue; tax portion credits tax payable.
- **Cash/card/bank payment collected:** Dr selected cash/bank/clearing account / Cr Guest receivable.
- **Expense paid immediately:** Dr expense account (and eligible tax input account if configured) / Cr cash or bank.
- **Supplier bill entered but unpaid:** Dr expense / Cr accounts payable; payment later clears payable.
- **Refund:** reverse the original revenue/receivable/payment treatment with linked reason and original transaction.
- **Deposit:** record as guest deposit liability until applied to the stay; applying it reduces the folio receivable and deposit liability.

Do not call cash received “revenue” without labeling it. The dashboard separates **recognized revenue** (posted income statement), **payments collected** (cash movement), and **net income** (recognized revenue less recognized expenses, under the configured accounting basis). Define ADR as room revenue ÷ rooms sold; RevPAR as room revenue ÷ available room nights. Exclude out-of-order room nights only through an explicit report setting. Occupancy = occupied room nights ÷ available room nights. Do not include taxes in revenue when the configured mapping treats them as liabilities.

Store monetary values in `bigint` kobo; never use floating point for amounts. Store timestamps as `timestamptz`, save the property's IANA timezone (default `Africa/Lagos`), and retain the property's local business date for night audit/report boundaries. Room night and tax rounding rules should be explicit and consistent.

## Page architecture

```text
/auth/sign-in
/onboarding/organization
/app/[orgSlug]/overview
/app/[orgSlug]/front-desk
/app/[orgSlug]/reservations
/app/[orgSlug]/reservations/new
/app/[orgSlug]/reservations/[reservationId]
/app/[orgSlug]/rooms
/app/[orgSlug]/housekeeping
/app/[orgSlug]/guests
/app/[orgSlug]/finance/overview
/app/[orgSlug]/finance/expenses
/app/[orgSlug]/finance/ledger
/app/[orgSlug]/reports
/app/[orgSlug]/settings/property
/app/[orgSlug]/settings/rooms
/app/[orgSlug]/settings/team
```

Keep the active organization/property context in the app shell. The same page can filter to one property or an explicitly authorized all-property view. Responsive navigation collapses into a drawer; common tasks remain reachable in two taps.

## Supabase and tenant isolation

Use Supabase Auth for identity, but never trust a tenant ID supplied by the browser. Resolve the active organization from an authenticated user's `organization_memberships` row and check property membership for every read and mutation. Enable RLS on every tenant-owned table. Use policies that join the row's `organization_id` (and where relevant `property_id`) to the caller's active membership; do not rely on a client-side filter or a hidden selector.

For privileged actions (check-in/out, posting a payment, posting an expense/journal, refunds, changing a posted transaction), call a server-side function/RPC that validates membership, role, property scope, current state, and idempotency key in one transaction. The Supabase service key stays server-only. Prefer database constraints and triggers for invariants such as balanced journals, positive amounts, valid stay dates, and immutable posted journals. Audit user ID, action, entity, timestamp, and before/after values for security-sensitive changes.

A single organization can own multiple properties. Start with organization-level roles plus an optional allowed-property list. If property-scoped staff access is needed, use `membership_properties`; absence of rows can mean all properties only for roles explicitly configured that way. Test RLS as two separate users/organizations before launch.

## MVP delivery sequence

1. **Discovery and prototype:** interview 3–5 Calabar hotel teams (owner, front desk, accountant/manager, housekeeping); validate room-night, deposit, cash/card, expense and month-end workflows; test these wireframes.
2. **Foundation:** auth, organization/property setup, membership roles, RLS, audit events, room configuration, and tenant-safe shell.
3. **Stay operations:** guest, availability, reservation, room board, check-in/out, folio, payment and receipt. Add idempotent transitions and transaction history.
4. **Ledger:** chart of accounts, source mappings, posting RPCs, expenses, reversal workflow, and reports reconciled against sample manual books.
5. **Owner view and pilot:** dashboard drill-down, exports, staff onboarding, one-property pilot, daily reconciliation feedback, and fixes before adding integrations.

## Decisions to validate with the first hotels

- Do they sell by night only, or also by day-use/hourly stays?
- Can one reservation include several rooms and several guests? (Schema supports this; initial UI can create them separately.)
- Which taxes/levies/fees are charged, how are they rounded, and which are pass-through liabilities?
- Which payment methods matter in practice (cash, POS/card, bank transfer, mobile money), and what constitutes a confirmed transfer?
- What is their night audit/business-day cut-off, and can a stay cross midnight differently from the calendar day?
- Do owners need property-level accounting books or consolidated reporting across properties?
- Which staff can discount, waive, void, refund, or reopen a closed folio, and what approval is required?
- What reports and export format does their accountant need at month end?

## Wireframe guide

Open [hotel-pms-wireframes.html](hotel-pms-wireframes.html) in a browser. It contains an interactive desktop app shell with Overview, Front desk, Reservations, Rooms, and Finance screens. The screens are intentionally mid-fidelity: they demonstrate information hierarchy and core actions, while labels, cards, tables, and values can be edited directly in the HTML source. The layout is responsive and includes a property/date selector, navigation, drill-down cues, and realistic Nigerian Naira examples.
