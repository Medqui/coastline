-- SaaS plans and platform monitoring. Existing organizations retain unrestricted pilot access.
-- Platform admins are provisioned explicitly by a database administrator, never by hotel owners.
create schema if not exists saas_private;
revoke all on schema saas_private from public,anon,authenticated;

create table if not exists public.saas_plans (
  code text primary key check(code in ('starter','business','group')),
  name text not null, staff_limit integer check(staff_limit>0), property_limit integer check(property_limit>0),
  features text[] not null
);
insert into public.saas_plans values
 ('starter','Starter',5,1,array[]::text[]),
 ('business','Business',15,1,array['advanced_reports','supplier_accounts','inventory','staff_shifts']),
 ('group','Group',null,null,array['advanced_reports','supplier_accounts','inventory','staff_shifts','multi_property'])
on conflict(code) do nothing;

create table if not exists public.saas_platform_admins (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.saas_subscriptions (
  organization_id uuid primary key references public.organizations on delete cascade,
  plan_code text not null references public.saas_plans(code),
  status text not null check(status in ('trialing','active','past_due','expired','cancelled')),
  grandfathered boolean not null default false,
  trial_ends_at timestamptz, current_period_end timestamptz,
  monthly_fee_kobo bigint check(monthly_fee_kobo>=0),
  is_test boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(status<>'trialing' or trial_ends_at is not null),
  check(status<>'past_due' or current_period_end is not null)
);
create table if not exists public.saas_platform_events (
  id uuid primary key default gen_random_uuid(), actor_user_id uuid not null references auth.users,
  organization_id uuid not null references public.organizations,
  action text not null, reason text not null,
  before_data jsonb, after_data jsonb, created_at timestamptz not null default now()
);
-- This insert is deliberately idempotent and preserves any already assigned plan.
insert into public.saas_subscriptions(organization_id,plan_code,status,grandfathered)
select id,'group','active',true from public.organizations on conflict(organization_id) do nothing;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.saas_platform_admins where user_id=auth.uid())
$$;
revoke all on function public.is_platform_admin() from public,anon;
grant execute on function public.is_platform_admin() to authenticated;

alter table public.saas_plans enable row level security;
alter table public.saas_platform_admins enable row level security;
alter table public.saas_subscriptions enable row level security;
alter table public.saas_platform_events enable row level security;
revoke all on public.saas_plans,public.saas_platform_admins,public.saas_subscriptions,public.saas_platform_events from public,anon,authenticated;
grant select on public.saas_plans,public.saas_subscriptions to authenticated;
drop policy if exists saas_plans_read on public.saas_plans;
create policy saas_plans_read on public.saas_plans for select to authenticated using(true);
drop policy if exists saas_subscription_read on public.saas_subscriptions;
create policy saas_subscription_read on public.saas_subscriptions for select to authenticated using(public.is_org_member(organization_id));

