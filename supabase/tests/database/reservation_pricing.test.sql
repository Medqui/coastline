begin;
select plan(13);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('11000000-0000-4000-8000-000000000001','authenticated','authenticated','pricing@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
create temp table pricing_hotel as select * from public.setup_hotel('Pricing tests','Pricing property',null,2,1000000);
create temp table pricing_rooms as select r.id,r.room_number from public.rooms r join pricing_hotel h on h.property_id=r.property_id;
create temp table pricing_bookings(kind text primary key,id uuid);
grant select on pricing_hotel,pricing_rooms to authenticated;
grant select,insert on pricing_bookings to authenticated;

set local role authenticated;
select lives_ok($$insert into pricing_bookings select 'discount',public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Discount guest',null,null,(now() at time zone 'Africa/Lagos')::date+10,(now() at time zone 'Africa/Lagos')::date+12,1::smallint,800000,null,'Repeat guest offer') from pricing_hotel h,pricing_rooms r where r.room_number='101'$$,'owner can approve a discounted booking');
select is((select quoted_standard_rate_kobo from public.reservation_rooms where reservation_id=(select id from pricing_bookings where kind='discount')),1000000::bigint,'booking retains the original standard rate');
select is((select pricing_approved_by from public.reservation_rooms where reservation_id=(select id from pricing_bookings where kind='discount')),auth.uid(),'booking retains its approval actor');
select is((select after_data->>'reason' from public.audit_events where entity_id=(select id from pricing_bookings where kind='discount') and action='reservation_pricing_approved'),'Repeat guest offer','approval audit retains the reason');
select throws_ok($$select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Missing reason',null,null,(now() at time zone 'Africa/Lagos')::date+20,(now() at time zone 'Africa/Lagos')::date+22,1::smallint,800000) from pricing_hotel h,pricing_rooms r where r.room_number='101'$$,'22023',null,'discount requires a reason');
select lives_ok($$insert into pricing_bookings select 'complimentary',public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Complimentary guest',null,null,(now() at time zone 'Africa/Lagos')::date-1,(now() at time zone 'Africa/Lagos')::date+1,1::smallint,0,null,'Approved familiarization stay') from pricing_hotel h,pricing_rooms r where r.room_number='102'$$,'owner can approve a complimentary stay');
select public.update_room_housekeeping_status(id,'clean') from pricing_rooms where room_number='102';
select lives_ok($$select public.check_in_reservation(id) from pricing_bookings where kind='complimentary'$$,'complimentary guest can check in');
select is((select public.post_due_room_nights(id) from pricing_bookings where kind='complimentary'),0,'complimentary completed nights create no financial charge');
select is((select count(*)::int from public.journals where source_id=(select id from pricing_bookings where kind='complimentary')),0,'complimentary stay creates no artificial revenue journal');
select ok(not has_function_privilege('authenticated','public.create_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text)','execute'),'legacy booking RPC cannot bypass pricing approval');

reset role;
update public.organization_memberships set role='front_desk' where user_id='11000000-0000-4000-8000-000000000001';
set local role authenticated;
select lives_ok($$insert into pricing_bookings select 'standard',public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Standard guest',null,null,(now() at time zone 'Africa/Lagos')::date+30,(now() at time zone 'Africa/Lagos')::date+32,1::smallint,1000000) from pricing_hotel h,pricing_rooms r where r.room_number='101'$$,'front desk can book the standard rate');
select throws_ok($$select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Unauthorized discount',null,null,(now() at time zone 'Africa/Lagos')::date+40,(now() at time zone 'Africa/Lagos')::date+42,1::smallint,800000,null,'Staff supplied reason') from pricing_hotel h,pricing_rooms r where r.room_number='101'$$,'42501',null,'front desk cannot self-approve a discount');
select throws_ok($$select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Unauthorized comp',null,null,(now() at time zone 'Africa/Lagos')::date+40,(now() at time zone 'Africa/Lagos')::date+42,1::smallint,0,null,'Staff supplied reason') from pricing_hotel h,pricing_rooms r where r.room_number='101'$$,'42501',null,'front desk cannot self-approve a complimentary stay');

select * from finish();
rollback;
