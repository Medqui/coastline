# Staff identities and shifts — 5 October 2026

The existing hotel application now supports named staff identities and operational shifts. Database releases 017 (identity/shift/handover) and 018 (hosted pgcrypto compatibility) are applied to the linked Supabase project. The generated full installer contains all 19 migrations.

## How staff use it

1. Each person signs in with their own account. Owner invitations now require full name, email, property and role. Acceptance preserves that name on the hotel membership.
2. Existing staff can expand **Set my full name** in **My identity & shift**. Owners can also save names in Staff. Name changes do not change login credentials or permissions.
3. Select **Start my shift**. The panel displays the signed-in name, role, start time and on-duty status. There is at most one operational shift per person per hotel, across properties. Repeated starts are safe.
4. Work using existing role access. Existing actor IDs remain on operational/accounting records. Audit events created during an active shift are linked to its shift ID. Actions taken off duty retain actor attribution but do not have a shift link; this increment does not require a shift before every action.
5. Reconcile any cashier shift, write the handover, then select **End shift & save handover**. An open cashier shift or pending variance review blocks ending the operational shift.
6. Read **Incoming shift handovers** for the next shift. Staff receive completed handovers for their role in the assigned property. Owners/managers can review the whole property. Private cashier receipt totals are removed from other staff’s shared handovers; housekeeping summaries contain no money.

## Handover and cash handling

Ending a shift saves its note and a snapshot of pending arrivals, due/overdue departures, in-house guests and dirty rooms. Authorized operations/finance roles also receive open guest balances and their own gross cash receipts since the shift started. Cash receipts are not a cash reconciliation figure: the existing cashier workflow handles opening float, refunds, counted cash and variance approvals. Shift history preserves the name and role as they were at start even if a staff name or role later changes.

The Front Desk/Housekeeping dashboard now replaces empty revenue/profit cards with departures and ready-room counts. Owner role displays correctly as protected Owner in Staff.

## Verification

- Lint, TypeScript, production build and 13 existing navigation/read-retry tests pass.
- 20 staff identity/shift/invitation/privacy checks pass locally and on hosted Supabase. All synthetic test users, hotel, shifts and cashier records roll back.
- Hosted acceptance found and fixed an existing invite bug: pgcrypto was installed outside `public`, while invitation RPCs expected public-qualified functions. Release 018 adds compatible aliases without moving the extension; both creation and acceptance then passed.
- The actual app displays Tomiwa Ale, Owner and the active shift. The active user shift was preserved; it was not ended for testing. Staff shows the full-name invitation field and owner name management.
- CI now includes the repeatable SQL shift acceptance scenario. Remote CI and independent browser sign-ins for each staff role were not run in this pass.

## Boundaries

This is actual shift start/end and handover tracking, not a planned rota, payroll/timesheets, forced clock-out or staff reassignment workflow. Staff notes can describe pending guest/room issues; automated handover entries are operational counts and financial totals rather than a per-guest task list. Owner/manager history shows the latest 50 property shifts and shared handovers the latest 20. The active personal shift is loaded separately so history limits cannot hide it.
