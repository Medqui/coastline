begin;
select no_plan();

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('1b000000-0000-4000-8000-000000000001','authenticated','authenticated','shift-owner@test.local','',now(),'{}','{}',now(),now()),
('1b000000-0000-4000-8000-000000000002','authenticated','authenticated','shift-desk@test.local','',now(),'{}','{}',now(),now()),
('1b000000-0000-4000-8000-000000000003','authenticated','authenticated','shift-manager@test.local','',now(),'{}','{}',now(),now());
select set_config('request.jwt.claim.sub','1b000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"1b000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
create temp table shift_hotel as select * from public.setup_hotel('Cashier tests','Cashier property',null,1,100000);
insert into public.organization_memberships(organization_id,user_id,role,active,all_properties)
select organization_id,'1b000000-0000-4000-8000-000000000002'::uuid,'front_desk'::public.member_role,true,true from shift_hotel
union all select organization_id,'1b000000-0000-4000-8000-000000000003'::uuid,'manager'::public.member_role,true,true from shift_hotel;
create temp table shift_stay as select public.create_priced_reservation(h.organization_id,h.property_id,r.id,'Shift guest',null,null,current_date,current_date+1,1::smallint,100000,null,null,null) as id
  from shift_hotel h join public.rooms r on r.property_id=h.property_id where r.room_number='101';
create temp table shift_ids(kind text primary key,id uuid);
insert into shift_ids select 'cash-method',m.id from shift_hotel h join public.payment_methods m on m.property_id=h.property_id where m.clearing_account_code='1000';

select set_config('request.jwt.claim.sub','1b000000-0000-4000-8000-000000000002',true);
insert into shift_ids select 'shift-one',public.open_cashier_shift(property_id,1000,'cashier-shift-open-one') from shift_hotel;
insert into shift_ids select 'payment-one',public.record_reservation_deposit(s.id,m.id,5000,'CASH-1','cashier-shift-payment-one') from shift_stay s,shift_ids m where m.kind='cash-method';
select is((select cashier_shift_id from public.payments where id=(select id from shift_ids where kind='payment-one')),(select id from shift_ids where kind='shift-one'),'cash payment attaches to the open cashier shift');
select is(public.request_close_cashier_shift((select id from shift_ids where kind='shift-one'),6000,null),'closed','balanced cash closes without approval');
select is((select variance_kobo from public.cashier_shifts where id=(select id from shift_ids where kind='shift-one')),0::bigint,'balanced shift stores zero variance');

insert into shift_ids select 'shift-two',public.open_cashier_shift(property_id,0,'cashier-shift-open-two') from shift_hotel;
insert into shift_ids select 'payment-two',public.record_reservation_deposit(s.id,m.id,1000,'CASH-2','cashier-shift-payment-two') from shift_stay s,shift_ids m where m.kind='cash-method';
select is(public.request_close_cashier_shift((select id from shift_ids where kind='shift-two'),500,'Drawer was five hundred naira short'),'pending_approval','cash variance requires approval');
select throws_ok($$select public.review_cashier_shift_close((select id from shift_ids where kind='shift-two'),true,null)$$,'42501',null,'front desk cannot approve a cash variance');

insert into shift_ids select 'refund-request',public.request_guest_payment_refund((select id from shift_ids where kind='payment-one'),500,'Guest was charged twice','cashier-refund-request-one');
select is((select status from public.refund_approval_requests where id=(select id from shift_ids where kind='refund-request')),'pending','refund request does not post immediately');
select ok(not has_function_privilege('authenticated','public.refund_guest_payment(uuid,bigint,text,text)','execute'),'authenticated clients cannot bypass refund approval');

select set_config('request.jwt.claim.sub','1b000000-0000-4000-8000-000000000001',true);
select is(public.review_cashier_shift_close((select id from shift_ids where kind='shift-two'),true,'Reviewed against the handover count'),'closed','another owner approves the cash variance');
select ok(public.review_guest_payment_refund((select id from shift_ids where kind='refund-request'),true,'Approved after checking the receipt') is not null,'another owner approves and posts the refund');
select is((select status from public.refund_approval_requests where id=(select id from shift_ids where kind='refund-request')),'approved','refund request records approval');
select is((select count(*)::int from public.payment_refunds where payment_id=(select id from shift_ids where kind='payment-one')),1,'approved refund posts exactly once');
select is((select count(*)::int from public.audit_events where action in ('cashier_shift_opened','cashier_shift_closed','cashier_shift_close_requested','cashier_shift_variance_approved','guest_refund_requested','guest_refund_approved')),7,'shift and refund decisions are audited');

select set_config('request.jwt.claim.sub','1b000000-0000-4000-8000-000000000003',true);
insert into shift_ids select 'manager-request',public.request_guest_payment_refund((select id from shift_ids where kind='payment-one'),500,'Second duplicate charge review','cashier-refund-manager');
select throws_ok($$select public.review_guest_payment_refund((select id from shift_ids where kind='manager-request'),true,null)$$,'23514',null,'manager cannot approve their own refund request');
select ok(not has_table_privilege('authenticated','public.cashier_shifts','insert'),'clients cannot insert cashier shifts directly');
select ok(not has_table_privilege('authenticated','public.refund_approval_requests','update'),'clients cannot approve refunds directly');

select * from finish();
rollback;
