begin;
select no_plan();
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('19000000-0000-4000-8000-000000000001','authenticated','authenticated','statements-owner@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
create temp table fs_ctx(kind text primary key,organization_id uuid,property_id uuid);
insert into fs_ctx select 'a',organization_id,property_id from public.setup_hotel('Statements tests','Statements property',null,2,100000);
insert into fs_ctx select 'b',organization_id,gen_random_uuid() from fs_ctx where kind='a';
insert into public.properties(id,organization_id,name) select property_id,organization_id,'Restricted property' from fs_ctx where kind='b';
insert into public.organizations(id,name,slug) values('29000000-0000-4000-8000-000000000002','Foreign statements hotel','foreign-statements');
insert into public.properties(id,organization_id,name) values('39000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000002','Foreign statements property');
insert into fs_ctx values('c','29000000-0000-4000-8000-000000000002','39000000-0000-4000-8000-000000000002');
create temp table fs_ids(kind text primary key,id uuid);
grant select on fs_ctx to authenticated;
grant select,insert on fs_ids to authenticated;
create function pg_temp.fs_prop(k text default 'a') returns uuid language sql as $$select property_id from fs_ctx where kind=k$$;
create function pg_temp.fs_id(k text) returns uuid language sql as $$select id from fs_ids where kind=k$$;
create function pg_temp.fs_today() returns date language sql as $$select (now() at time zone 'Africa/Lagos')::date$$;
create function pg_temp.fs_folio(k text) returns uuid language plpgsql as $$
declare o uuid;g uuid;r uuid;f uuid;
begin
  select organization_id into o from fs_ctx where kind='a';
  insert into public.guests(organization_id,full_name) values(o,'Synthetic guest '||k) returning id into g;
  insert into public.reservations(organization_id,property_id,guest_id,arrival_date,departure_date) values(o,pg_temp.fs_prop(),g,pg_temp.fs_today()-120,pg_temp.fs_today()+1) returning id into r;
  insert into public.folios(organization_id,property_id,reservation_id) values(o,pg_temp.fs_prop(),r) returning id into f;
  return f;
end $$;
create function pg_temp.fs_journal(s text,n bigint,d text,c text,dt date,f uuid default null,k text default 'a') returns uuid language plpgsql as $$
declare o uuid;j uuid;net bigint;typ text;
begin
  select organization_id into o from fs_ctx where kind=k;
  insert into public.journals(organization_id,property_id,source_type,journal_date,memo,idempotency_key,created_by)
    values(o,pg_temp.fs_prop(k),s,dt,'Synthetic '||s,gen_random_uuid()::text,auth.uid()) returning id into j;
  insert into public.journal_lines(organization_id,property_id,journal_id,account_id,debit_kobo,credit_kobo)
    select o,pg_temp.fs_prop(k),j,id,n,0 from public.accounts where organization_id=o and code=d;
  insert into public.journal_lines(organization_id,property_id,journal_id,account_id,debit_kobo,credit_kobo)
    select o,pg_temp.fs_prop(k),j,id,0,n from public.accounts where organization_id=o and code=c;
  update public.journals set status='posted',posted_by=auth.uid(),posted_at=now() where id=j;
  if f is not null then
    net:=case when d='1100' then n else -n end;
    typ:=case when s='payment_refund' then 'refund' when net>0 then 'extra' else 'payment' end;
    insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,unit_amount_kobo,total_amount_kobo,journal_id)
      values(o,pg_temp.fs_prop(k),f,typ,'Synthetic dated item',dt,net,net,j);
  end if;
  return j;
end $$;

