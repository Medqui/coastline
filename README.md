# Coastline PMS

A Next.js and Supabase hotel operations and accounting app for independent hotels in Calabar.

## Current pilot workflow

- Email sign-in, organization onboarding, property rooms, and role-checked access.
- Direct reservations with overlap checks, guest directory, cancellation and no-show controls.
- Housekeeping status, check-in, room-night charging, extras, deposits, payments, refunds, and checkout.
- Balanced, immutable journals for posted financial events, categorized paid expenses with private receipt uploads, financial statements, guest aging, and CSV bank-statement matching.
- Multiple property setup and switching, property-scoped staff invitation links and role management, date-range availability, in-house room moves, early checkout, printable folios, and a monitoring health endpoint.

Run all SQL files in `supabase/migrations` in filename order before using the connected app. See `supabase/README.md` for the exact setup sequence and current limits. For staff roles and daily workflows, see the [staff user manual](docs/user-manual.md). The first feature release still uses manual copy-and-share invitation links and does not send invitation emails.

## Run locally

1. Install Node.js 20.9 or newer.
2. Copy `.env.example` to `.env.local` and set your Supabase project URL and publishable key. Keep service-role credentials out of the browser.
3. Run `npm install`, then `npm run dev` and open `http://localhost:3000`.
4. Sign up or sign in, then create your hotel on `/onboarding`.

To run the database integration suite, install the Supabase CLI and Docker, start the local stack with `supabase start`, then run `npm run test:db`. CI runs the migrations and this suite against a fresh local database.

CI also runs `python3 scripts/test-booking-concurrency.py` with the local PostgreSQL client. This test refuses a database containing hotel organizations and must run on a fresh disposable local stack. It checks overlapping bookings, saved nightly prices, and the separation between quotes and revenue.

Without environment variables, the dashboard opens in a sample-data preview.

## Data rules

All money is stored as integer kobo and displayed as naira. Reservation quotes are not revenue. Completed room nights and extra charges recognize revenue; advance deposits remain liabilities until applied. Every posted journal has matching debit and credit totals, and tenant-owned tables use row-level security.

The full product plan and deferred workflows are in `docs/product-blueprint.md`. The six-module implementation sequence and engineering gates are in [docs/engineering-roadmap.md](docs/engineering-roadmap.md).
