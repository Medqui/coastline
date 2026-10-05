"""Verify booking, supplier-invoice and payment serialization against a fresh disposable local database.

Supabase local defaults are used unless PMS_TEST_DATABASE_URL is provided.
The fixture is left in this disposable database for inspection; reset the local
stack before rerunning. An existing organization causes the test to refuse writes.
"""

import concurrent.futures
import json
import os
import subprocess
import uuid
from urllib.parse import urlsplit


database_url = os.environ.get(
    "PMS_TEST_DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
)
if urlsplit(database_url).hostname not in {"127.0.0.1", "localhost"}:
    raise SystemExit("Concurrency tests require a disposable local database.")


def execute(sql):
    return subprocess.run(
        ["psql", "--no-psqlrc", "--dbname", database_url, "-v", "ON_ERROR_STOP=1", "-q", "-t", "-A"],
        input=sql, text=True, capture_output=True, timeout=15,
    )


def checked(sql):
    result = execute(sql)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


if checked("select count(*) from public.organizations;") != "0":
    raise SystemExit("Use a fresh disposable database; existing hotel organizations were found.")

user_id = str(uuid.uuid4())
setup = checked(f"""
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('{user_id}','authenticated','authenticated','concurrency-{user_id}@test.local','',now(),'{{}}','{{}}',now(),now());
select set_config('request.jwt.claim.sub','{user_id}',false);
select organization_id::text||'|'||property_id::text
from public.setup_hotel('Concurrency verification','Concurrency property',null,1,1000000);
""")
organization_id, property_id = next(line for line in setup.splitlines() if "|" in line).split("|")
organization_id = str(uuid.UUID(organization_id))
property_id = str(uuid.UUID(property_id))
room_id = str(uuid.UUID(checked(f"select id from public.rooms where property_id='{property_id}';")))

booking_sql = f"""begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','{user_id}',true);
select public.create_priced_reservation('{organization_id}','{property_id}','{room_id}',
  'Concurrent guest',null,null,current_date+10,current_date+12,1::smallint,null);
select pg_sleep(0.3);
commit;
"""
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(execute, [booking_sql, booking_sql]))
if sorted(result.returncode == 0 for result in results) != [False, True]:
    raise AssertionError([(result.returncode, result.stderr) for result in results])
if "already reserved" not in next(result.stderr for result in results if result.returncode):
    raise AssertionError("The conflicting attempt failed for a reason other than overlap.")

reservations = int(checked(f"select count(*) from public.reservations where property_id='{property_id}';"))
nightly_rows = int(checked(f"select count(*) from public.reservation_night_rates where property_id='{property_id}';"))
quoted_kobo = int(checked(f"select sum(charged_rate_kobo) from public.reservation_night_rates where property_id='{property_id}';"))
journals = int(checked(f"select count(*) from public.journals where property_id='{property_id}';"))
assert reservations == 1, reservations
assert nightly_rows == 2, nightly_rows
assert quoted_kobo == 2000000, quoted_kobo
assert journals == 0, journals
print(json.dumps({
    "scenario": "two concurrent same-room bookings", "successful_bookings": 1,
    "rejected_conflicts": 1, "stored_reservations": reservations,
    "saved_nightly_prices": nightly_rows, "quoted_kobo": quoted_kobo, "revenue_journals": journals,
}))

# Continue in this script's own disposable fixture; never touch a shared hotel.
auth_sql = f"set local role authenticated; select set_config('request.jwt.claim.sub','{user_id}',true);"
today_sql = "(now() at time zone 'Africa/Lagos')::date"
method_id = str(uuid.UUID(checked(f"select id from public.payment_methods where property_id='{property_id}' and clearing_account_code='1010' limit 1;")))
department_id = str(uuid.UUID(checked(f"select id from public.departments where property_id='{property_id}' and code='restaurant';")))
supplier_result = checked(f"""begin; {auth_sql}
select public.save_supplier('{property_id}',null,'Concurrency supplier',null,null,null,true); commit;""")
supplier_id = str(uuid.UUID(supplier_result.splitlines()[-1]))


