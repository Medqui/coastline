# Coastline PMS operations runbook

## Database backups

- In the Supabase project dashboard, enable the scheduled database backups available on the project’s subscription and confirm the retention period with the project owner.
- Before every schema release, export a fresh database backup and save a copy outside the Supabase project.
- Once per month, restore the latest backup into a separate non-production project and confirm users, properties, room inventory, folios, expenses, and journals are present. Do not use the live hotel project for restore drills.
- Keep receipt files in the private `expense-receipts` bucket. Include the bucket in the project’s storage backup/export procedure; a database-only backup does not include the file contents.
- Restrict dashboard access and database credentials to the owner and designated technical administrator. Never put the service-role key in the Next.js public environment.

## Availability monitoring

- Check `GET /api/health` from an external uptime monitor every five minutes. HTTP 200 means the app can reach Supabase; HTTP 503 means configuration or database access needs attention. The endpoint returns no credentials or customer data.
- Alert the technical administrator after two consecutive failures. Check the hosting deployment, Supabase project status, database availability, and configured public Supabase URL/key.
- Review Supabase Auth, database, and storage usage at least weekly during the pilot. Investigate repeated failures and unusual storage growth.

## Daily hotel close

- At the property’s local close, review in-house folios, post completed room nights, confirm payments against receipts and POS/bank references, and record paid expenses.
- Complete the cash/bank reconciliation for the period before relying on cash balances.
- Export the period’s financial reports and reservation list to the hotel’s approved secure storage.
