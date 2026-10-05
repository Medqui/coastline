# Coastline PMS — MVP status (4 October 2026)

## Working pilot flows

- Supabase email authentication, organization/property onboarding, tenant-scoped reads and role-checked mutations.
- Rooms, housekeeping status, direct reservations, overlapping-room prevention, cancellation/no-show with audit, and a searchable guest directory.
- Check-in, room-night posting after each completed night, extras, deposits, deposit application, partial payments, refunds on open folios, printable folio, scheduled checkout, and dirty-room turnover.
- Double-entry posted journals with balanced-entry checks and immutability; paid expense entry; owner summary of room revenue, other revenue, expenses, net guest cash receipts, and open folio balances.
- Front desk and reservation search/filter with CSV for displayed rows.

## Verified

- `npm run build` passed on the Desktop Next.js project.
- All six project migrations applied in a fresh disposable PostgreSQL database.
- Local scenarios passed: reservation → check-in → charges → split payments → expense → checkout; cancellation released the room; deposits and refunds reconciled; every posted journal balanced; another tenant and housekeeping role could not read protected financial data.
- Connected Kings test workspace: ₦5,000 test deposit posted, ₦1,000 advance refunded, room 101 marked clean, and Emeka Okafor checked in. A live ₦2,000 test charge requires the user to submit it because automatic approval review blocked that action. The cash-collected card also needs the final `20261004000500_net_guest_cash_summary.sql` update in Supabase to show the net ₦4,000.

## Remaining before broad hotel use

- Multi-property creation and switching in the app, team invitations and role management.
- Date-range availability search, room moves, early checkout, discounts, no-show deposit handling, and taxes/levies after the hotel's actual rules are agreed.
- Refunds after folio closure, expense categories/receipts, trial balance, income statement detail, reconciliation, ADR/RevPAR, and historical report date selection.
- Backup/export procedure, operational monitoring, and a complete live pilot across an overnight boundary.

Kings is a disposable test workspace. The real room-night charge for the checked-in test stay is due on 5 October 2026 in the property's Africa/Lagos timezone; it was not posted early.