def create_bill(number, amount, key):
    return f"""select public.post_supplier_bill('{property_id}','{supplier_id}','{number}',{today_sql},{today_sql},{today_sql},
      'Concurrent supply bill','5010','{department_id}',{amount},'{key}');"""


def payment(bill, amount, key):
    return f"""select public.pay_supplier_bill('{bill}','{method_id}',{today_sql},{amount},'Synthetic test transfer','{key}');"""


def race(statements):
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(execute, [f"begin; {auth_sql} {sql} select pg_sleep(0.3); commit;" for sql in statements]))


bill_result = checked(f"begin; {auth_sql} {create_bill('RACE-1', 10000, 'race-bill-one')} commit;")
bill_id = str(uuid.UUID(bill_result.splitlines()[-1]))
results = race([payment(bill_id, 7000, 'race-payment-one'), payment(bill_id, 7000, 'race-payment-two')])
assert sorted(r.returncode == 0 for r in results) == [False, True], [(r.returncode, r.stderr) for r in results]
assert 'exceed the unpaid bill balance' in next(r.stderr for r in results if r.returncode)
assert checked(f"select count(*)||'|'||sum(amount_kobo) from public.supplier_bill_payments where bill_id='{bill_id}';") == '1|7000'
balance = checked(f"begin; {auth_sql} select outstanding_kobo from public.get_supplier_bill_balances('{property_id}',{today_sql}) where bill_id='{bill_id}'; commit;").splitlines()[-1]
assert balance == '3000', balance
print(json.dumps({'scenario': 'two concurrent supplier payments above combined balance', 'successful_payments': 1, 'rejected_overpayments': 1, 'outstanding_kobo': 3000}))

results = race([create_bill('RACE-2', 10000, 'race-bill-two-a'), create_bill('RACE-2', 10000, 'race-bill-two-b')])
assert sorted(r.returncode == 0 for r in results) == [False, True], [(r.returncode, r.stderr) for r in results]
assert 'invoice has already been recorded' in next(r.stderr for r in results if r.returncode)
assert checked(f"select count(*) from public.supplier_bills where property_id='{property_id}' and bill_number='RACE-2';") == '1'
assert checked(f"select count(*) from public.journals where property_id='{property_id}' and source_type='supplier_bill';") == '2'
print(json.dumps({'scenario': 'same supplier invoice with concurrent different references', 'recorded_bills': 1, 'rejected_duplicates': 1, 'orphan_bill_journals': 0}))

bill_result = checked(f"begin; {auth_sql} {create_bill('RACE-3', 10000, 'race-bill-three')} commit;")
bill_id = str(uuid.UUID(bill_result.splitlines()[-1]))
results = race([payment(bill_id, 7000, 'race-payment-same-key')] * 2)
assert all(r.returncode == 0 for r in results), [(r.returncode, r.stderr) for r in results]
# Inspect the durable record instead of relying on whitespace in psql output.
assert checked(f"select count(*)||'|'||sum(amount_kobo) from public.supplier_bill_payments where bill_id='{bill_id}';") == '1|7000'
assert checked(f"select count(*) from public.journals where property_id='{property_id}' and idempotency_key='supplier-payment:race-payment-same-key';") == '1'
print(json.dumps({'scenario': 'same supplier payment submitted concurrently', 'successful_requests': 2, 'recorded_payments': 1, 'payment_journals': 1}))

assert checked(f"select count(*) from (select j.id from public.journals j join public.journal_lines l on l.journal_id=j.id where j.property_id='{property_id}' and j.status='posted' group by j.id having sum(l.debit_kobo)<>sum(l.credit_kobo)) x;") == '0'
assert checked(f"select sum(l.debit_kobo-l.credit_kobo) from public.journal_lines l join public.journals j on j.id=l.journal_id join public.accounts a on a.id=l.account_id where j.property_id='{property_id}' and j.status='posted' and a.code='5010';") == '30000'
print(json.dumps({'scenario': 'accounting integrity after concurrent writes', 'unbalanced_journals': 0, 'recognized_supplier_expense_kobo': 30000}))
