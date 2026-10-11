-- Platform receipt authorization and exact cash/MRR calculations. No fixture survives.
begin;
create function pg_temp.assert_true(value boolean,label text) returns void language plpgsql as $$ begin if value is distinct from true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.expect_failure(sql text,code text,label text) returns void language plpgsql as $$
declare actual text;
begin
 begin execute sql; exception when others then get stacked diagnostics actual=returned_sqlstate; end;
 if actual is null or (code is not null and actual<>code) then raise exception 'FAIL: % (expected %, got %)',label,code,actual; end if;
end $$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('21000000-0000-4000-8000-000000000001','revenue-owner@test.local','{}'),
 ('21000000-0000-4000-8000-000000000002','revenue-admin@test.local','{}'),
 ('21000000-0000-4000-8000-000000000003','revenue-test-owner@test.local','{}'),
 ('21000000-0000-4000-8000-000000000004','revenue-trial-owner@test.local','{}'),
 ('21000000-0000-4000-8000-000000000005','revenue-pilot-owner@test.local','{}');
insert into public.saas_platform_admins(user_id) values('21000000-0000-4000-8000-000000000002');
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000001',true);
create temp table revenue_hotel as select * from public.setup_hotel('Revenue customer','Revenue property',null,1,100000);
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000003',true);
create temp table revenue_test as select * from public.setup_hotel('Test customer','Test property',null,1,100000);
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000004',true);
create temp table revenue_trial as select * from public.setup_hotel('Trial customer','Trial property',null,1,100000);
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000005',true);
create temp table revenue_pilot as select * from public.setup_hotel('Pilot customer','Pilot property',null,1,100000);
update public.saas_subscriptions set grandfathered=true,monthly_fee_kobo=7500000 where organization_id=(select organization_id from revenue_pilot);
create temp table revenue_ids(kind text,id uuid); grant select,insert on revenue_ids to authenticated;
grant select on revenue_hotel,revenue_test,revenue_trial,revenue_pilot to authenticated;
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select pg_temp.assert_true((select monthly_price_kobo=1500000 from public.saas_plan_prices where plan_code='starter'),'Starter price is readable and exact');
select pg_temp.assert_true((select monthly_price_kobo=3500000 from public.saas_plan_prices where plan_code='business'),'Business price is exact');
select pg_temp.assert_true((select monthly_price_kobo=7500000 and custom_quote from public.saas_plan_prices where plan_code='group'),'Group starts at 75000 and supports quotes');
select pg_temp.expect_failure('select public.get_platform_revenue(false)','42501','hotel owners cannot see platform revenue');
select pg_temp.expect_failure('select * from public.saas_subscription_receipts','42501','hotel owners cannot enumerate receipts');
select pg_temp.expect_failure($q$update public.saas_plan_prices set monthly_price_kobo=1$q$,'42501','customers cannot change catalogue prices');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),organization_id,'starter','payment',null,1500000,current_date,'bank_transfer','TEST-NOT-ADMIN','Unauthorized payment') from revenue_hotel$q$,'42501','owners cannot record platform money');
select set_config('request.jwt.claim.sub','21000000-0000-4000-8000-000000000002',true);
select pg_temp.assert_true((public.get_platform_revenue(false)->>'mrr_kobo')::bigint=0,'trials and pilots have zero contracted MRR');
select public.set_platform_subscription(organization_id,'starter','active',now()+interval '30 days',1500000,false,'Starter pricing test') from revenue_hotel;
select public.set_platform_subscription(organization_id,'group','active',now()+interval '30 days',7500000,true,'Test pricing workspace') from revenue_test;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'mrr_kobo')::bigint=1500000,'normal MRR excludes test accounts, pilots and trials');
select pg_temp.assert_true((public.get_platform_revenue(true)->>'mrr_kobo')::bigint=9000000,'including tests adds only contracted test MRR');
insert into revenue_ids select 'payment',public.record_subscription_receipt('21000000-0000-4000-8000-000000000010',organization_id,'starter','payment',null,1500000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','REV-PAYMENT-1','Starter subscription received') from revenue_hotel;
select pg_temp.assert_true((select public.record_subscription_receipt('21000000-0000-4000-8000-000000000010',h.organization_id,'starter','payment',null,1500000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','REV-PAYMENT-1','Starter subscription received')=r.id from revenue_hotel h,revenue_ids r where r.kind='payment'),'request retry returns the original receipt');
select pg_temp.expect_failure($q$select public.record_subscription_receipt('21000000-0000-4000-8000-000000000010',organization_id,'starter','payment',null,2000000,current_date,'bank_transfer','REV-PAYMENT-1','Starter subscription received') from revenue_hotel$q$,null,'request reuse cannot alter the amount');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),organization_id,'starter','payment',null,1500000,current_date,'bank_transfer','rev-payment-1','Duplicate transfer reference') from revenue_hotel$q$,null,'case-insensitive reference duplicates are rejected');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),organization_id,'starter','payment',null,-1,current_date,'cash','REV-NEGATIVE','Invalid negative payment') from revenue_hotel$q$,null,'negative payments are rejected');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),organization_id,'starter','payment',null,100,(now() at time zone 'Africa/Lagos')::date+1,'cash','REV-FUTURE','Invalid future payment') from revenue_hotel$q$,null,'future payments are rejected');
select public.record_subscription_receipt(gen_random_uuid(),organization_id,'group','payment',null,7500000,(now() at time zone 'Africa/Lagos')::date,'cash','REV-TEST-1','Test workspace receipt') from revenue_test;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'received_this_month_kobo')::bigint=1500000,'real collections exclude test receipts');
select pg_temp.assert_true((public.get_platform_revenue(true)->>'received_this_month_kobo')::bigint=9000000,'test receipts are included only explicitly');
insert into revenue_ids select 'refund',public.record_subscription_receipt('21000000-0000-4000-8000-000000000011',h.organization_id,'business','refund',r.id,300000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','REV-REFUND-1','Partial refund was issued') from revenue_hotel h,revenue_ids r where r.kind='payment';
select pg_temp.assert_true((public.get_platform_revenue(false)->>'refunded_this_month_kobo')::bigint=300000,'refund collections are tracked separately');
select pg_temp.assert_true((select (r->>'refunded_kobo')::bigint=300000 from jsonb_array_elements(public.get_platform_revenue(false)->'receipts') r where r->>'entry_type'='payment'),'remaining refundable balance uses all refunds');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),h.organization_id,'starter','refund',r.id,1200001,current_date,'cash','REV-TOO-LARGE','Invalid excess refund') from revenue_hotel h,revenue_ids r where r.kind='payment'$q$,null,'refund cannot exceed remaining balance');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),h.organization_id,'starter','refund',r.id,100,current_date-1,'cash','REV-BEFORE','Refund predates payment') from revenue_hotel h,revenue_ids r where r.kind='payment'$q$,null,'refund cannot precede the payment');
select pg_temp.expect_failure($q$select public.record_subscription_receipt(gen_random_uuid(),h.organization_id,'starter','refund',r.id,100,current_date,'cash','REV-WRONG-HOTEL','Wrong hotel for refund') from revenue_test h,revenue_ids r where r.kind='payment'$q$,null,'refund must match the original customer');
select public.set_platform_subscription(organization_id,'business','active',now()+interval '30 days',3500000,false,'Upgrade preserves historic collections') from revenue_hotel;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'mrr_kobo')::bigint=3500000,'upgrade changes contracted MRR immediately');
select pg_temp.assert_true((select (t->>'net_this_month_kobo')::bigint=1200000 from jsonb_array_elements(public.get_platform_revenue(false)->'tiers') t where t->>'code'='starter'),'cash remains attributed to the plan originally paid for');
select public.record_subscription_receipt(gen_random_uuid(),organization_id,'business','payment',null,700000,(date_trunc('month',now() at time zone 'Africa/Lagos'))::date-1,'cash','REV-PRIOR-MONTH','Prior month payment received') from revenue_hotel;
select public.record_subscription_receipt(gen_random_uuid(),h.organization_id,'business','payment',null,10000,(now() at time zone 'Africa/Lagos')::date,'cash','REV-BATCH-'||n,'Additional subscription payment') from revenue_hotel h,generate_series(1,51) n;
select pg_temp.assert_true(jsonb_array_length(public.get_platform_revenue(false)->'receipts')=50,'history limits only visible entries');
select pg_temp.assert_true((public.get_platform_revenue(false)->>'received_this_month_kobo')::bigint=2010000,'month totals include receipts outside the newest 50');
select pg_temp.assert_true((public.get_platform_revenue(false)->>'received_all_time_kobo')::bigint=2710000,'all-time totals include the prior month');
select pg_temp.assert_true(jsonb_array_length(public.get_platform_revenue(false)->'months')=12,'twelve real monthly trend buckets are provided');
select pg_temp.assert_true((select sum((m->>'received_kobo')::bigint)=2710000 from jsonb_array_elements(public.get_platform_revenue(false)->'months') m),'trend sums agree with complete collections');
select public.set_platform_subscription(organization_id,'business','past_due',now()-interval '2 days',3500000,false,'Overdue subscription revenue test') from revenue_hotel;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'at_risk_mrr_kobo')::bigint=3500000,'overdue contracted amounts are flagged at risk');
select pg_temp.assert_true((public.get_platform_revenue(false)->>'mrr_kobo')::bigint=0,'overdue subscriptions are excluded from active MRR');
reset role;
select pg_temp.expect_failure($q$update public.saas_subscription_receipts set amount_kobo=1$q$,'42501','posted receipt amounts cannot be edited');
select pg_temp.expect_failure($q$delete from public.saas_subscription_receipts$q$,'42501','posted receipts cannot be deleted');
select pg_temp.assert_true((select count(*)=55 from public.saas_subscription_receipts),'failed attempts and retries do not create extra receipts');
select pg_temp.assert_true((select count(*)=55 from public.saas_platform_events where action in ('subscription_payment_recorded','subscription_refund_recorded')),'successful entries record the administrator in the audit history');
select pg_temp.assert_true((select plan_code='starter' from public.saas_subscription_receipts where entry_type='refund'),'refund inherits the original tier');
update public.saas_subscriptions set is_test=false where organization_id=(select organization_id from revenue_test);
set local role authenticated;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'received_all_time_kobo')::bigint=2710000,'converting a test hotel does not turn historic test receipts into real revenue');
reset role;
-- A refund remains real money even if its customer was temporarily marked as a test.
update public.saas_subscriptions set is_test=true where organization_id=(select organization_id from revenue_hotel);
set local role authenticated;
select public.record_subscription_receipt(gen_random_uuid(),h.organization_id,'business','refund',r.id,100000,(now() at time zone 'Africa/Lagos')::date,'bank_transfer','REV-CLASSIFICATION-REFUND','Refund issued during a workspace classification change') from revenue_hotel h,revenue_ids r where r.kind='payment';
reset role;
select pg_temp.assert_true((select not is_test from public.saas_subscription_receipts where reference='REV-CLASSIFICATION-REFUND'),'a real-payment refund keeps its original non-test classification');
update public.saas_subscriptions set is_test=false where organization_id=(select organization_id from revenue_hotel);
set local role authenticated;
select pg_temp.assert_true((public.get_platform_revenue(false)->>'refunded_all_time_kobo')::bigint=400000,'real refunds are counted after restoring normal workspace classification');
reset role;
rollback;
select 'PASS: subscription pricing, authorization, immutable receipts, retries, refunds, historical attribution and complete revenue totals';
