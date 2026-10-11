"""Receipt retry, reference and over-refund races on a disposable local database.

Synthetic fixtures are deliberately retained for inspection, like booking races.
Run after rollback/replay tests; never against a connected customer database.
"""
import concurrent.futures
import os
import subprocess
import uuid
from urllib.parse import urlsplit

url = os.environ.get('PMS_TEST_DATABASE_URL', 'postgresql://postgres:postgres@127.0.0.1:54322/postgres')
if urlsplit(url).hostname not in {'localhost', '127.0.0.1'}:
    raise SystemExit('Receipt races require a disposable local database.')
owner, admin, request = [str(uuid.uuid4()) for _ in range(3)]
reference = 'receipt-race-' + request

def execute(sql):
    return subprocess.run(['psql', '-X', '--dbname', url, '-v', 'ON_ERROR_STOP=1', '-q', '-t', '-A'], input=sql, capture_output=True, text=True, timeout=45)

def must(sql):
    result = execute(sql)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:])
    return result.stdout.strip()

must(f"""begin;
insert into auth.users(id,email,raw_user_meta_data) values('{owner}','race-owner-{owner}@test.local','{{}}'),('{admin}','race-admin-{admin}@test.local','{{}}');
insert into public.saas_platform_admins(user_id) values('{admin}');
set local request.jwt.claim.sub='{owner}';
select * from public.setup_hotel('Receipt concurrency test','Synthetic property',null,1,100000);
commit;""")
org = must(f"select organization_id from public.organization_memberships where user_id='{owner}';")

def authenticated(expression):
    return f"begin; set local request.jwt.claim.sub='{admin}'; set local role authenticated; select {expression}; commit;"

def payment(request_id, ref):
    return authenticated(f"public.record_subscription_receipt('{request_id}','{org}','business','payment',null,1000000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','{ref}','Synthetic race payment')")

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    retry_results = list(pool.map(execute, [payment(request, reference)] * 5))
assert all(result.returncode == 0 for result in retry_results), 'A same-request retry failed'
ids = {result.stdout.strip() for result in retry_results}
assert len(ids) == 1, 'Concurrent retries returned different receipts'
payment_id = ids.pop()
assert must(f"select count(*) from public.saas_subscription_receipts where request_id='{request}';") == '1', 'A retry was counted twice'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    refs = list(pool.map(execute, [payment(str(uuid.uuid4()), reference + '-duplicate') for _ in range(2)]))
assert sorted(result.returncode == 0 for result in refs) == [False, True], 'Duplicate bank references both succeeded'
refunds = [authenticated(f"public.record_subscription_receipt('{uuid.uuid4()}','{org}','business','refund','{payment_id}',700000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','{reference}-refund-{n}','Synthetic refund race')") for n in range(2)]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(execute, refunds))
assert sorted(result.returncode == 0 for result in results) == [False, True], 'Concurrent refunds exceeded the original payment'
assert must(f"select sum(amount_kobo) from public.saas_subscription_receipts where original_payment_id='{payment_id}';") == '700000', 'Refund sum is incorrect'
print('PASS: five concurrent retries record once, duplicate references reject, and concurrent refunds cannot exceed the original payment.')