set local role authenticated;
select is((select sum(amount_kobo)::bigint from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today())),0::bigint,'empty books have zero accumulated earnings');
select is((select closing_cash_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-10,pg_temp.fs_today())),0::bigint,'empty cash statement closes at zero');
select is((select ledger_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),0::bigint,'empty aging is zero');
reset role;
insert into fs_ids values('folio',pg_temp.fs_folio('main')),('credit',pg_temp.fs_folio('credit'));
select pg_temp.fs_journal('folio_extra',100000,'1100','4100',pg_temp.fs_today()-100,pg_temp.fs_id('folio'));
select pg_temp.fs_journal('folio_extra',50000,'1100','4100',pg_temp.fs_today()-50,pg_temp.fs_id('folio'));
select pg_temp.fs_journal('folio_extra',25000,'1100','4100',pg_temp.fs_today()-10,pg_temp.fs_id('folio'));
select pg_temp.fs_journal('folio_extra',10000,'1100','4100',pg_temp.fs_today()+1,pg_temp.fs_id('folio'));
select pg_temp.fs_journal('folio_payment',80000,'1000','1100',pg_temp.fs_today()-5,pg_temp.fs_id('folio'));
set local role authenticated;
select is((select outstanding_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),95000::bigint,'future charges are excluded and posted payment reduces balance');
select is((select age_90_plus_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),20000::bigint,'FIFO settles oldest charge first');
select is((select age_31_60_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),50000::bigint,'middle charge retains its age');
select is((select age_0_30_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),25000::bigint,'new charge retains its age');
select is((select outstanding_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()-6) where folio_id=pg_temp.fs_id('folio')),175000::bigint,'historical balance excludes later payment');
reset role;
select pg_temp.fs_journal('payment_refund',30000,'1100','1000',pg_temp.fs_today(),pg_temp.fs_id('folio'));
select pg_temp.fs_journal('guest_deposit',7000,'1000','2100',pg_temp.fs_today()-2);
select pg_temp.fs_journal('folio_payment',1200,'1000','1100',pg_temp.fs_today(),pg_temp.fs_id('credit'));
select pg_temp.fs_journal('legacy_receivable',7000,'1100','4100',pg_temp.fs_today()-2);
do $$ declare age integer;f uuid;begin
  foreach age in array array[0,30,31,60,61,90,91] loop
    f:=pg_temp.fs_folio('boundary-'||age);
    perform pg_temp.fs_journal('folio_extra',500,'1100','4100',pg_temp.fs_today()-age,f);
  end loop;
end $$;
set local role authenticated;
select is((select outstanding_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),125000::bigint,'payment refund restores receivable without pretending to add revenue');
select is((select age_90_plus_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),50000::bigint,'refund reduces FIFO settlement and reopens original charge age');
select is((select credit_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),1200::bigint,'credit balance is separately visible');
select is((select outstanding_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),128500::bigint,'advances are liabilities and not receivable credits');
select is((select ledger_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),134300::bigint,'receivable control retains credit balances and unmapped historical journal');
select is((select unassigned_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),7000::bigint,'unmapped ledger amount is flagged instead of hidden');
select is((select age_0_30_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),26000::bigint,'days zero and thirty are in first bucket');
select is((select age_31_60_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),51000::bigint,'days thirty-one and sixty are in second bucket');
select is((select age_61_90_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),1000::bigint,'days sixty-one and ninety are in third bucket');
select is((select age_90_plus_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),50500::bigint,'day ninety-one is in oldest bucket');
select is((select age_0_30_kobo+age_31_60_kobo+age_61_90_kobo+age_90_plus_kobo+unaged_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),128500::bigint,'all aged and unaged amounts sum to gross outstanding');
select is((select ledger_kobo-folio_net_kobo-unassigned_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),0::bigint,'subledger control reconciles with general ledger');
reset role;
insert into public.accounts(organization_id,code,name,account_type) select organization_id,v.code,v.name,v.kind from fs_ctx cross join(values('1500','Equipment','asset'),('2200','Loan','liability'),('3000','Owner capital','equity'))v(code,name,kind) where fs_ctx.kind='a';
insert into fs_ids values('capital',pg_temp.fs_journal('opening_import',100000,'1000','3000',pg_temp.fs_today()-120)),
 ('equipment',pg_temp.fs_journal('equipment_import',20000,'1500','1010',pg_temp.fs_today()-2)),
 ('loan',pg_temp.fs_journal('loan_import',15000,'1000','2200',pg_temp.fs_today()-4)),
 ('transfer',pg_temp.fs_journal('internal_transfer',3000,'1010','1000',pg_temp.fs_today()-1)),
 ('card',pg_temp.fs_journal('folio_payment',4000,'1020','1100',pg_temp.fs_today()-1)),
 ('unpaid-bill',pg_temp.fs_journal('supplier_bill',6000,'5010','2000',pg_temp.fs_today()-3)),
 ('expense',pg_temp.fs_journal('expense',2000,'5010','1000',pg_temp.fs_today()-2)),
 ('supplier-payment',pg_temp.fs_journal('supplier_payment',1000,'2000','1010',pg_temp.fs_today()-1)),
 ('supplier-reversal',pg_temp.fs_journal('supplier_payment_reversal',1000,'1010','2000',pg_temp.fs_today()));
