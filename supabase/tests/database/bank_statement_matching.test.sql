begin;
select no_plan();

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('1a000000-0000-4000-8000-000000000001','authenticated','authenticated','bank-owner@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','1a000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"1a000000-0000-4000-8000-000000000001","role":"authenticated"}',true);

create temp table bank_hotel as select * from public.setup_hotel('Bank matching tests','Bank property',null,1,100000);
create temp table bank_ids(kind text primary key,id uuid);
insert into bank_ids select 'method',id from public.payment_methods where property_id=(select property_id from bank_hotel) and clearing_account_code='1010';
insert into bank_ids select 'bank-account',id from public.accounts where organization_id=(select organization_id from bank_hotel) and code='1010';
insert into bank_ids select 'revenue-account',id from public.accounts where organization_id=(select organization_id from bank_hotel) and code='4100';

insert into public.journals(id,organization_id,property_id,source_type,journal_date,memo,status,idempotency_key,created_by,posted_by,posted_at)
select '4a000000-0000-4000-8000-000000000001',organization_id,property_id,'test_bank_receipt',current_date,'Guest transfer TEST','draft','bank-ledger-test',auth.uid(),null,null from bank_hotel;
insert into public.journal_lines(organization_id,property_id,journal_id,account_id,description,debit_kobo,credit_kobo)
select h.organization_id,h.property_id,'4a000000-0000-4000-8000-000000000001'::uuid,i.id,'Bank receipt',150000,0 from bank_hotel h,bank_ids i where i.kind='bank-account'
union all select h.organization_id,h.property_id,'4a000000-0000-4000-8000-000000000001'::uuid,i.id,'Revenue',0,150000 from bank_hotel h,bank_ids i where i.kind='revenue-account';
update public.journals set status='posted',posted_by=auth.uid(),posted_at=now() where id='4a000000-0000-4000-8000-000000000001';

insert into bank_ids select 'reconciliation',public.create_bank_reconciliation(h.property_id,m.id,current_date,current_date,0,150000)
from bank_hotel h,bank_ids m where m.kind='method';

select lives_ok($$select public.import_bank_statement((select id from bank_ids where kind='reconciliation'),'statement.csv',repeat('a',64),
  jsonb_build_array(jsonb_build_object('date',current_date::text,'description','Guest transfer TEST','reference','TRX-1','amount_kobo',150000,'balance_kobo',150000)),'bank-import-test')$$,'owner imports a statement');
select is((select matching_required from public.bank_reconciliations where id=(select id from bank_ids where kind='reconciliation')),true,'statement import enables transaction matching');
select is((select count(*)::int from public.bank_statement_lines),1,'import stores one immutable statement line');
select is((select count(*)::int from public.import_bank_statement((select id from bank_ids where kind='reconciliation'),'statement.csv',repeat('a',64),
  jsonb_build_array(jsonb_build_object('date',current_date::text,'description','Guest transfer TEST','reference','TRX-1','amount_kobo',150000,'balance_kobo',150000)),'bank-import-test') x),1,'same import retry returns the original record');
select throws_ok($$update public.bank_statement_lines set description='Changed'$$,'23514',null,'imported statement facts are immutable');
select throws_ok($$select public.complete_bank_reconciliation((select id from bank_ids where kind='reconciliation'))$$,'23514',null,'matching reconciliation cannot complete with unmatched transactions');
select is(public.auto_match_bank_statement((select id from bank_ids where kind='reconciliation')),1,'unique amount within three days is automatically matched');
select is((select status from public.get_bank_statement_lines((select id from bank_ids where kind='reconciliation'))),'matched','statement line reports matched');
select is((select status from public.get_bank_ledger_candidates((select id from bank_ids where kind='reconciliation'))),'matched','ledger movement reports matched');
select lives_ok($$select public.complete_bank_reconciliation((select id from bank_ids where kind='reconciliation'))$$,'fully matched reconciliation completes');
select is((select status from public.bank_reconciliations where id=(select id from bank_ids where kind='reconciliation')),'reconciled','reconciliation is complete');
select is((select count(*)::int from public.audit_events where action in('bank_statement_imported','bank_statement_line_matched','bank_reconciliation_completed')),3,'import, match and completion are audited');

insert into public.bank_reconciliations(id,organization_id,property_id,payment_method_id,period_from,period_to,opening_balance_kobo,statement_balance_kobo,book_balance_kobo,difference_kobo,matching_required,created_by)
select '5a000000-0000-4000-8000-000000000001',h.organization_id,h.property_id,m.id,current_date-1,current_date-1,0,150000,150000,0,true,auth.uid() from bank_hotel h,bank_ids m where m.kind='method';
select lives_ok($$select public.import_bank_statement('5a000000-0000-4000-8000-000000000001','exception.csv',repeat('b',64),
  jsonb_build_array(jsonb_build_object('date',(current_date-1)::text,'description','Unknown bank fee','amount_kobo',-2500)),'bank-import-exception')$$,'second statement imports');
select lives_ok($$select public.flag_bank_statement_exception((select id from public.bank_statement_lines where reconciliation_id='5a000000-0000-4000-8000-000000000001'),'Bank fee has not yet been posted','bank-exception-test')$$,'unmatched statement line can be flagged');
select is((select status from public.get_bank_statement_lines('5a000000-0000-4000-8000-000000000001')),'exception','open exception is visible');
select throws_ok($$select public.complete_bank_reconciliation('5a000000-0000-4000-8000-000000000001')$$,'23514',null,'reviewed exception still blocks completion until posted and matched');

update public.organization_memberships set role='front_desk' where user_id=auth.uid();
select throws_ok($$select * from public.get_bank_statement_lines('5a000000-0000-4000-8000-000000000001')$$,'42501',null,'front desk cannot read bank statement lines');
select throws_ok($$select public.auto_match_bank_statement('5a000000-0000-4000-8000-000000000001')$$,'42501',null,'front desk cannot match bank statements');
select ok(not has_function_privilege('anon','public.import_bank_statement(uuid,text,text,jsonb,text)','execute'),'anonymous users cannot import statements');
select ok(not has_table_privilege('authenticated','public.bank_statement_lines','insert'),'clients cannot insert statement facts directly');
select ok(not has_table_privilege('authenticated','public.bank_statement_matches','insert'),'clients cannot bypass matching functions');

select * from finish();
rollback;
