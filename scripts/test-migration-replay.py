"""Verify populated migration replays on an empty disposable local database.

Requires migrations 000–015. All fixture and replay operations are rolled back.
Refuses nonlocal databases and databases containing hotel organizations.
"""
import os
from pathlib import Path
import subprocess
import uuid
from urllib.parse import urlsplit

root=Path(__file__).resolve().parents[1]
database_url=os.environ.get('PMS_TEST_DATABASE_URL','postgresql://postgres:postgres@127.0.0.1:54322/postgres')
if urlsplit(database_url).hostname not in {'localhost','127.0.0.1'}:
    raise SystemExit('Migration replay tests require a disposable local database.')
def execute(sql):
    return subprocess.run(['psql','-X','--dbname',database_url,'-v','ON_ERROR_STOP=1','-q','-t','-A'],input=sql,text=True,capture_output=True,timeout=90)
check=execute('select count(*) from public.organizations;')
if check.returncode or check.stdout.strip()!='0':
    raise SystemExit('Use a migrated disposable database with no existing hotel organizations.')
user=str(uuid.uuid4())
setup=f"""begin;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('{user}','authenticated','authenticated','replay-{user}@test.local','',now(),'{{}}','{{}}',now(),now());
select set_config('request.jwt.claim.sub','{user}',true);
create temp table replay_hotel as select * from public.setup_hotel('Replay tests','Replay property',null,2,100000);
create temp table replay_stay as select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Replay guest',null,null,
  (now() at time zone 'Africa/Lagos')::date-1,(now() at time zone 'Africa/Lagos')::date+1,1::smallint,null) as id
  from replay_hotel h join public.rooms r on r.property_id=h.property_id where r.room_number='101';
select public.update_room_housekeeping_status(id,'clean') from public.rooms;
select public.check_in_reservation(id) from replay_stay;
select public.post_due_room_nights(id) from replay_stay;
select public.post_department_folio_charge(f.id,'Preserved dinner',7000,'replay-folio-charge',d.id) from public.folios f,public.departments d where d.property_id=f.property_id and d.code='restaurant';
select public.post_department_expense(h.property_id,'5050','Preserved paid supplies',null,3000,m.id,'replay-paid-expense',d.id) from replay_hotel h,public.departments d,public.payment_methods m where d.property_id=h.property_id and d.code='restaurant' and m.property_id=h.property_id and m.clearing_account_code='1000';
create temp table replay_supplier as select public.save_supplier(property_id,null,'Preserved supplier',null,null,null,true) as id from replay_hotel;
create temp table replay_bill as select public.post_supplier_bill(h.property_id,s.id,'REPLAY-1',current_date,current_date,current_date,'Preserved invoice','5050',d.id,12000,'replay-supplier-bill') as id from replay_hotel h,replay_supplier s,public.departments d where d.property_id=h.property_id and d.code='restaurant';
create temp table replay_payment as select public.pay_supplier_bill(b.id,m.id,current_date,4000,'Preserved transfer','replay-supplier-payment') as id from replay_bill b,public.payment_methods m where m.clearing_account_code='1010';
select public.reverse_supplier_payment(id,current_date,'Transfer was returned') from replay_payment;
select public.report_maintenance(r.id,'Preserved repair',null,'normal',false,'replay-maintenance') from public.rooms r where r.room_number='102';
update public.departments set name='Hotel bar',active=false where code='bar';
create function pg_temp.hotel_snapshot() returns jsonb language plpgsql as $snapshot$
declare t record; v jsonb; result jsonb:='{{}}'::jsonb;
begin
  for t in select tablename from pg_catalog.pg_tables where schemaname='public' and tablename not in ('__tcache__','pms_schema_releases') order by tablename loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]''::jsonb) from public.%I x',t.tablename) into v;
    result:=result||jsonb_build_object(t.tablename,v);
  end loop;
  return result;
end $snapshot$;
create temp table replay_before as select pg_temp.hotel_snapshot() as value;
"""
verify="""do $check$ begin
  if (select value from replay_before) is distinct from pg_temp.hotel_snapshot() then
    raise exception 'Migration replay changed stored hotel records';
  end if;
  if to_regprocedure('public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text)') is not null then
    raise exception 'Replay restored an obsolete public booking overload';
  end if;
  if has_function_privilege('authenticated','public.create_priced_reservation_legacy(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text)','execute') then
    raise exception 'Replay exposed the private pricing helper';
  end if;
end $check$;
"""
# Transactions inside the SQL Editor installer cannot be nested in this rollback test.
installer=(root/'supabase/repeatable-install.sql').read_text()
installer=installer.replace('\nbegin;\n','\n',1).replace('\ncommit;\n','\n',1)
migrations='\n\n'.join(p.read_text() for p in sorted((root/'supabase/migrations').glob('*.sql')))
result=execute(setup+migrations+verify+installer+verify+installer+verify+'\nrollback;')
if result.returncode:
    raise SystemExit(result.stderr[-10000:])
assert execute('select count(*) from public.organizations;').stdout.strip()=='0','Fixture rollback failed'
print('PASS: populated CLI replay, repeated installer, immutable source facts, pricing permissions and fixture rollback.')
