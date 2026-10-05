begin;
select plan(20);
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('12000000-0000-4000-8000-000000000001','authenticated','authenticated','maintenance@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','12000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"12000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
create temp table maintenance_hotel as select * from public.setup_hotel('Maintenance tests','Maintenance property',null,3,1000000);
create temp table maintenance_rooms as select r.id,r.room_number from public.rooms r join maintenance_hotel h on h.property_id=r.property_id;
create temp table maintenance_bookings(kind text primary key,id uuid);
create temp table maintenance_tasks(kind text primary key,id uuid);
grant select on maintenance_hotel,maintenance_rooms to authenticated;
grant select,insert on maintenance_bookings,maintenance_tasks to authenticated;
set local role authenticated;
select public.update_room_housekeeping_status(id,'clean') from maintenance_rooms;
insert into maintenance_bookings select r.room_number,public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Maintenance test guest',null,null,(now() at time zone 'Africa/Lagos')::date,(now() at time zone 'Africa/Lagos')::date+2,1::smallint,1000000)
  from maintenance_hotel h,maintenance_rooms r where r.room_number in ('101','102');

select lives_ok($$insert into maintenance_tasks select 'reserved',public.report_maintenance(id,'Repair bathroom',null,'urgent',true,'maint-reserved-101') from maintenance_rooms where room_number='101'$$,'manager can block a room with a future reservation');
select lives_ok($$insert into maintenance_tasks select 'vacant',public.report_maintenance(id,'Repair air conditioner',null,'normal',true,'maint-vacant-103') from maintenance_rooms where room_number='103'$$,'manager can block a vacant room');
select is((select public.report_maintenance(id,'Repair air conditioner',null,'normal',true,'maint-vacant-103') from maintenance_rooms where room_number='103'),(select id from maintenance_tasks where kind='vacant'),'retry returns the same work order');
select throws_ok($$select public.report_maintenance(id,'Different issue',null,'normal',true,'maint-vacant-103') from maintenance_rooms where room_number='103'$$,'23505',null,'retry with changed issue is rejected');
select is((select count(*)::int from maintenance_hotel h, lateral public.get_available_rooms(h.property_id,current_date+20,current_date+21)),1,'calendar availability excludes both active room blocks');
select throws_ok($$select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Blocked booking',null,null,current_date+20,current_date+21,1::smallint,1000000) from maintenance_hotel h,maintenance_rooms r where room_number='103'$$,'23514',null,'booking cannot bypass a maintenance block');
select throws_ok($$select public.check_in_reservation(id) from maintenance_bookings where kind='101'$$,'23514',null,'existing reservation cannot check in to a blocked room');
select lives_ok($$select public.check_in_reservation(id) from maintenance_bookings where kind='102'$$,'unblocked room can check in');
select throws_ok($$select public.move_checked_in_reservation(b.id,r.id,'Maintenance move') from maintenance_bookings b,maintenance_rooms r where b.kind='102' and r.room_number='103'$$,'23514',null,'room move cannot bypass a maintenance block');
select throws_ok($$select public.report_maintenance(id,'Occupied room issue',null,'urgent',true,'maint-occupied-102') from maintenance_rooms where room_number='102'$$,'23514',null,'blocking requires moving an in-house guest first');
select throws_ok($$select public.transition_maintenance(id,'resolved',null) from maintenance_tasks where kind='vacant'$$,'22023',null,'closing requires work notes');
select lives_ok($$select public.transition_maintenance(id,'resolved','Air conditioner repaired and tested') from maintenance_tasks where kind='vacant'$$,'manager can resolve and release a room block');
select is((select housekeeping_status::text from public.rooms where id=(select id from maintenance_rooms where room_number='103')),'clean','maintenance resolution preserves separate housekeeping status');
select is((select count(*)::int from maintenance_hotel h, lateral public.get_available_rooms(h.property_id,current_date+20,current_date+21)),2,'resolved block returns the room to availability');
select lives_ok($$select public.move_checked_in_reservation(b.id,r.id,'Maintenance move') from maintenance_bookings b,maintenance_rooms r where b.kind='102' and r.room_number='103'$$,'room move succeeds after maintenance release');
select throws_ok($$select public.transition_maintenance(id,'in_progress','Reopen attempt') from maintenance_tasks where kind='vacant'$$,'23514',null,'terminal maintenance history cannot be reopened');
select is((select count(*)::int from public.audit_events where entity_id=(select id from maintenance_tasks where kind='vacant') and action='maintenance_status_changed'),1,'maintenance closure has one audit event');

reset role;
update public.organization_memberships set role='front_desk' where user_id='12000000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select public.report_maintenance(id,'Unauthorized block',null,'normal',true,'maint-unauthorized') from maintenance_rooms where room_number='102'$$,'42501',null,'front desk cannot block inventory');
select throws_ok($$select public.transition_maintenance(id,'resolved','Unauthorized closure') from maintenance_tasks where kind='reserved'$$,'42501',null,'front desk cannot resolve a maintenance block');
select lives_ok($$select public.report_maintenance(id,'Minor paint damage',null,'low',false,'maint-paint-issue') from maintenance_rooms where room_number='102'$$,'front desk can report a nonblocking issue');
select * from finish();
rollback;
