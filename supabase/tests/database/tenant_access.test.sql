begin;

select plan(14);

-- Test property-scoped and cross-tenant reads with isolated fixtures.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','frontdesk@test.local','',now(),'{}','{}',now(),now()),
  ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','accountant@test.local','',now(),'{}','{}',now(),now());

insert into public.organizations (id,name,slug) values
  ('20000000-0000-4000-8000-000000000001','Test hotel group','test-hotel-group'),
  ('20000000-0000-4000-8000-000000000002','Other hotel group','other-hotel-group');

insert into public.properties (id,organization_id,name) values
  ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Front desk property'),
  ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','Accountant property'),
  ('30000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','Other tenant property');

insert into public.organization_memberships (organization_id,user_id,role,all_properties) values
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','front_desk',false),
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','accountant',false);

insert into public.membership_properties (organization_id,user_id,property_id) values
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001'),
  ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000002');

insert into public.room_types (id,organization_id,property_id,name,base_rate_kobo) values
  ('40000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','Standard',25000000),
  ('40000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','Standard',25000000),
  ('40000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000003','Standard',25000000);

insert into public.rooms (id,organization_id,property_id,room_type_id,room_number) values
  ('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001','101'),
  ('50000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000002','201'),
  ('50000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000003','40000000-0000-4000-8000-000000000003','301');

insert into public.maintenance_work_orders(organization_id,property_id,room_id,title,priority,reported_by,idempotency_key)
values
  ('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','Assigned issue','normal','10000000-0000-4000-8000-000000000001','tenant-issue-1'),
  ('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000002','Unassigned issue','normal','10000000-0000-4000-8000-000000000001','tenant-issue-2'),
  ('20000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000003','Other tenant issue','normal','10000000-0000-4000-8000-000000000001','tenant-issue-3');

set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}',true);

select ok(public.is_org_member('20000000-0000-4000-8000-000000000001'), 'active user is recognized in their organization');
select ok(not public.is_org_member('20000000-0000-4000-8000-000000000002'), 'membership helper rejects another tenant');
select is((select count(*)::int from public.properties), 1, 'property list respects the member property assignment');
select is((select count(*)::int from public.rooms), 1, 'room inventory respects the member property assignment');
select is((select count(*)::int from public.rooms where organization_id='20000000-0000-4000-8000-000000000002'), 0, 'room inventory hides another tenant');
select ok(public.can_access_property('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001'), 'member can access assigned property');
select ok(not public.can_access_property('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002'), 'member cannot access unassigned property in same organization');
select ok(not public.has_org_role('20000000-0000-4000-8000-000000000001',array['owner','manager','accountant']::public.member_role[]), 'front desk role does not gain finance privileges');
select throws_ok($$select * from public.get_profit_and_loss('30000000-0000-4000-8000-000000000001',current_date,current_date)$$, '42501', null, 'front desk cannot read profit and loss');
select throws_ok($$select * from public.get_profit_and_loss('30000000-0000-4000-8000-000000000002',current_date,current_date)$$, '42501', null, 'assigned-property member cannot read another property accounts');
select throws_ok($$select * from public.get_trial_balance('30000000-0000-4000-8000-000000000003',current_date)$$, '42501', null, 'member cannot read another tenant trial balance');
select is((select count(*)::int from public.accounts where organization_id='20000000-0000-4000-8000-000000000002'), 0, 'account chart hides another tenant');

select is((select count(*)::int from public.maintenance_work_orders),1,'maintenance list respects property assignment');
select is((select count(*)::int from public.maintenance_work_orders where organization_id='20000000-0000-4000-8000-000000000002'),0,'maintenance list hides another tenant');
select * from finish();
rollback;
