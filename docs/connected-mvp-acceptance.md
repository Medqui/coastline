# Connected MVP acceptance — 5 October 2026

Application: existing localhost Next.js app connected to project `ctsqpmuzdluggaemkxmt`. The original Kings property is currently named **Delvin**. Existing organization membership, rooms and real/sample stays were preserved. No bank transfer, purchase or real cash movement was performed.

## Hosted deployment

CLI dry-run identified two unrecorded migrations: `20261005000100_cashier_shifts_and_refund_approvals.sql` and `20261005000200_property_configuration_and_stock.sql`. Both were applied successfully. Some objects were already present, and the migrations safely reused them. Hosted migration history now includes all 17 versioned migrations; all four configuration/inventory tables are present. Settings, Inventory and cashier controls load successfully.

## Connected owner workflow

| Check | Observed result |
|---|---|
| Create TEST room type | `TEST MVP 05 Oct 2026`, capacity 2, base rate ₦100 saved |
| Create TEST floor | `TEST MVP Floor 05 Oct 2026` saved |
| Create physical room | `TEST-1005` appeared in live Rooms as Dirty |
| Clean room | Housekeeping saved Clean; Rooms showed Available |
| Book room | Quote ₦100 for 5–6 October; status became Reserved |
| Check in | Front Desk saved In-house; guest appeared in POS |
| Charge to room | Labeled ₦25 service charge appeared in guest folio |
| Record synthetic Cash payment | Labeled ₦25 receipt settled the folio to ₦0 |
| Same-day early checkout | Reservation became Checked out; physical room became Dirty |
| Retire test configuration | Test room and room type deactivated; no active booking remained |
| Create TEST stock item | `TEST MVP Water 05 Oct 2026`, unit bottle, par level 8 |
| Receive 10 units | On-hand 10, In stock, immutable receipt history appeared |
| Issue 3 units | On-hand 7, Low stock, issue history appeared |
| Attempt issue of 8 units | Rejected with “Stock issued cannot exceed the quantity on hand”; on-hand stayed 7 |
| Remove remaining synthetic quantity | Correcting issue of 7 returned on-hand to 0; original movements remain |
| Navigation after saves | URL stays on the selected module after the fix; Inventory saves retained `#inventory` |
| Browser back/forward | Correct Reservations/Inventory screen restored |

The browser workflow used early checkout so it could finish on the same day. The original ₦100 overnight quote did not become room revenue: no night was completed in this browser fixture. Standard scheduled-departure checkout remains to be verified with a suitable due-out fixture.

## Hosted database verification

29 configuration, role and property-boundary assertions passed in a transaction that rolled back every synthetic auth user, hotel, role change, room, booking and stock record. These include owner configuration, manager assigned-property access, denied unassigned properties, accountant inventory access/write, denied accountant configuration, denied front-desk inventory access/write, allowed housekeeping cleaning, denied housekeeping configuration/reservations/inventory, active-booking deactivation guards, preserved nightly booking prices, immutable stock movements and idempotent receiving.

12 overnight lifecycle/accounting assertions passed in a separate rolled-back transaction: actual hosted booking/check-in, one completed room night, repeat-posting idempotency, room/extras balance, unpaid-checkout rejection, payment retry idempotency, full settlement, property-local early checkout, closed folio, dirty room, balanced journals and matching financial summary. Both scenarios verified that their temporary auth users were absent afterward. These test database authorization as the authenticated role with controlled claims; they do not constitute separate browser sign-ins for each staff role.

## Fix and code verification

Server-action refreshes initially restored an old hash URL because navigation only assigned `window.location.hash`. Navigation now uses the Next.js-integrated native History API and restores state on `popstate`. Manual connected saves and browser back/forward verify the fix. Lint, TypeScript and all 13 navigation/read-retry tests pass; the production build passes. CI retains existing pgTAP/concurrency suites and now also runs the configuration and overnight SQL scenarios. Remote CI has not been run in this pass.

## Retained test artifacts

Only records labeled TEST/MVP were created in Delvin. Room `TEST-1005` and its type are inactive. The test floor, checked-out guest/reservation, closed zero-balance folio and audit records remain for inspection. The ₦25 synthetic service charge and ₦25 synthetic cash receipt remain immutable posted facts in the test hotel, so they add ₦25 to reported income and recorded cash; they are not actual money movement. The test stock item remains with zero on-hand quantity and par level 8, with its receipt/issue/correction history intact.

Remaining connected acceptance: separate staff-role logins; standard departure-day checkout; broader deposit/refund/cashier-close scenarios. These remain distinct from the completed database role and overnight posting checks.

Evidence files in task outputs: `Test-room-created.png`, `Test-folio-settled.png`, `Test-stay-checked-out.png`, `Test-room-after-checkout.png`, `Stock-overdraw-rejected.png`, `Inventory-verified.png`.