create or replace function saas_private.access(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare s public.saas_subscriptions%rowtype; p public.saas_plans%rowtype; cutoff timestamptz; state text;
begin
 select * into s from public.saas_subscriptions where organization_id=p_org;
 if not found then return jsonb_build_object('access','read_only','features','[]'::jsonb,'plan_code',null); end if;
 select * into p from public.saas_plans where code=s.plan_code;
 cutoff:=case when s.status='trialing' then s.trial_ends_at else s.current_period_end end;
 state:=case
   when s.status='expired' then 'read_only'
   when s.status='cancelled' and (cutoff is null or cutoff<=now()) then 'read_only'
   when s.status in ('trialing','active','past_due') and cutoff is not null and cutoff<=now() then
     case when cutoff+interval '7 days'>now() then 'grace' else 'read_only' end
   else 'full' end;
 return jsonb_build_object('plan_code',s.plan_code,'plan_name',p.name,'status',s.status,'access',state,
  'features',to_jsonb(p.features),
  'staff_limit',case when s.grandfathered then null else p.staff_limit end,
  'property_limit',case when s.grandfathered then null else p.property_limit end,
  'grandfathered',s.grandfathered,'trial_ends_at',s.trial_ends_at,'current_period_end',s.current_period_end,
  'monthly_fee_kobo',s.monthly_fee_kobo);
end $$;
revoke all on function saas_private.access(uuid) from public,anon,authenticated;

create or replace function public.get_subscription_access(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_org_member(p_organization_id) then raise exception 'You cannot view this hotel subscription.' using errcode='42501'; end if;
 return saas_private.access(p_organization_id);
end $$;
revoke all on function public.get_subscription_access(uuid) from public,anon;
grant execute on function public.get_subscription_access(uuid) to authenticated;

create or replace function public.saas_has_feature(p_org uuid,p_feature text) returns boolean
language sql stable security definer set search_path='' as $$
 select public.is_org_member(p_org) and coalesce((saas_private.access(p_org)->'features') ? p_feature,false)
$$;
revoke all on function public.saas_has_feature(uuid,text) from public,anon;
grant execute on function public.saas_has_feature(uuid,text) to authenticated;

create or replace function saas_private.assert_property_feature(p_property uuid,p_feature text) returns void
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
 select organization_id into org from public.properties where id=p_property;
 if not public.can_access_property(org,p_property) or not public.saas_has_feature(org,p_feature) then
   raise exception 'Your plan does not include this feature. Contact the hotel owner to review the subscription.' using errcode='42501';
 end if;
end $$;
revoke all on function saas_private.assert_property_feature(uuid,text) from public,anon,authenticated;

create or replace function saas_private.seed_subscription() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.saas_subscriptions(organization_id,plan_code,status,trial_ends_at)
 values(new.id,'business','trialing',now()+interval '14 days') on conflict(organization_id) do nothing;
 return new;
end $$;
revoke all on function saas_private.seed_subscription() from public,anon,authenticated;
drop trigger if exists saas_seed_subscription on public.organizations;
create trigger saas_seed_subscription after insert on public.organizations for each row execute function saas_private.seed_subscription();

-- Guards run inside existing authenticated RPCs too; hiding buttons is not enforcement.
create or replace function saas_private.guard_write() returns trigger
language plpgsql security definer set search_path='' as $$
declare rowdata jsonb; org uuid; a jsonb; feature text:=tg_argv[0]; limit_value integer; used integer;
begin
 -- Authenticated requests always enforce plans. Only an actual database administrator
 -- with no end-user identity may replay migrations and maintain retained records.
 if auth.uid() is null and pg_has_role(session_user,'postgres','USAGE') then
  if tg_op='DELETE' then return old; end if; return new;
 end if;
 rowdata:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 org:=(case when tg_table_name='organizations' then rowdata->>'id' else rowdata->>'organization_id' end)::uuid;
 a:=saas_private.access(org);
 if a->>'access'='read_only' then raise exception 'This hotel subscription is read-only. Existing records and exports remain available.' using errcode='42501'; end if;
 if feature<>'' and not (a->'features' ? feature) then raise exception 'Your plan does not include this feature. Contact the hotel owner to review the subscription.' using errcode='42501'; end if;
 if tg_table_name in ('properties','organization_memberships','team_invitations') then
  perform pg_advisory_xact_lock(hashtextextended(org::text||':saas-capacity',0));
  a:=saas_private.access(org);
  if a->>'access'='read_only' then raise exception 'This hotel subscription is read-only.' using errcode='42501'; end if;
  if tg_table_name='properties' and tg_op='INSERT' then
   limit_value:=(a->>'property_limit')::integer;
   select count(*) into used from public.properties where organization_id=org;
   if limit_value is not null and used>=limit_value then raise exception 'Your plan has reached its hotel limit. The Group plan supports multiple properties.' using errcode='42501'; end if;
  elsif tg_table_name='organization_memberships' and coalesce((rowdata->>'active')::boolean,false) and (tg_op='INSERT' or not coalesce((to_jsonb(old)->>'active')::boolean,false)) then
   limit_value:=(a->>'staff_limit')::integer;
   select count(*) into used from public.organization_memberships where organization_id=org and active;
   used:=used+(select count(distinct i.email) from public.team_invitations i where i.organization_id=org and i.accepted_at is null and i.expires_at>now() and not exists(select 1 from auth.users u where u.id=(rowdata->>'user_id')::uuid and lower(u.email)=i.email) and not exists(select 1 from public.organization_memberships m join auth.users u on u.id=m.user_id where m.organization_id=org and m.active and lower(u.email)=i.email));
   if limit_value is not null and used>=limit_value then raise exception 'Your plan has reached its staff limit.' using errcode='42501'; end if;
  elsif tg_table_name='team_invitations' and tg_op='INSERT' then
   limit_value:=(a->>'staff_limit')::integer;
   select count(*) into used from public.organization_memberships where organization_id=org and active;
   used:=used+(select count(distinct email) from public.team_invitations where organization_id=org and accepted_at is null and expires_at>now() and email<>(rowdata->>'email'));
   if limit_value is not null and used>=limit_value then raise exception 'Your plan has reached its staff limit, including pending invitations.' using errcode='42501'; end if;
  end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
revoke all on function saas_private.guard_write() from public,anon,authenticated;

do $$ declare t text; f text; begin
 foreach t in array array['properties','organization_memberships','membership_properties','room_types','rooms','guests','reservations','reservation_rooms','folios','folio_items','payment_methods','accounts','journals','journal_lines','expenses','payments','guest_deposits','payment_refunds','team_invitations','maintenance_work_orders','room_rate_periods','reservation_night_rates','room_move_events','guest_deposit_applications','departments','cash_flow_classifications','property_floors','property_tax_rules','cashier_shifts','cashier_shift_movements','refund_approval_requests','suppliers','supplier_bills','supplier_bill_payments','bank_reconciliations','bank_statement_imports','bank_statement_lines','bank_statement_matches','bank_statement_exceptions','stock_items','stock_movements','staff_shifts'] loop
  -- Optional table names are checked explicitly: the application only supports installed modules.
  if to_regclass('public.'||t) is null then continue; end if;
  f:=case when t in ('stock_items','stock_movements') then 'inventory'
    when t in ('suppliers','supplier_bills','supplier_bill_payments') then 'supplier_accounts'
    when t like 'bank_%' then 'advanced_reports' when t='staff_shifts' then 'staff_shifts' else '' end;
  execute format('drop trigger if exists saas_plan_write on public.%I',t);
  execute format('create trigger saas_plan_write before insert or update or delete on public.%I for each row execute function saas_private.guard_write(%L)',t,f);
 end loop;
 foreach t in array array['stock_items','stock_movements','staff_shifts','suppliers','supplier_bills','supplier_bill_payments','bank_reconciliations','bank_statement_imports','bank_statement_lines','bank_statement_matches','bank_statement_exceptions'] loop
  if to_regclass('public.'||t) is null then continue; end if;
  f:=case when t like 'stock_%' then 'inventory' when t='staff_shifts' then 'staff_shifts' when t like 'supplier%' then 'supplier_accounts' else 'advanced_reports' end;
  execute format('drop policy if exists saas_plan_read on public.%I',t);
  execute format('create policy saas_plan_read on public.%I as restrictive for select to authenticated using(public.saas_has_feature(organization_id,%L))',t,f);
 end loop;
end $$;

drop policy if exists saas_receipts_write on storage.objects;
create policy saas_receipts_write on storage.objects as restrictive for insert to authenticated with check (
 bucket_id<>'expense-receipts' or case
  when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then public.get_subscription_access((storage.foldername(name))[1]::uuid)->>'access'<>'read_only'
  else false end
);

-- Aggregate SaaS metadata only. Guest names, folios and hotel financial details are not returned.
create or replace function public.get_platform_overview() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare hotels jsonb;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access is required.' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc),'[]'::jsonb) into hotels from (
  select o.id,o.name,o.created_at,s.is_test,s.monthly_fee_kobo,
   saas_private.access(o.id) as subscription,
   (select count(*) from public.properties p where p.organization_id=o.id) as properties,
   (select count(*) from public.rooms r where r.organization_id=o.id and r.active) as rooms,
   (select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active) as staff,
   (select u.email from public.organization_memberships m join auth.users u on u.id=m.user_id where m.organization_id=o.id and m.role='owner' and m.active order by m.created_at limit 1) as owner_email,
   (select max(a.created_at) from public.audit_events a where a.organization_id=o.id and a.action not in ('hotel_setup','property_created','staff_name_updated','team_invitation_created','team_invitation_accepted','member_role_changed')) as last_activity_at,
   (exists(select 1 from public.rooms r where r.organization_id=o.id and r.active) and exists(select 1 from public.organization_memberships m where m.organization_id=o.id and m.role='owner' and m.active)) as onboarded
  from public.organizations o join public.saas_subscriptions s on s.organization_id=o.id
 ) h;
 return jsonb_build_object('hotels',hotels,'as_of',now());
end $$;
revoke all on function public.get_platform_overview() from public,anon;
grant execute on function public.get_platform_overview() to authenticated;

create or replace function public.set_platform_subscription(p_organization_id uuid,p_plan_code text,p_status text,
 p_period_end timestamptz,p_monthly_fee_kobo bigint,p_is_test boolean,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare before_row public.saas_subscriptions%rowtype; after_row public.saas_subscriptions%rowtype; used_staff integer; used_properties integer; p public.saas_plans%rowtype;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access is required.' using errcode='42501'; end if;
 if length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Give a reason for this subscription change.' using errcode='22023'; end if;
 if p_status not in ('trialing','active','past_due','expired','cancelled') or p_status is null then raise exception 'Choose a valid subscription status.'; end if;
 if p_status in ('trialing','past_due') and p_period_end is null then raise exception 'Choose the trial or billing end date.'; end if;
 select * into p from public.saas_plans where code=p_plan_code;
 if not found then raise exception 'Choose an existing plan.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text||':saas-capacity',0));
 select * into before_row from public.saas_subscriptions where organization_id=p_organization_id for update;
 if not found then raise exception 'Hotel subscription not found.'; end if;
 select count(*) into used_staff from public.organization_memberships where organization_id=p_organization_id and active;
 used_staff:=used_staff+(select count(distinct i.email) from public.team_invitations i where i.organization_id=p_organization_id and i.accepted_at is null and i.expires_at>now() and not exists(select 1 from public.organization_memberships m join auth.users u on u.id=m.user_id where m.organization_id=p_organization_id and m.active and lower(u.email)=i.email));
 select count(*) into used_properties from public.properties where organization_id=p_organization_id;
 if (p.staff_limit is not null and used_staff>p.staff_limit) or (p.property_limit is not null and used_properties>p.property_limit) then raise exception 'This hotel exceeds the selected plan limits. Reduce usage before changing its plan.'; end if;
 update public.saas_subscriptions set plan_code=p_plan_code,status=p_status,grandfathered=false,
  trial_ends_at=case when p_status='trialing' then p_period_end else trial_ends_at end,
  current_period_end=case when p_status='trialing' then null else p_period_end end,
  monthly_fee_kobo=p_monthly_fee_kobo,is_test=p_is_test,updated_at=now()
 where organization_id=p_organization_id returning * into after_row;
 insert into public.saas_platform_events(actor_user_id,organization_id,action,reason,before_data,after_data)
 values(auth.uid(),p_organization_id,'subscription_updated',btrim(p_reason),to_jsonb(before_row),to_jsonb(after_row));
end $$;
revoke all on function public.set_platform_subscription(uuid,text,text,timestamptz,bigint,boolean,text) from public,anon;
grant execute on function public.set_platform_subscription(uuid,text,text,timestamptz,bigint,boolean,text) to authenticated;

-- Forward definitions retain original signatures, role checks and execute grants.
create or replace function public.assert_finance_report_access(p_property_id uuid) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  perform saas_private.assert_property_feature(p_property_id,'advanced_reports');
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501';
  end if;
  return v_org;
end $$;

create or replace function public.get_trial_balance(p_property_id uuid,p_as_of date)
returns table(account_code text,account_name text,account_type text,debit_balance_kobo bigint,credit_balance_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  perform saas_private.assert_property_feature(p_property_id,'advanced_reports');
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select a.code,a.name,a.account_type,
    greatest(sum(l.debit_kobo-l.credit_kobo),0)::bigint,greatest(sum(l.credit_kobo-l.debit_kobo),0)::bigint
  from public.accounts a join public.journal_lines l on l.organization_id=a.organization_id and l.account_id=a.id
    join public.journals j on j.organization_id=l.organization_id and j.id=l.journal_id
  where a.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_as_of
  group by a.code,a.name,a.account_type having sum(l.debit_kobo+l.credit_kobo)>0 order by a.code;
end $$;

create or replace function public.get_department_profit_and_loss(p_property_id uuid,p_from date,p_to date)
returns table(department_code text,department_name text,revenue_kobo bigint,expense_kobo bigint,net_income_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  perform saas_private.assert_property_feature(p_property_id,'advanced_reports');
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a period of up to one year.' using errcode='22023'; end if;
  return query with amounts as(
    select coalesce(d.code,case j.source_type when 'room_night' then 'accommodation' when 'folio_extra' then 'services' when 'expense' then 'administration' else 'unallocated' end) as code,
      coalesce(d.name,case j.source_type when 'room_night' then 'Accommodation' when 'folio_extra' then 'Guest services' when 'expense' then 'Administration' else 'Unallocated historical entries' end) as name,
      case when a.account_type='revenue' then l.credit_kobo-l.debit_kobo else 0 end as revenue,
      case when a.account_type='expense' then l.debit_kobo-l.credit_kobo else 0 end as expense
    from public.journals j join public.journal_lines l on l.organization_id=j.organization_id and l.journal_id=j.id
      join public.accounts a on a.organization_id=l.organization_id and a.id=l.account_id
      left join public.departments d on d.id=j.department_id
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date between p_from and p_to and a.account_type in ('revenue','expense'))
    select x.code,x.name,sum(x.revenue)::bigint,sum(x.expense)::bigint,sum(x.revenue-x.expense)::bigint from amounts x group by x.code,x.name order by x.code;
end $$;

create or replace function public.get_supplier_bill_balances(p_property_id uuid,p_as_of date)
returns table(bill_id uuid,supplier_id uuid,supplier_name text,bill_number text,invoice_date date,posting_date date,due_date date,description text,amount_kobo bigint,paid_kobo bigint,outstanding_kobo bigint,status text,receipt_path text)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  perform saas_private.assert_property_feature(p_property_id,'supplier_accounts');
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view supplier accounts for this property.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select b.id,s.id,s.name,b.bill_number,b.invoice_date,b.posting_date,b.due_date,b.description,b.amount_kobo,
    coalesce(p.paid,0)::bigint,case when j.journal_date<=p_as_of then 0 else b.amount_kobo-coalesce(p.paid,0) end::bigint,
    case when j.journal_date<=p_as_of then 'void' else 'posted' end,b.receipt_path
    from public.supplier_bills b join public.suppliers s on s.id=b.supplier_id
      left join public.journals j on j.id=b.reversal_journal_id
      left join lateral(select sum(x.amount_kobo)::bigint as paid from public.supplier_bill_payments x left join public.journals r on r.id=x.reversal_journal_id
        where x.bill_id=b.id and x.payment_date<=p_as_of and (r.journal_date is null or r.journal_date>p_as_of)) p on true
    where b.organization_id=v_org and b.property_id=p_property_id and b.posting_date<=p_as_of order by b.posting_date desc,b.id;
end $$;

create or replace function public.get_supplier_payment_history(p_property_id uuid,p_as_of date)
returns table(payment_id uuid,bill_id uuid,bill_number text,supplier_name text,payment_date date,amount_kobo bigint,method_name text,reference text,status text,reversal_date date,reversal_reason text)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  perform saas_private.assert_property_feature(p_property_id,'supplier_accounts');
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view supplier payments for this property.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select p.id,b.id,b.bill_number,s.name,p.payment_date,p.amount_kobo,m.name,p.reference,
    case when r.journal_date<=p_as_of then 'reversed' else 'posted' end,
    case when r.journal_date<=p_as_of then r.journal_date end,case when r.journal_date<=p_as_of then p.reversal_reason end
    from public.supplier_bill_payments p join public.supplier_bills b on b.id=p.bill_id join public.suppliers s on s.id=b.supplier_id
      join public.payment_methods m on m.id=p.payment_method_id left join public.journals r on r.id=p.reversal_journal_id
    where p.organization_id=v_org and p.property_id=p_property_id and p.payment_date<=p_as_of order by p.payment_date desc,p.created_at desc;
end $$;

create or replace function public.staff_handover_summary(p_property_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare org uuid;today date;result jsonb;start_time timestamptz;
begin
  perform saas_private.assert_property_feature(p_property_id,'staff_shifts');
 select organization_id,(now() at time zone timezone)::date into org,today from public.properties where id=p_property_id;
 if org is null or not public.can_access_property(org,p_property_id) then raise exception 'You cannot view this handover.' using errcode='42501'; end if;
 select started_at into start_time from public.staff_shifts where organization_id=org and property_id=p_property_id and user_id=auth.uid() and ended_at is null;
 select jsonb_build_object('arrivals',count(*) filter(where status='confirmed' and arrival_date=today),'departures',count(*) filter(where status='checked_in' and departure_date<=today),'in_house',count(*) filter(where status='checked_in')) into result from public.reservations where property_id=p_property_id;
 result:=result||jsonb_build_object('dirty_rooms',(select count(*) from public.rooms where property_id=p_property_id and active and housekeeping_status='dirty'));
 if public.has_org_role(org,array['owner','manager','front_desk','accountant']::public.member_role[]) then
  result:=result||jsonb_build_object('outstanding_kobo',coalesce((select sum(balance) from (select greatest(sum(i.total_amount_kobo),0) balance from public.folios f join public.folio_items i on i.folio_id=f.id where f.property_id=p_property_id and f.status='open' group by f.id) b),0),'my_cash_received_kobo',coalesce((select sum(p.amount_kobo) from public.payments p join public.payment_methods m on m.id=p.payment_method_id where p.property_id=p_property_id and p.received_by=auth.uid() and p.received_at>=start_time and m.clearing_account_code='1000'),0));
 end if;
 return result;
end $$;

create or replace function public.get_shift_handovers(p_property_id uuid)
returns table(id uuid,staff_name text,staff_role public.member_role,started_at timestamptz,ended_at timestamptz,handover_note text,handover_summary jsonb)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;myrole public.member_role;
begin
  perform saas_private.assert_property_feature(p_property_id,'staff_shifts');
 select organization_id into org from public.properties where public.properties.id=p_property_id;
 if org is null or not public.can_access_property(org,p_property_id) then raise exception 'You cannot view this property’s handovers.' using errcode='42501'; end if;
 select role into myrole from public.organization_memberships where organization_id=org and user_id=auth.uid() and active;
 return query select s.id,s.staff_name,s.staff_role,s.started_at,s.ended_at,s.handover_note,
 case when myrole in ('owner','manager') then s.handover_summary else s.handover_summary-'my_cash_received_kobo' end
 from public.staff_shifts s where s.property_id=p_property_id and s.ended_at is not null and (myrole in ('owner','manager') or s.staff_role=myrole) order by s.ended_at desc limit 20;
end $$;

create or replace function public.get_bank_statement_lines(p_reconciliation_id uuid)
returns table(line_id uuid,transaction_date date,description text,reference text,amount_kobo bigint,balance_kobo bigint,status text,match_id uuid,matched_journal_id uuid,exception_reason text)
language plpgsql stable security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;
begin
  perform saas_private.assert_property_feature((select property_id from public.bank_reconciliations where id=p_reconciliation_id),'advanced_reports');
  select * into r from public.bank_reconciliations where id=p_reconciliation_id;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this bank reconciliation.' using errcode='42501'; end if;
  return query select l.id,l.transaction_date,l.description,l.reference,l.amount_kobo,l.balance_kobo,
    case when m.id is not null then 'matched' when e.id is not null then 'exception' else 'unmatched' end,m.id,m.journal_id,e.reason
    from public.bank_statement_lines l
      left join public.bank_statement_matches m on m.statement_line_id=l.id and m.status='active'
      left join public.bank_statement_exceptions e on e.statement_line_id=l.id and e.status='open'
    where l.reconciliation_id=r.id order by l.transaction_date,l.line_number,l.id;
end $$;

create or replace function public.get_bank_ledger_candidates(p_reconciliation_id uuid)
returns table(journal_id uuid,journal_date date,memo text,source_type text,amount_kobo bigint,status text,matched_statement_line_id uuid)
language plpgsql stable security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;account_code text;account uuid;
begin
  perform saas_private.assert_property_feature((select property_id from public.bank_reconciliations where id=p_reconciliation_id),'advanced_reports');
  select * into r from public.bank_reconciliations where id=p_reconciliation_id;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this bank reconciliation.' using errcode='42501'; end if;
  select clearing_account_code into account_code from public.payment_methods where id=r.payment_method_id and organization_id=r.organization_id and property_id=r.property_id;
  select id into account from public.accounts where organization_id=r.organization_id and code=account_code;
  return query select j.id,j.journal_date,j.memo,j.source_type,sum(l.debit_kobo-l.credit_kobo)::bigint,
    case when m.id is null then 'unmatched' else 'matched' end,m.statement_line_id
    from public.journals j join public.journal_lines l on (l.organization_id,l.journal_id)=(j.organization_id,j.id) and l.account_id=account
      left join public.bank_statement_matches m on m.reconciliation_id=r.id and m.journal_id=j.id and m.status='active'
    where j.organization_id=r.organization_id and j.property_id=r.property_id and j.status='posted' and j.journal_date between r.period_from and r.period_to
    group by j.id,j.journal_date,j.memo,j.source_type,m.id,m.statement_line_id
    having sum(l.debit_kobo-l.credit_kobo)<>0 order by j.journal_date,j.id;
end $$;


-- Explicit platform-owner bootstrap authorized for this deployment. Hotel roles do not grant it.
insert into public.saas_platform_admins(user_id)
select id from auth.users where lower(email)='aletomiwa@gmail.com'
on conflict(user_id) do nothing;
