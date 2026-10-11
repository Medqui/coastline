-- Launch pricing and a separate, immutable ledger for Coastline subscription receipts.
-- This never changes an existing customer's plan or agreed monthly fee.
create table if not exists public.saas_plan_prices (
 plan_code text primary key references public.saas_plans(code),
 monthly_price_kobo bigint not null check(monthly_price_kobo>0 and monthly_price_kobo<=9007199254740991),
 custom_quote boolean not null default false
);
insert into public.saas_plan_prices(plan_code,monthly_price_kobo,custom_quote) values
 ('starter',1500000,false),('business',3500000,false),('group',7500000,true)
on conflict(plan_code) do nothing;
alter table public.saas_plan_prices enable row level security;
revoke all on public.saas_plan_prices from public,anon,authenticated;
grant select on public.saas_plan_prices to authenticated;
drop policy if exists saas_plan_prices_read on public.saas_plan_prices;
create policy saas_plan_prices_read on public.saas_plan_prices for select to authenticated using(true);

create table if not exists public.saas_subscription_receipts (
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique,
 organization_id uuid not null references public.organizations,
 plan_code text not null references public.saas_plans(code),
 entry_type text not null check(entry_type in ('payment','refund')),
 original_payment_id uuid references public.saas_subscription_receipts(id),
 amount_kobo bigint not null check(amount_kobo>0 and amount_kobo<=9007199254740991),
 received_on date not null, method text not null check(method in ('bank_transfer','cash','card','other')),
 reference text not null check(length(btrim(reference)) between 2 and 150),
 note text not null check(length(btrim(note)) between 5 and 500),
 is_test boolean not null,
 recorded_by uuid not null references auth.users, created_at timestamptz not null default now(),
 check((entry_type='payment' and original_payment_id is null) or (entry_type='refund' and original_payment_id is not null))
);
create unique index if not exists saas_receipt_reference_unique on public.saas_subscription_receipts(lower(reference));
create index if not exists saas_receipt_org_date on public.saas_subscription_receipts(organization_id,received_on);
create index if not exists saas_receipt_refunds on public.saas_subscription_receipts(original_payment_id) where entry_type='refund';
alter table public.saas_subscription_receipts enable row level security;
revoke all on public.saas_subscription_receipts from public,anon,authenticated;

create or replace function saas_private.immutable_subscription_receipt() returns trigger
language plpgsql set search_path='' as $$ begin
 raise exception 'Subscription receipts are permanent. Record a refund to correct a payment.' using errcode='42501';
end $$;
drop trigger if exists saas_receipts_immutable on public.saas_subscription_receipts;
create trigger saas_receipts_immutable before update or delete on public.saas_subscription_receipts
for each row execute function saas_private.immutable_subscription_receipt();
revoke all on function saas_private.immutable_subscription_receipt() from public,anon,authenticated;

create or replace function public.record_subscription_receipt(p_request_id uuid,p_organization_id uuid,p_plan_code text,
 p_entry_type text,p_original_payment_id uuid,p_amount_kobo bigint,p_received_on date,p_method text,p_reference text,p_note text) returns uuid
language plpgsql security definer set search_path='' as $$
declare old public.saas_subscription_receipts%rowtype; original public.saas_subscription_receipts%rowtype;
 s public.saas_subscriptions%rowtype; receipt public.saas_subscription_receipts%rowtype; refunded numeric; resolved_plan text;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access is required.' using errcode='42501'; end if;
 if p_request_id is null then raise exception 'A receipt request is required.'; end if;
 if p_amount_kobo is null or p_amount_kobo<=0 or p_amount_kobo>9007199254740991 then raise exception 'Enter a positive payment amount.'; end if;
 if p_received_on is null or p_received_on>(now() at time zone 'Africa/Lagos')::date then raise exception 'Choose today or an earlier payment date.'; end if;
 if p_entry_type is null or p_entry_type not in ('payment','refund') then raise exception 'Choose payment or refund.'; end if;
 if p_method is null or p_method not in ('bank_transfer','cash','card','other') then raise exception 'Choose a payment method.'; end if;
 if length(btrim(coalesce(p_reference,''))) not between 2 and 150 then raise exception 'Enter a unique payment reference between 2 and 150 characters.'; end if;
 if length(btrim(coalesce(p_note,''))) not between 5 and 500 then raise exception 'Add a note between 5 and 500 characters.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text||':saas-receipt',0));
 select * into old from public.saas_subscription_receipts where request_id=p_request_id;
 if found then
  if old.organization_id=p_organization_id and old.entry_type=p_entry_type
   and old.original_payment_id is not distinct from p_original_payment_id
   and (p_entry_type='refund' or old.plan_code=p_plan_code)
   and old.amount_kobo=p_amount_kobo and old.received_on=p_received_on and old.method=p_method
   and old.reference=btrim(p_reference) and old.note=btrim(p_note) and old.recorded_by=auth.uid()
  then return old.id; end if;
  raise exception 'This request was already used for a different receipt.';
 end if;
 select * into s from public.saas_subscriptions where organization_id=p_organization_id;
 if not found then raise exception 'Hotel subscription not found.'; end if;
 if p_entry_type='refund' then
  select * into original from public.saas_subscription_receipts where id=p_original_payment_id for update;
  if not found or original.entry_type<>'payment' or original.organization_id<>p_organization_id then raise exception 'Choose the original payment for this customer.'; end if;
  if p_received_on<original.received_on then raise exception 'The refund cannot be dated before its payment.'; end if;
  select coalesce(sum(amount_kobo),0) into refunded from public.saas_subscription_receipts where original_payment_id=original.id;
  if refunded+p_amount_kobo>original.amount_kobo then raise exception 'This refund exceeds the payment’s remaining refundable amount.'; end if;
  resolved_plan:=original.plan_code;
 else
  if p_original_payment_id is not null then raise exception 'A payment cannot refer to an earlier payment.'; end if;
  if not exists(select 1 from public.saas_plan_prices where plan_code=p_plan_code) then raise exception 'Choose the plan this payment covers.'; end if;
  resolved_plan:=p_plan_code;
 end if;
 insert into public.saas_subscription_receipts(request_id,organization_id,plan_code,entry_type,original_payment_id,amount_kobo,received_on,method,reference,note,is_test,recorded_by)
 values(p_request_id,p_organization_id,resolved_plan,p_entry_type,p_original_payment_id,p_amount_kobo,p_received_on,p_method,btrim(p_reference),btrim(p_note),s.is_test or coalesce(original.is_test,false),auth.uid()) returning * into receipt;
 insert into public.saas_platform_events(actor_user_id,organization_id,action,reason,after_data)
 values(auth.uid(),p_organization_id,'subscription_'||p_entry_type||'_recorded',btrim(p_note),to_jsonb(receipt));
 return receipt.id;
