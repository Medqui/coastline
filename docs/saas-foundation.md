# SaaS foundation — 11 October 2026

Releases 019–022 add organization subscriptions, database-enforced feature access and capacity limits, and a separate `/platform` dashboard. `/subscription` explains the plan inside each hotel workspace. Subscription management is manual in this release; online payment collection, automatic billing, taxes and payment-provider webhooks are not connected. Launch pricing and manually recorded subscription collections are available.

## Plans

| Plan | Monthly launch price | Properties | Active staff including owners | Features |
| --- | --- | --- | --- | --- |
| Starter | ₦15,000 | 1 | 5 | Reservations, availability, check-in/out, housekeeping, guest folios, deposits, receipts, expenses, basic accounting/dashboard and basic exports |
| Business | ₦35,000 | 1 | 15 | Starter plus inventory, supplier accounts, detailed financial reports, bank statement reconciliation, staff shifts and handovers |
| Group | From ₦75,000; custom quotes for larger groups | Unlimited in this release | Unlimited in this release | Business plus multiple properties and property comparisons |

Safety controls for collecting cash, reconciling cashier shifts and approving refunds remain available on every plan. Staff operational shifts and handovers are the Business feature. Staff capacity includes distinct outstanding invitations; accepting a reserved invitation does not consume a second seat. Concurrent capacity requests serialize at organization level. A downgrade is rejected while staff or property usage exceeds its limits.

## Subscription lifecycle

New organizations automatically receive a 14-day Business trial. Organizations present before release 019 retain unrestricted Group pilot access and are excluded from paying-customer/MRR counts. The platform administrator must explicitly assign a plan to replace pilot access. Migration replay preserves existing subscription assignments.

Trials and dated active/past-due subscriptions enter a seven-day grace period after their end date. Hotel operations continue during grace. After grace, writes are blocked in the database and receipt uploads are restricted; retained records and exports remain available under the assigned plan. Explicit `expired` status is immediately read-only. Cancelled subscriptions remain accessible until their recorded period end, then become read-only. Active subscriptions without an end date remain active until manually changed. Renewing restores writes without recreating records.

Triggers enforce plan and write access inside existing authenticated RPCs, including direct calls. Restrictive read policies and guarded reporting RPCs gate premium modules. Existing tenant/property and role checks remain in force. Genuine database-administrator maintenance without an end-user identity is allowed so migrations can replay without modifying retained hotel facts; authenticated requests cannot use that exemption.

## Platform access and reporting

Platform administration is explicitly recorded in `saas_platform_admins`, separate from hotel membership and never inferred from owner roles or editable Auth metadata. The deployment bootstraps `aletomiwa@gmail.com` only for a verified Auth account. Release 020 reserves the same requested email when it does not yet exist; an Auth trigger activates the grant only after that address is verified, then consumes the private enrollment. Other administrators must be provisioned by a database administrator; hotel clients have no insert or update privileges on platform roles, plans or subscriptions. No service-role key is required in the frontend.

The platform RPC returns customer organization metadata, owner contact, property/room/staff counts, subscription status and last operational audit timestamp. It does not return guest names, folios or hotel revenue. Platform privilege does not automatically grant access to any hotel workspace.

An onboarded customer has configured active rooms and an active hotel owner. Customer organizations and individual properties are counted separately. Active customers have operational audit activity in the last 30 days, excluding setup/invitation/profile events. Test workspaces are excluded by default. Paying customers are non-pilot, active, currently accessible subscriptions with a positive configured fee. MRR is the sum of their configured monthly amounts, not evidence that payments were collected.

Subscription changes require platform access and a reason. The database records the actor, previous assignment, new assignment and reason in `saas_platform_events`. Setting a monthly amount records pricing only; it does not charge anyone.

The platform directory exposes **Upgrade plan** for higher tiers and **Activate plan** for trial or pilot customers. The dedicated flow previews the selected tier’s features, accepts an optional billing end date and agreed fee, and requires a reason. Before saving, the server rechecks platform membership and the customer’s latest plan. Upgrades set status to active, preserve the workspace’s test classification, and reject an already ended billing period. The existing database RPC applies capacity checks and records the change; both the platform and hotel subscription pages are revalidated. **Manage** remains available for other subscription changes.

