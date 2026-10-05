begin;
select no_plan();
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('19000000-0000-4000-8000-000000000001','authenticated','authenticated','department-owner@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"19000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
create temp table da_hotel as select * from public.setup_hotel('Department accounting tests','Department property',null,1,100000);
create temp table da_ids(kind text primary key,id uuid);
insert into da_ids values('other-property',gen_random_uuid());
insert into public.properties(id,organization_id,name) select i.id,h.organization_id,'Other department property' from da_hotel h,da_ids i where i.kind='other-property';
insert into da_ids select 'foreign-dept',id from public.departments where property_id=(select id from da_ids where kind='other-property') and code='bar';
grant select on da_hotel to authenticated;
grant select,insert on da_ids to authenticated;
create function pg_temp.da_id(k text) returns uuid language sql as $$select id from da_ids where kind=k$$;
create function pg_temp.da_prop() returns uuid language sql as $$select property_id from da_hotel$$;
create function pg_temp.da_dept(c text) returns uuid language sql as $$select id from public.departments where property_id=pg_temp.da_prop() and code=c$$;
create function pg_temp.da_method() returns uuid language sql as $$select id from public.payment_methods where property_id=pg_temp.da_prop() and clearing_account_code='1000' limit 1$$;
create function pg_temp.da_today() returns date language sql as $$select (now() at time zone 'Africa/Lagos')::date$$;
set local role authenticated;
insert into da_ids select 'reservation',public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Department guest',null,null,pg_temp.da_today()-1,pg_temp.da_today()+1,1::smallint,null) from da_hotel h join public.rooms r on r.property_id=h.property_id;
select public.update_room_housekeeping_status(id,'clean') from public.rooms where property_id=pg_temp.da_prop();
select public.check_in_reservation(pg_temp.da_id('reservation'));
insert into da_ids select 'folio',id from public.folios where reservation_id=pg_temp.da_id('reservation');
select public.post_due_room_nights(pg_temp.da_id('reservation'));
select is((select d.code from public.journals j join public.departments d on d.id=j.department_id where j.source_type='room_night'),'accommodation','posted room night receives accommodation department');
select lives_ok($$insert into da_ids values('restaurant-charge',public.post_department_folio_charge(pg_temp.da_id('folio'),'Dinner',25000,'da-restaurant-charge',pg_temp.da_dept('restaurant')))$$,'restaurant charge posts to guest folio');
select is(public.post_department_folio_charge(pg_temp.da_id('folio'),'Dinner',25000,'da-restaurant-charge',pg_temp.da_dept('restaurant')),pg_temp.da_id('restaurant-charge'),'identical charge retry returns original item');
select throws_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Dinner',25000,'da-restaurant-charge',pg_temp.da_dept('bar'))$$,'23505',null,'charge key cannot be reused with another department');
select throws_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Dinner',25001,'da-restaurant-charge',pg_temp.da_dept('restaurant'))$$,'23505',null,'charge key cannot be reused with changed amount');
select throws_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Foreign department',1000,'da-foreign-charge',pg_temp.da_id('foreign-dept'))$$,'22023',null,'folio charge rejects another property department');
select lives_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Drinks',10000,'da-bar-charge',pg_temp.da_dept('bar'))$$,'bar charge retains its department');
select lives_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Laundry',5000,'da-laundry-charge',pg_temp.da_dept('laundry'))$$,'laundry charge retains its department');
select lives_ok($$select public.post_folio_charge(pg_temp.da_id('folio'),'Guest service',3000,'da-default-charge')$$,'legacy folio RPC remains compatible');
select is((select d.code from public.journals j join public.departments d on d.id=j.department_id where j.idempotency_key='extra:da-default-charge'),'services','legacy folio RPC defaults to guest services');
select lives_ok($$insert into da_ids values('expense',public.post_department_expense(pg_temp.da_prop(),'5010','Restaurant supplies','Market vendor',4000,pg_temp.da_method(),'da-restaurant-expense',pg_temp.da_dept('restaurant')))$$,'paid expense records selected department');
select is(public.post_department_expense(pg_temp.da_prop(),'5010','Restaurant supplies','Market vendor',4000,pg_temp.da_method(),'da-restaurant-expense',pg_temp.da_dept('restaurant')),pg_temp.da_id('expense'),'identical paid expense retry returns original record');
select throws_ok($$select public.post_department_expense(pg_temp.da_prop(),'5010','Restaurant supplies','Market vendor',4000,pg_temp.da_method(),'da-restaurant-expense',pg_temp.da_dept('bar'))$$,'23505',null,'expense retry cannot change department');
select throws_ok($$select public.post_department_expense(pg_temp.da_prop(),'5010','Restaurant supplies','Different vendor',4000,pg_temp.da_method(),'da-restaurant-expense',pg_temp.da_dept('restaurant'))$$,'23505',null,'expense retry cannot change vendor');
select throws_ok($$select public.post_department_expense(pg_temp.da_prop(),'5010','Foreign department',null,1000,pg_temp.da_method(),'da-foreign-expense',pg_temp.da_id('foreign-dept'))$$,'22023',null,'paid expense rejects foreign property department');
select lives_ok($$select public.post_categorized_expense(pg_temp.da_prop(),'5020','Legacy categorized expense',null,6000,pg_temp.da_method(),'da-default-expense')$$,'legacy categorized expense RPC remains compatible');
select lives_ok($$select public.post_paid_expense(pg_temp.da_prop(),'Legacy paid expense',null,2000,pg_temp.da_method(),'da-default-paid')$$,'legacy paid expense RPC remains compatible');
select is((select count(*)::int from public.journals j join public.departments d on d.id=j.department_id where j.source_type='expense' and d.code='administration'),2,'legacy expense RPCs default to administration');
select is((select payment_method_id from public.expenses where id=pg_temp.da_id('expense')),pg_temp.da_method(),'new expense retains payment method identity');
select is((select revenue_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='restaurant'),25000::bigint,'restaurant revenue reports only restaurant charge');
select is((select expense_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='restaurant'),4000::bigint,'restaurant expense reports its cost');
select is((select net_income_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='restaurant'),21000::bigint,'restaurant net income is revenue less cost');
select is((select revenue_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='bar'),10000::bigint,'bar revenue is separate');
select is((select revenue_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='laundry'),5000::bigint,'laundry revenue is separate');
select is((select sum(total_amount_kobo)::bigint from public.folio_items where folio_id=pg_temp.da_id('folio')),143000::bigint,'department charges appear once in guest balance');
-- Simulate immutable pre-upgrade posted facts without assigning departments.
reset role;
create function pg_temp.da_legacy(s text,a bigint,debit text,credit text) returns uuid language plpgsql as $$
declare o uuid; j uuid;
begin
  select organization_id into o from da_hotel;
  insert into public.journals(organization_id,property_id,source_type,source_id,journal_date,memo,idempotency_key,created_by)
    values(o,pg_temp.da_prop(),s,gen_random_uuid(),pg_temp.da_today(),'Legacy fixture','legacy:'||s,auth.uid()) returning id into j;
  insert into public.journal_lines(organization_id,property_id,journal_id,account_id,description,debit_kobo,credit_kobo)
    select o,pg_temp.da_prop(),j,id,'Legacy fixture',a,0 from public.accounts where organization_id=o and code=debit;
  insert into public.journal_lines(organization_id,property_id,journal_id,account_id,description,debit_kobo,credit_kobo)
    select o,pg_temp.da_prop(),j,id,'Legacy fixture',0,a from public.accounts where organization_id=o and code=credit;
  update public.journals set status='posted',posted_by=auth.uid(),posted_at=now() where id=j;
  return j;
end $$;
insert into da_ids values('legacy-room',pg_temp.da_legacy('room_night',11000,'1100','4000')),
 ('legacy-extra',pg_temp.da_legacy('folio_extra',2000,'1100','4100')),
 ('legacy-expense',pg_temp.da_legacy('expense',1700,'5000','1000')),
 ('legacy-import',pg_temp.da_legacy('legacy_import',900,'5000','1000'));
set local role authenticated;
select is((select revenue_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='accommodation'),111000::bigint,'historical room source is inferred without rewriting posted journal');
select is((select revenue_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='services'),5000::bigint,'historical extra source is assigned to guest services');
select is((select expense_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='administration'),9700::bigint,'historical paid expense appears in administration');
select is((select expense_kobo from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where department_code='unallocated'),900::bigint,'unknown historical source is explicitly unallocated');
select ok((select department_id is null from public.journals where id=pg_temp.da_id('legacy-room')),'historical posted header remains unchanged');
select is((select sum(revenue_kobo)::bigint from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today())),(select sum(amount_kobo)::bigint from public.get_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where account_type='revenue'),'department revenues reconcile to account P&L');
select is((select sum(expense_kobo)::bigint from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today())),(select sum(amount_kobo)::bigint from public.get_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today()) where account_type='expense'),'department costs reconcile to account P&L');
select is((select sum(debit_balance_kobo-credit_balance_kobo)::bigint from public.get_trial_balance(pg_temp.da_prop(),pg_temp.da_today())),0::bigint,'all dimensions preserve balanced ledger');
select throws_ok($$select * from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today(),pg_temp.da_today()-1)$$,'22023',null,'department report rejects reversed date range');
reset role;
update public.organization_memberships set role='front_desk' where user_id=auth.uid();
set local role authenticated;
select lives_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Staff meal sale',1000,'da-frontdesk-charge',pg_temp.da_dept('restaurant'))$$,'front desk can allocate permitted folio charge');
select throws_ok($$select public.post_department_expense(pg_temp.da_prop(),'5010','Unauthorized expense',null,1000,pg_temp.da_method(),'da-frontdesk-expense',pg_temp.da_dept('restaurant'))$$,'42501',null,'front desk cannot post department expenses');
select throws_ok($$select * from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today())$$,'42501',null,'front desk cannot read department financial report');
reset role;
update public.organization_memberships set role='accountant' where user_id=auth.uid();
set local role authenticated;
select throws_ok($$select public.post_department_folio_charge(pg_temp.da_id('folio'),'Unauthorized folio sale',1000,'da-accountant-charge',pg_temp.da_dept('restaurant'))$$,'42501',null,'accountant does not gain front desk sale permission');
select lives_ok($$select * from public.get_department_profit_and_loss(pg_temp.da_prop(),pg_temp.da_today()-1,pg_temp.da_today())$$,'accountant can view department report');
select * from finish();
rollback;