exception when unique_violation then
 raise exception 'This payment reference is already recorded. Use the correct unique reference.';
end $$;
revoke all on function public.record_subscription_receipt(uuid,uuid,text,text,uuid,bigint,date,text,text,text) from public,anon;
grant execute on function public.record_subscription_receipt(uuid,uuid,text,text,uuid,bigint,date,text,text,text) to authenticated;

create or replace function public.get_platform_revenue(p_include_tests boolean default false) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare report jsonb; month_start date:=(date_trunc('month',now() at time zone 'Africa/Lagos'))::date;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access is required.' using errcode='42501'; end if;
 with customers as (
  select s.*,saas_private.access(s.organization_id)->>'access' as access from public.saas_subscriptions s
  where coalesce(p_include_tests,false) or not s.is_test
 ), recurring as (
  select * from customers where not grandfathered and status='active' and access='full' and monthly_fee_kobo>0
 ), entries as (
  select r.*,o.name as organization_name from public.saas_subscription_receipts r
  join public.organizations o on o.id=r.organization_id join customers s on s.organization_id=r.organization_id
  where coalesce(p_include_tests,false) or not r.is_test
 ), monthly as (
  select to_char(m,'YYYY-MM') as month,
   coalesce(sum(r.amount_kobo) filter(where r.entry_type='payment'),0) as received_kobo,
   coalesce(sum(r.amount_kobo) filter(where r.entry_type='refund'),0) as refunded_kobo
  from generate_series(month_start-interval '11 months',month_start,interval '1 month') m
  left join entries r on r.received_on>=m::date and r.received_on<(m+interval '1 month')::date group by m
 ), tiers as (
  select p.code,
   (select count(*) from recurring c where c.plan_code=p.code) as customers,
   (select coalesce(sum(c.monthly_fee_kobo),0) from recurring c where c.plan_code=p.code) as mrr_kobo,
   (select coalesce(sum(case when r.entry_type='payment' then r.amount_kobo else -r.amount_kobo end),0) from entries r where r.plan_code=p.code and r.received_on>=month_start) as net_this_month_kobo
  from public.saas_plans p
 ), recent as (
  select r.*,coalesce((select sum(x.amount_kobo) from public.saas_subscription_receipts x where x.original_payment_id=r.id),0) as refunded_kobo
  from entries r order by r.received_on desc,r.created_at desc,r.id desc limit 50
 )
 select jsonb_build_object(
  'as_of',now(),'include_tests',coalesce(p_include_tests,false),
  'prices',(select jsonb_object_agg(plan_code,monthly_price_kobo) from public.saas_plan_prices),
  'mrr_kobo',(select coalesce(sum(monthly_fee_kobo),0) from recurring),
  'paying_customers',(select count(*) from recurring),
  'at_risk_mrr_kobo',(select coalesce(sum(monthly_fee_kobo),0) from customers where not grandfathered and monthly_fee_kobo>0 and (status='past_due' or (status='active' and access<>'full'))),
  'received_this_month_kobo',(select coalesce(sum(amount_kobo),0) from entries where entry_type='payment' and received_on>=month_start),
  'refunded_this_month_kobo',(select coalesce(sum(amount_kobo),0) from entries where entry_type='refund' and received_on>=month_start),
  'received_all_time_kobo',(select coalesce(sum(amount_kobo),0) from entries where entry_type='payment'),
  'refunded_all_time_kobo',(select coalesce(sum(amount_kobo),0) from entries where entry_type='refund'),
  'months',(select coalesce(jsonb_agg(to_jsonb(m) order by month),'[]'::jsonb) from monthly m),
  'tiers',(select coalesce(jsonb_agg(to_jsonb(t) order by code),'[]'::jsonb) from tiers t),
  'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by received_on desc,created_at desc,id desc),'[]'::jsonb) from recent r)
 ) into report;
 return report;
end $$;
revoke all on function public.get_platform_revenue(boolean) from public,anon;
grant execute on function public.get_platform_revenue(boolean) to authenticated;