## Verification

- Lint, TypeScript checks, production build and 26 navigation/read-retry/subscription-upgrade/receipt tests pass.
- `scripts/test-saas.sql` exercises owner impersonation attempts, direct subscription writes, platform authorization, cross-tenant subscription reads, core and premium feature gates, pending-invitation capacity, accepting a reserved invitation at full capacity, Group upgrades, invalid downgrades, grace/expiry/renewal, retained records, receipt upload restrictions and subscription audits, and verified-email activation of a private platform enrollment. Its fixtures are rolled back.
- Existing property configuration, staff shifts and stay lifecycle SQL scenarios pass on disposable PostgreSQL 16.
- Populated migration replay and repeated installer checks preserve exact stored records, including expired hotel records, and current pricing permissions.
- Concurrent booking/payment/stock checks pass, as do new races for the final Starter staff seat and first Business property.
- The linked Supabase migrations applied successfully; the connected application's `/api/health` responds successfully. The complete SaaS authorization, capacity, lifecycle and enrollment scenarios also passed on the hosted database in one rolled-back transaction.
- The full pgTAP suite is configured in CI; local integration testing used the isolated SQL scripts above.
- Interactive platform acceptance passed after the administrator signed up and verified their email. The dashboard displays the intended administrator account and the real customer organization with two properties and preserved pilot access. Overview, Hotels, Subscriptions and Plans navigation, hotel search, keyboard dismissal and focus restoration were checked in the browser. The subscription editor has an opaque dialog, consistent fields, a scrolling body and persistent actions; desktop (1440×900) and phone layouts (390×844 and 320×568) were visually verified. The admin activation dialog was also checked on desktop and phone, including eligible plan display, benefits preview, scrolling, persistent actions and cancellation. The upgrade action tests cover authorization, stale tier choices, active status, pricing precision, preserved test classification, end-date validation, revalidation and database errors. No live subscription was changed during these browser checks.

Regenerate `supabase/repeatable-install.sql` with `python3 scripts/build-repeatable-installer.py` after adding a forward migration. Do not edit a migration already applied to the hosted database. Run rolled-back tests and replay before the concurrency script, which intentionally leaves its synthetic fixtures in a disposable local database.


## Platform collections

The separate Revenue view reports active contracted monthly revenue and its annual projection, received payments less issued refunds, twelve monthly collection buckets, tier totals, overdue monthly amounts and recent history. Catalogue pricing is stored separately from agreed fees. Introducing prices does not activate pilots or reprice existing contracts. Plan cards and new upgrade/activation quotes use Starter ₦15,000, Business ₦35,000 and Group from ₦75,000 monthly.

An admin records only funds already received or refunds already issued, with a date, method, unique reference and note. This does not move money or change plan access. Receipts are immutable and audited. Retries with an identical request UUID return the original receipt. Duplicate references are rejected. Concurrent refunds lock their original payment and cannot over-refund it. Collections retain the originally paid tier, even after a plan upgrade. Refunds inherit the original receipt's test classification. Trials, pilots and test workspaces are excluded from contracted MRR by default; test receipt history never becomes real money just because a customer leaves test mode. Payment history shows the latest 50 rows; aggregate totals include every receipt.

Pricing research reviewed the published [LodgeStatus Nigeria pricing](https://lodgestatus.com/hotel-software/nigeria/) and [OTTO offering](https://www.otto.com.ng/). The launch prices above are the user's chosen product positioning and agreed defaults for this release.

Verification: both forward migrations applied to the linked database and the connected admin loaded real pricing and revenue reporting. The clean local installer, extended rollback-only revenue scenarios, populated replay with custom pricing/receipt preservation, 26 application tests and receipt retry/reference/refund concurrency scenarios passed. Browser acceptance checks cover catalogue prices, payment defaults, desktop and mobile report/form layouts, chart-range selection and cancellation. No customer payment was added or pilot converted during browser testing.
