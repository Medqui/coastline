# Connected accounting acceptance — Kings

Date: 4 October 2026. Environment: localhost app connected to hosted Supabase. Workspace: Kings, authorized by the user as disposable test data. Session: owner actions available.

## Verified in the connected browser

| Step | Observed result |
|---|---|
| Add synthetic supplier | Supplier appears in the invoice selector and directory |
| Record restaurant invoice dated 3 October | ₦1,000 unpaid; expense and department recognized once |
| Upload synthetic PNG with invoice | Private receipt link appears |
| Open receipt | Image loads with the fixture's actual 240 × 80 dimensions |
| Record ₦400 payment dated 4 October | ₦600 owed; one payment record appears |
| View balances as of 3 October | ₦1,000 owed; later payment excluded; no payment shown |
| Refresh account and department P&L | ₦1,000 food/beverage expense and matching Restaurant expense; ₦5,000 net income |
| Trial balance after partial payment | Debits and credits both ₦9,600 |
| Reverse synthetic payment | ₦1,000 owed again; original payment retained with reversal date and reason |
| Void synthetic unpaid invoice | ₦0 owed; original invoice retained as Void; current net recognized expense returns to zero |
| Open owner overview | ₦6,000 recognized revenue, ₦6,000 net income, 5% occupancy (1 of 19 active rooms) |

The test did not transfer money or purchase goods. The supplier, invoice, payment, linked corrections, attachment and audit records remain in Kings. They are clearly labeled TEST or synthetic. The payment reversal and bill void remove the current financial effect without deleting posted records.

## Reliability change

One finance read request failed temporarily and recovered with the existing Refresh controls. The application now retries recognized transport, timeout, rate-limit and gateway failures up to three total attempts with bounded delays. Only read queries use this helper. Authentication, permission, schema and database errors are not retried. Reconciliation lists are cleared on reload and report errors explicitly, preventing a failed refresh from leaving an old list visible.

Eight helper regressions pass; lint, TypeScript and production build pass. CI includes these regressions. The tests cover the retry helper, not every possible browser/network condition. The production build retains the existing metadataBase warning for social image URLs.

## Remaining connected acceptance

- Separate manager, accountant, front desk and housekeeping sessions; property and tenant boundary acceptance through hosted auth and storage.
- Receipt replacement was submitted; final replacement bytes and attachment retry after an interrupted upload still need verification.
- Historical reports after the void, private receipt denial without authorization, export/download and reconciliation workflows.
- Full booking-to-checkout regression across staff roles.

Local database suites already cover permitted and denied roles and immutable correction history. They do not replace these connected checks. This milestone does not establish launch readiness or complete the six-module product.

Evidence: `supplier-historical-balance-test.png` and `kings-owner-dashboard.png`.