create temp table fs_original_equipment as select to_jsonb(j) as value from public.journals j where id=pg_temp.fs_id('equipment');
set local role authenticated;
select is((select opening_cash_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),100000::bigint,'opening cash is ledger balance before report start');
select is((select closing_cash_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),151200::bigint,'cash closes including financing, investing, refunds and advances');
select is((select pos_clearing_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),4000::bigint,'unsettled card clearing is shown separately from cash');
select is((select unclassified_journals from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),2::bigint,'unknown investment and loan need review');
select is((select count(*)::int from public.get_cash_flow_journals(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where journal_id in(pg_temp.fs_id('transfer'),pg_temp.fs_id('card'),pg_temp.fs_id('unpaid-bill'))),0,'internal transfers, card clearing and unpaid bills do not create cash flow');
select is((select sum(net_kobo)::bigint from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),(select net_change_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),'all classified and unclassified cash movements reconcile to ledger change');
select is((select inflow_kobo from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where activity='operating'),89200::bigint,'operating receipts include payments, advances and returned supplier payment');
select is((select outflow_kobo from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where activity='operating'),33000::bigint,'operating outflows include refund, paid expense and supplier settlement');
select lives_ok($$insert into fs_ids values('class-investment',public.classify_cash_flow(pg_temp.fs_id('equipment'),'investing','Purchase of hotel equipment','fs-investment-class'))$$,'owner classifies investing cash movement');
select is(public.classify_cash_flow(pg_temp.fs_id('equipment'),'investing','Purchase of hotel equipment','fs-investment-class'),pg_temp.fs_id('class-investment'),'same classification retry returns original record');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('equipment'),'financing','Purchase of hotel equipment','fs-investment-class')$$,'23505',null,'changed classification retry is rejected');
select lives_ok($$select public.classify_cash_flow(pg_temp.fs_id('loan'),'financing','Loan proceeds received','fs-loan-class')$$,'loan cash movement can be classified as financing');
select is((select net_kobo from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where activity='investing'),-20000::bigint,'investing reports cash paid for equipment');
select is((select net_kobo from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where activity='financing'),15000::bigint,'financing reports loan proceeds');
select is((select unclassified_journals from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),0::bigint,'cash classifications remove review warning');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('expense'),'investing','Change ordinary expense','fs-invalid-expense')$$,'23514',null,'known workflow classification cannot be relabeled');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('transfer'),'financing','Internal transfer test','fs-invalid-transfer')$$,'23514',null,'internal transfer cannot become external cash flow');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('card'),'operating','Unsettled card test','fs-invalid-card')$$,'23514',null,'card clearing does not become cash by classification');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('loan'),'other','Invalid category reason','fs-invalid-category')$$,'22023',null,'unknown classification activity is rejected');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('loan'),'financing','bad','fs-invalid-reason')$$,'22023',null,'classification requires an audit reason');
select lives_ok($$select public.classify_cash_flow(pg_temp.fs_id('equipment'),'financing','Test revised classification','fs-investment-revised')$$,'classification correction appends a new record');
select is((select activity from public.get_cash_flow_journals(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today()) where journal_id=pg_temp.fs_id('equipment')),'financing','latest revision controls statement classification');
select lives_ok($$select public.classify_cash_flow(pg_temp.fs_id('equipment'),'investing','Correct equipment classification','fs-investment-final')$$,'corrected classification can be restored with an audit link');
select is((select count(*)::int from public.cash_flow_classifications where journal_id=pg_temp.fs_id('equipment')),3,'classification history retains every revision');
select is((select count(*)::int from public.audit_events where action='cash_flow_classified'),4,'retries do not duplicate classification audit records');
select throws_ok($$insert into public.cash_flow_classifications(organization_id,property_id,journal_id,activity,reason,idempotency_key,created_by) select organization_id,property_id,pg_temp.fs_id('loan'),'investing','Bypass attempt','bypass-test',auth.uid() from fs_ctx where kind='a'$$,'42501',null,'client cannot insert classifications directly');
select ok(not has_function_privilege('authenticated','public.assert_finance_report_access(uuid)','execute'),'private report authorization helper is not callable by staff');
select ok(not has_function_privilege('anon','public.get_balance_sheet(uuid,date)','execute'),'anonymous balance-sheet execution is revoked');
select ok(not has_function_privilege('anon','public.get_cash_flow(uuid,date,date)','execute'),'anonymous cash-flow execution is revoked');
select ok(not has_function_privilege('anon','public.get_guest_receivables_aging(uuid,date)','execute'),'anonymous guest-aging execution is revoked');
select throws_ok($$select * from public.get_balance_sheet(pg_temp.fs_prop(),null)$$,'22023',null,'balance sheet requires an as-of date');
select throws_ok($$select * from public.get_guest_receivables_summary(pg_temp.fs_prop(),null)$$,'22023',null,'guest aging requires an as-of date');
select throws_ok($$select * from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today(),pg_temp.fs_today()-1)$$,'22023',null,'cash-flow period must be ordered');
select throws_ok($$select * from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-367,pg_temp.fs_today())$$,'22023',null,'cash-flow period is bounded to one year');
select is((select sum(case when account_type='asset' then amount_kobo else -amount_kobo end)::bigint from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today())),0::bigint,'assets equal liabilities plus equity including accumulated earnings');
select is((select amount_kobo from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today()) where account_code='__earnings__'),(select sum(case when account_type='revenue' then amount_kobo else -amount_kobo end)::bigint from public.get_profit_and_loss(pg_temp.fs_prop(),pg_temp.fs_today()-366,pg_temp.fs_today())),'accumulated earnings agrees with posted P&L');
select is((select amount_kobo from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today()) where account_code='1100'),(select ledger_kobo from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())),'balance sheet and receivables control agree');
select is((select sum(amount_kobo)::bigint from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today()) where account_code in('1000','1010')),(select closing_cash_kobo from public.get_cash_flow_summary(pg_temp.fs_prop(),pg_temp.fs_today()-110,pg_temp.fs_today())),'cash statement closing agrees with balance sheet');
reset role;
select is((select to_jsonb(j) from public.journals j where id=pg_temp.fs_id('equipment')),(select value from fs_original_equipment),'classification never changes posted journal');
select throws_ok($$update public.cash_flow_classifications set activity='financing' where id=pg_temp.fs_id('class-investment')$$,'23514',null,'classification facts cannot be updated even by admin');
select throws_ok($$delete from public.cash_flow_classifications where id=pg_temp.fs_id('class-investment')$$,'23514',null,'classification history cannot be deleted');
select pg_temp.fs_journal('folio_payment',125000,'1000','1100',pg_temp.fs_today(),pg_temp.fs_id('folio'));
update public.folios set status='closed',closed_at=now() where id=pg_temp.fs_id('folio');
set local role authenticated;
select is((select count(*)::int from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()) where folio_id=pg_temp.fs_id('folio')),0,'settled closed folio has no current receivable');
select is((select outstanding_kobo from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today()-6) where folio_id=pg_temp.fs_id('folio')),175000::bigint,'closed folio still appears in its historical unpaid period');
select throws_ok($$select * from public.get_balance_sheet(pg_temp.fs_prop('c'),pg_temp.fs_today())$$,'42501',null,'balance sheet rejects other tenant');
select throws_ok($$select * from public.get_guest_receivables_summary(pg_temp.fs_prop('c'),pg_temp.fs_today())$$,'42501',null,'receivables reject other tenant');
select throws_ok($$select * from public.get_cash_flow(pg_temp.fs_prop('c'),pg_temp.fs_today()-1,pg_temp.fs_today())$$,'42501',null,'cash flow rejects other tenant even with no movements');
reset role;
update public.organization_memberships set role='manager' where user_id=auth.uid();
set local role authenticated;
select lives_ok($$select * from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today())$$,'manager may read balance sheet');
select throws_ok($$select public.classify_cash_flow(pg_temp.fs_id('loan'),'financing','Manager test classification','fs-manager-class')$$,'42501',null,'manager cannot reclassify cash flow');
reset role;
update public.organization_memberships set role='accountant',all_properties=false where user_id=auth.uid();
insert into public.membership_properties(organization_id,user_id,property_id) select organization_id,auth.uid(),property_id from fs_ctx where kind='a';
set local role authenticated;
select lives_ok($$select * from public.get_guest_receivables_summary(pg_temp.fs_prop(),pg_temp.fs_today())$$,'accountant may read assigned guest balances');
select lives_ok($$select public.classify_cash_flow(pg_temp.fs_id('loan'),'financing','Accountant confirmation','fs-accountant-class')$$,'accountant may classify assigned cash movement');
select throws_ok($$select * from public.get_cash_flow_summary(pg_temp.fs_prop('b'),pg_temp.fs_today()-1,pg_temp.fs_today())$$,'42501',null,'accountant cannot read unassigned property');
reset role;
update public.organization_memberships set role='front_desk' where user_id=auth.uid();
set local role authenticated;
select throws_ok($$select * from public.get_balance_sheet(pg_temp.fs_prop(),pg_temp.fs_today())$$,'42501',null,'front desk cannot read balance sheet');
select throws_ok($$select * from public.get_guest_receivables_aging(pg_temp.fs_prop(),pg_temp.fs_today())$$,'42501',null,'front desk cannot read finance aging');
select throws_ok($$select * from public.get_cash_flow(pg_temp.fs_prop(),pg_temp.fs_today()-1,pg_temp.fs_today())$$,'42501',null,'front desk cannot read cash-flow statement');
select is((select count(*)::int from public.cash_flow_classifications),0,'front desk cannot read classification reasons');
reset role;
update public.organization_memberships set role='housekeeping' where user_id=auth.uid();
set local role authenticated;
select throws_ok($$select * from public.get_cash_flow_journals(pg_temp.fs_prop(),pg_temp.fs_today()-1,pg_temp.fs_today())$$,'42501',null,'housekeeping cannot read cash journals');
select * from finish();
rollback;
