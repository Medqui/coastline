-- Isolated SaaS security and lifecycle checks. All fixture writes are rolled back.
begin;
create function pg_temp.assert_true(value boolean,label text) returns void language plpgsql as $$ begin if value is distinct from true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.expect_failure(sql text,code text,label text) returns void language plpgsql as $$
declare actual text;
begin
 begin execute sql; exception when others then get stacked diagnostics actual=returned_sqlstate; end;
 if actual is null or (code is not null and actual<>code) then raise exception 'FAIL: % (expected %, got %)',label,code,actual; end if;
end $$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('19000000-0000-4000-8000-000000000001','saas-owner@test.local','{"platform_admin":true}'),
 ('19000000-0000-4000-8000-000000000002','saas-admin@test.local','{}'),
 ('19000000-0000-4000-8000-000000000003','saas-other@test.local','{}'),
 ('19000000-0000-4000-8000-000000000004','saas-staff1@test.local','{}');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
create temp table saas_hotel as select * from public.setup_hotel('SaaS tests','SaaS property',null,2,100000);
select pg_temp.assert_true((select status='trialing' and plan_code='business' and trial_ends_at between now()+interval '13 days' and now()+interval '15 days' from public.saas_subscriptions where organization_id=(select organization_id from saas_hotel)),'new hotels get a 14-day Business trial');
insert into public.saas_platform_admins(user_id) values('19000000-0000-4000-8000-000000000002');
create temp table saas_invite(token text); grant select,insert on saas_invite to authenticated;
create temp table saas_ids(kind text,id uuid); grant select,insert on saas_ids to authenticated; grant select on saas_hotel to authenticated;
set local role authenticated;
select pg_temp.assert_true(not public.is_platform_admin(),'hotel owner metadata cannot grant platform privileges');
select pg_temp.expect_failure('select public.get_platform_overview()','42501','hotel owner cannot enumerate all customers');
select pg_temp.expect_failure($q$insert into public.saas_platform_admins(user_id) values(auth.uid())$q$,'42501','hotel owner cannot grant platform privileges');
select pg_temp.expect_failure($q$update public.saas_subscriptions set plan_code='group'$q$,'42501','hotel owner cannot assign a plan directly');
select pg_temp.expect_failure($q$select public.set_platform_subscription(organization_id,'group','active',null,null,false,'Unauthorized upgrade') from saas_hotel$q$,'42501','hotel owner cannot call subscription management');
select pg_temp.assert_true((select public.saas_has_feature(organization_id,'inventory') from saas_hotel),'trial includes inventory');
insert into saas_ids select 'stock',public.save_stock_item(property_id,'Preserved trial stock','bottle',1) from saas_hotel;
select pg_temp.expect_failure($q$select public.create_property(organization_id,'Second property',null,1,100000) from saas_hotel$q$,'42501','Business trial caps properties');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000002',true);
select pg_temp.assert_true(public.is_platform_admin(),'explicit platform membership grants platform access');
select pg_temp.assert_true((public.get_platform_overview()->'hotels'->0->>'onboarded')::boolean,'onboarding totals use real configured rooms and owner');
select pg_temp.assert_true(not (public.get_platform_overview()->'hotels'->0 ? 'guests'),'platform overview excludes guest records');
select public.set_platform_subscription(organization_id,'starter','active',now()+interval '30 days',500000,false,'Test Starter assignment') from saas_hotel;
select pg_temp.expect_failure($q$select public.get_subscription_access(organization_id) from saas_hotel$q$,'42501','platform privilege does not grant hotel data membership');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((select public.get_subscription_access(organization_id)->>'plan_code'='starter' from saas_hotel),'owner sees assigned plan');
select pg_temp.assert_true((select count(*)=0 from public.stock_items),'Starter cannot read gated inventory');
select pg_temp.expect_failure($q$select public.save_stock_item(property_id,'Blocked stock','bottle',1) from saas_hotel$q$,'42501','Starter inventory mutation is blocked inside RPC');
select pg_temp.expect_failure($q$select public.save_supplier(property_id,null,'Blocked supplier',null,null,null,true) from saas_hotel$q$,'42501','Starter supplier mutation is blocked inside RPC');
select pg_temp.expect_failure($q$select public.get_balance_sheet(property_id,current_date) from saas_hotel$q$,'42501','Starter detailed financial report RPC is gated');
select pg_temp.expect_failure($q$select public.get_trial_balance(property_id,current_date) from saas_hotel$q$,'42501','Starter trial balance RPC is gated');
select pg_temp.expect_failure($q$select public.staff_handover_summary(property_id) from saas_hotel$q$,'42501','Starter staff handover RPC is gated');
select public.get_profit_and_loss(property_id,current_date,current_date) from saas_hotel;
select public.update_room_housekeeping_status(id,'clean') from public.rooms where property_id=(select property_id from saas_hotel);
select pg_temp.assert_true((select count(*)=2 from public.rooms where housekeeping_status='clean'),'Starter core hotel operations remain available');
-- Active memberships and pending invitations both consume capacity.
insert into saas_invite select public.create_team_invitation(organization_id,property_id,'saas-staff1@test.local','front_desk') from saas_hotel;
select public.create_team_invitation(organization_id,property_id,'saas-staff2@test.local','front_desk') from saas_hotel;
select public.create_team_invitation(organization_id,property_id,'saas-staff3@test.local','front_desk') from saas_hotel;
select public.create_team_invitation(organization_id,property_id,'saas-staff4@test.local','front_desk') from saas_hotel;
select pg_temp.expect_failure($q$select public.create_team_invitation(organization_id,property_id,'saas-staff5@test.local','front_desk') from saas_hotel$q$,'42501','Starter staff cap counts outstanding invites');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000004',true);
select set_config('request.jwt.claims','{"email":"saas-staff1@test.local"}',true);
select public.accept_team_invitation(token) from saas_invite;
select pg_temp.assert_true((select count(*)=2 from public.organization_memberships where organization_id=(select organization_id from saas_hotel) and active),'reserved invitation can be accepted at full seat capacity');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000003',true);
select pg_temp.expect_failure($q$select public.get_subscription_access(organization_id) from saas_hotel$q$,'42501','other customer cannot view subscription');
select pg_temp.assert_true((select count(*)=0 from public.saas_subscriptions),'subscription RLS prevents cross-tenant reads');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000002',true);
select public.set_platform_subscription(organization_id,'group','active',now()+interval '30 days',null,true,'Test Group assignment') from saas_hotel;
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
insert into saas_ids select 'property',public.create_property(organization_id,'Second property',null,1,100000) from saas_hotel;
select pg_temp.assert_true((select count(*)=1 from public.stock_items),'upgrading restores preserved premium records');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000002',true);
select pg_temp.expect_failure($q$select public.set_platform_subscription(organization_id,'business','active',null,null,false,'Test downgrade attempt') from saas_hotel$q$,null,'downgrading cannot strand a second property');
select public.set_platform_subscription(organization_id,'group','past_due',now()-interval '2 days',null,true,'Test grace period') from saas_hotel;
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((select public.get_subscription_access(organization_id)->>'access'='grace' from saas_hotel),'recently ended billing allows seven-day grace');
select public.update_room_housekeeping_status(id,'dirty') from public.rooms where property_id=(select property_id from saas_hotel);
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000002',true);
select public.set_platform_subscription(organization_id,'group','past_due',now()-interval '8 days',null,true,'Test expired grace') from saas_hotel;
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((select public.get_subscription_access(organization_id)->>'access'='read_only' from saas_hotel),'expired grace automatically becomes read-only');
select pg_temp.assert_true((select count(*)=3 from public.rooms),'expired subscription retains core records');
select pg_temp.expect_failure($q$insert into storage.objects(bucket_id,name) select 'expense-receipts',organization_id::text||'/'||property_id::text||'/test/receipt.png' from saas_hotel$q$,'42501','expired subscription cannot upload new receipts');
select pg_temp.assert_true((select count(*)=1 from public.stock_items),'expired subscription retains premium records and exports under its plan');
select public.get_balance_sheet(property_id,current_date) from saas_hotel;
select pg_temp.expect_failure($q$select public.update_room_housekeeping_status(id,'clean') from public.rooms where property_id=(select property_id from saas_hotel)$q$,'42501','read-only core mutations are blocked');
select pg_temp.expect_failure($q$select public.save_stock_item(property_id,'Expired stock','bottle',1) from saas_hotel$q$,'42501','read-only premium mutations are blocked');
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000002',true);
select public.set_platform_subscription(organization_id,'group','active',now()+interval '30 days',null,true,'Test subscription renewal') from saas_hotel;
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000001',true);
select public.update_room_housekeeping_status(id,'clean') from public.rooms where property_id=(select property_id from saas_hotel);
reset role;
select pg_temp.assert_true((select count(*)=5 from public.saas_platform_events where organization_id=(select organization_id from saas_hotel)),'only successful subscription changes produce platform audits');
select pg_temp.assert_true((select count(*)=2 from public.properties where organization_id=(select organization_id from saas_hotel)),'all properties are preserved');
-- The requested platform owner must verify their address before a reserved grant activates.
insert into auth.users(id,email,raw_user_meta_data) values('19000000-0000-4000-8000-000000000005','aletomiwa@gmail.com','{"email_verified":true}');
-- Simulate the preceding release's unverified bootstrap, then apply its forward correction.
insert into public.saas_platform_admins(user_id) values('19000000-0000-4000-8000-000000000005');
\ir ../supabase/migrations/20261011000100_platform_owner_enrollment.sql
select set_config('request.jwt.claim.sub','19000000-0000-4000-8000-000000000005',true);
set local role authenticated;
select pg_temp.assert_true(not public.is_platform_admin(),'unverified signup and editable email metadata cannot activate reserved platform access');
select pg_temp.expect_failure($q$select * from saas_private.platform_admin_enrollments$q$,'42501','pending platform enrollments are private');
select pg_temp.expect_failure($q$update auth.users set email_confirmed_at=now() where id=auth.uid()$q$,'42501','clients cannot self-verify the Auth account');
reset role;
update auth.users set email_confirmed_at=now() where id='19000000-0000-4000-8000-000000000005';
set local role authenticated;
select pg_temp.assert_true(public.is_platform_admin(),'Auth email verification activates the explicitly reserved platform role');
reset role;
select pg_temp.assert_true(not exists(select 1 from saas_private.platform_admin_enrollments where email='aletomiwa@gmail.com'),'platform enrollment is consumed after activation');
rollback;
select 'PASS: SaaS authorization, gates, capacities, grace, read-only, renewal and audit checks';
