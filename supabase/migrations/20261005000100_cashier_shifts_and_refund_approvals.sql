-- Cashier accountability, tender close and separated refund approval.
create table if not exists public.cashier_shifts(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  cashier_user_id uuid not null references auth.users,opened_by uuid not null references auth.users,
  opened_at timestamptz not null default now(),opening_float_kobo bigint not null check(opening_float_kobo>=0),
  status text not null default 'open' check(status in ('open','pending_approval','closed')),
  expected_cash_kobo bigint,counted_cash_kobo bigint,variance_kobo bigint,close_reason text,
  tender_totals jsonb,close_requested_by uuid references auth.users,close_requested_at timestamptz,
  approved_by uuid references auth.users,approved_at timestamptz,closed_by uuid references auth.users,closed_at timestamptz,
  idempotency_key text not null,created_at timestamptz not null default now(),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  unique(organization_id,idempotency_key),unique(organization_id,property_id,id),
  check((status='open' and expected_cash_kobo is null and counted_cash_kobo is null and variance_kobo is null and close_requested_at is null and closed_at is null)
    or (status='pending_approval' and expected_cash_kobo is not null and counted_cash_kobo is not null and variance_kobo<>0 and close_requested_by is not null and close_requested_at is not null and close_reason is not null and length(btrim(close_reason)) between 5 and 500 and closed_at is null)
    or (status='closed' and expected_cash_kobo is not null and counted_cash_kobo is not null and variance_kobo is not null and close_requested_by is not null and close_requested_at is not null and closed_by is not null and closed_at is not null
      and ((variance_kobo=0 and approved_by is null and approved_at is null) or (variance_kobo<>0 and approved_by is not null and approved_at is not null and approved_by<>cashier_user_id))))
);
create unique index if not exists cashier_one_active_shift on public.cashier_shifts(organization_id,property_id,cashier_user_id) where status in ('open','pending_approval');
create index if not exists cashier_shifts_property_idx on public.cashier_shifts(property_id,opened_at desc);

alter table public.payments add column if not exists cashier_shift_id uuid;
alter table public.payment_refunds add column if not exists cashier_shift_id uuid;
do $$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.payments'::regclass and conname='payments_cashier_shift_fk') then
    alter table public.payments add constraint payments_cashier_shift_fk foreign key(organization_id,property_id,cashier_shift_id) references public.cashier_shifts(organization_id,property_id,id);
  end if;
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.payment_refunds'::regclass and conname='payment_refunds_cashier_shift_fk') then
    alter table public.payment_refunds add constraint payment_refunds_cashier_shift_fk foreign key(organization_id,property_id,cashier_shift_id) references public.cashier_shifts(organization_id,property_id,id);
  end if;
end $$;
create index if not exists payments_cashier_shift_idx on public.payments(cashier_shift_id) where cashier_shift_id is not null;
create index if not exists payment_refunds_cashier_shift_idx on public.payment_refunds(cashier_shift_id) where cashier_shift_id is not null;
create unique index if not exists payments_org_property_id_uidx on public.payments(organization_id,property_id,id);
create unique index if not exists payment_refunds_org_property_id_uidx on public.payment_refunds(organization_id,property_id,id);

create table if not exists public.refund_approval_requests(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,payment_id uuid not null,
  amount_kobo bigint not null check(amount_kobo>0),reason text not null check(length(btrim(reason)) between 5 and 500),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),idempotency_key text not null,
  requested_by uuid not null references auth.users,requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users,reviewed_at timestamptz,review_note text,refund_id uuid references public.payment_refunds,
  foreign key(organization_id,property_id,payment_id) references public.payments(organization_id,property_id,id),
  unique(organization_id,idempotency_key),unique(organization_id,property_id,id),
  check((status='pending' and reviewed_by is null and reviewed_at is null and refund_id is null)
    or (status='approved' and reviewed_by is not null and reviewed_at is not null and reviewed_by<>requested_by and refund_id is not null)
    or (status='rejected' and reviewed_by is not null and reviewed_at is not null and reviewed_by<>requested_by and refund_id is null and review_note is not null and length(btrim(review_note)) between 5 and 500))
);
create index if not exists refund_approval_pending_idx on public.refund_approval_requests(property_id,requested_at) where status='pending';

do $$ declare t text;begin
  foreach t in array array['cashier_shifts','refund_approval_requests'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists operations_read on public.%I',t);
    execute format('create policy operations_read on public.%I for select to authenticated using(public.can_access_property(organization_id,property_id) and (public.has_org_role(organization_id,array[''owner'',''manager'']::public.member_role[]) or %s))',t,
      case when t='cashier_shifts' then 'cashier_user_id=auth.uid()' else 'requested_by=auth.uid()' end);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
  end loop;
end $$;

create or replace function public.assign_open_cashier_shift() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.cashier_shift_id is null then
    select id into new.cashier_shift_id from public.cashier_shifts where organization_id=new.organization_id and property_id=new.property_id
      and cashier_user_id=auth.uid() and status='open' order by opened_at desc limit 1;
  end if;
  return new;
end $$;
revoke all on function public.assign_open_cashier_shift() from public,anon,authenticated;
drop trigger if exists payment_assign_cashier_shift on public.payments;
create trigger payment_assign_cashier_shift before insert on public.payments for each row execute function public.assign_open_cashier_shift();
drop trigger if exists refund_assign_cashier_shift on public.payment_refunds;
create trigger refund_assign_cashier_shift before insert on public.payment_refunds for each row execute function public.assign_open_cashier_shift();

create or replace function public.cashier_shift_tenders(p_shift_id uuid)
returns table(payment_method_id uuid,method_name text,received_kobo bigint,refunded_kobo bigint,net_kobo bigint)
language sql stable security definer set search_path='' as $$
  with movements as(
    select p.payment_method_id,p.amount_kobo as received,0::bigint as refunded from public.payments p where p.cashier_shift_id=p_shift_id
    union all
    select p.payment_method_id,0::bigint,r.amount_kobo from public.payment_refunds r join public.payments p on p.id=r.payment_id where r.cashier_shift_id=p_shift_id
  )
  select m.id,m.name,coalesce(sum(x.received),0)::bigint,coalesce(sum(x.refunded),0)::bigint,
    (coalesce(sum(x.received),0)-coalesce(sum(x.refunded),0))::bigint
  from public.payment_methods m join public.cashier_shifts s on s.id=p_shift_id and (s.organization_id,s.property_id)=(m.organization_id,m.property_id)
    left join movements x on x.payment_method_id=m.id
  where m.active or x.payment_method_id is not null group by m.id,m.name order by m.name
$$;
revoke all on function public.cashier_shift_tenders(uuid) from public,anon,authenticated;

create or replace function public.open_cashier_shift(p_property_id uuid,p_opening_float_kobo bigint,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;prior public.cashier_shifts%rowtype;result uuid;
begin
  select organization_id into org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(org,p_property_id) or not public.has_org_role(org,array['owner','manager','front_desk']::public.member_role[]) then
    raise exception 'You cannot open a cashier shift for this property.' using errcode='42501'; end if;
  if p_opening_float_kobo is null or p_opening_float_kobo<0 or p_opening_float_kobo>100000000000 or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter a valid opening cash float and transaction key.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(org::text||':cashier-shift:'||auth.uid()::text,0));
  select * into prior from public.cashier_shifts where organization_id=org and idempotency_key=p_idempotency_key;
  if found then
    if prior.property_id<>p_property_id or prior.cashier_user_id<>auth.uid() or prior.opening_float_kobo<>p_opening_float_kobo then raise exception 'Transaction key was already used for another shift.' using errcode='23505'; end if;
    return prior.id;
  end if;
  if exists(select 1 from public.cashier_shifts where organization_id=org and property_id=p_property_id and cashier_user_id=auth.uid() and status in ('open','pending_approval')) then
    raise exception 'Close or resolve your current cashier shift before opening another.' using errcode='23514'; end if;
  insert into public.cashier_shifts(organization_id,property_id,cashier_user_id,opened_by,opening_float_kobo,idempotency_key)
    values(org,p_property_id,auth.uid(),auth.uid(),p_opening_float_kobo,p_idempotency_key) returning id into result;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(org,p_property_id,auth.uid(),'cashier_shift_opened','cashier_shift',result,jsonb_build_object('opening_float_kobo',p_opening_float_kobo));
  return result;
end $$;
revoke all on function public.open_cashier_shift(uuid,bigint,text) from public,anon;
grant execute on function public.open_cashier_shift(uuid,bigint,text) to authenticated;

create or replace function public.request_close_cashier_shift(p_shift_id uuid,p_counted_cash_kobo bigint,p_reason text)
returns text language plpgsql security definer set search_path='' as $$
declare s public.cashier_shifts%rowtype;expected bigint;variance bigint;totals jsonb;
begin
  select * into s from public.cashier_shifts where id=p_shift_id for update;
  if not found or s.cashier_user_id<>auth.uid() or not public.can_access_property(s.organization_id,s.property_id) then
    raise exception 'You can only close your own cashier shift.' using errcode='42501'; end if;
  if s.status<>'open' or p_counted_cash_kobo is null or p_counted_cash_kobo<0 then raise exception 'Enter a valid counted cash amount for an open shift.' using errcode='22023'; end if;
  select s.opening_float_kobo+coalesce(sum(case when m.clearing_account_code='1000' then p.amount_kobo else 0 end),0)
    -coalesce((select sum(case when rm.clearing_account_code='1000' then r.amount_kobo else 0 end) from public.payment_refunds r join public.payments rp on rp.id=r.payment_id join public.payment_methods rm on rm.id=rp.payment_method_id where r.cashier_shift_id=s.id),0)
    into expected from public.payments p join public.payment_methods m on m.id=p.payment_method_id where p.cashier_shift_id=s.id;
  variance:=p_counted_cash_kobo-expected;
  if variance<>0 and coalesce(length(btrim(p_reason)),0) not between 5 and 500 then raise exception 'Explain the cash variance in 5 to 500 characters.' using errcode='22023'; end if;
  select coalesce(jsonb_object_agg(t.method_name,jsonb_build_object('received_kobo',t.received_kobo,'refunded_kobo',t.refunded_kobo,'net_kobo',t.net_kobo)),'{}'::jsonb)
    into totals from public.cashier_shift_tenders(s.id) t;
  update public.cashier_shifts set expected_cash_kobo=expected,counted_cash_kobo=p_counted_cash_kobo,variance_kobo=variance,
    close_reason=case when variance=0 then null else btrim(p_reason) end,tender_totals=totals,close_requested_by=auth.uid(),close_requested_at=now(),
    status=case when variance=0 then 'closed' else 'pending_approval' end,closed_by=case when variance=0 then auth.uid() end,closed_at=case when variance=0 then now() end
    where id=s.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(s.organization_id,s.property_id,auth.uid(),case when variance=0 then 'cashier_shift_closed' else 'cashier_shift_close_requested' end,'cashier_shift',s.id,
      jsonb_build_object('expected_cash_kobo',expected,'counted_cash_kobo',p_counted_cash_kobo,'variance_kobo',variance,'reason',nullif(btrim(p_reason),'')));
  return case when variance=0 then 'closed' else 'pending_approval' end;
end $$;
revoke all on function public.request_close_cashier_shift(uuid,bigint,text) from public,anon;
grant execute on function public.request_close_cashier_shift(uuid,bigint,text) to authenticated;

create or replace function public.review_cashier_shift_close(p_shift_id uuid,p_approve boolean,p_note text)
returns text language plpgsql security definer set search_path='' as $$
declare s public.cashier_shifts%rowtype;
begin
  select * into s from public.cashier_shifts where id=p_shift_id for update;
  if not found or not public.can_access_property(s.organization_id,s.property_id) or not public.has_org_role(s.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can review a cash variance.' using errcode='42501'; end if;
  if s.status<>'pending_approval' then raise exception 'This shift is not awaiting variance approval.' using errcode='23514'; end if;
  if s.cashier_user_id=auth.uid() then raise exception 'A cashier cannot approve their own variance.' using errcode='23514'; end if;
  if p_approve is null or (not p_approve and coalesce(length(btrim(p_note)),0) not between 5 and 500) or coalesce(length(p_note),0)>500 then
    raise exception 'Enter valid review details and explain a rejection.' using errcode='22023'; end if;
  if p_approve then
    update public.cashier_shifts set status='closed',approved_by=auth.uid(),approved_at=now(),closed_by=auth.uid(),closed_at=now() where id=s.id;
  else
    update public.cashier_shifts set status='open',expected_cash_kobo=null,counted_cash_kobo=null,variance_kobo=null,close_reason=null,tender_totals=null,
      close_requested_by=null,close_requested_at=null where id=s.id;
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(s.organization_id,s.property_id,auth.uid(),case when p_approve then 'cashier_shift_variance_approved' else 'cashier_shift_close_rejected' end,'cashier_shift',s.id,
      jsonb_build_object('variance_kobo',s.variance_kobo,'cashier_user_id',s.cashier_user_id),jsonb_build_object('note',nullif(btrim(p_note),'')));
  return case when p_approve then 'closed' else 'open' end;
end $$;
revoke all on function public.review_cashier_shift_close(uuid,boolean,text) from public,anon;
grant execute on function public.review_cashier_shift_close(uuid,boolean,text) to authenticated;

create or replace function public.get_cashier_shifts(p_property_id uuid,p_limit integer default 30)
returns table(shift_id uuid,cashier_user_id uuid,cashier_email text,opened_at timestamptz,opening_float_kobo bigint,status text,expected_cash_kobo bigint,counted_cash_kobo bigint,variance_kobo bigint,close_reason text,tender_totals jsonb,closed_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(org,p_property_id) or not public.has_org_role(org,array['owner','manager','front_desk']::public.member_role[]) then raise exception 'You cannot view cashier shifts for this property.' using errcode='42501'; end if;
  return query select s.id,s.cashier_user_id,u.email::text,s.opened_at,s.opening_float_kobo,s.status,s.expected_cash_kobo,s.counted_cash_kobo,s.variance_kobo,s.close_reason,
    case when s.tender_totals is not null then s.tender_totals else (select coalesce(jsonb_object_agg(t.method_name,jsonb_build_object('received_kobo',t.received_kobo,'refunded_kobo',t.refunded_kobo,'net_kobo',t.net_kobo)),'{}'::jsonb) from public.cashier_shift_tenders(s.id) t) end,s.closed_at
    from public.cashier_shifts s join auth.users u on u.id=s.cashier_user_id where s.organization_id=org and s.property_id=p_property_id
      and (public.has_org_role(org,array['owner','manager']::public.member_role[]) or s.cashier_user_id=auth.uid()) order by s.opened_at desc limit least(greatest(coalesce(p_limit,30),1),100);
end $$;
revoke all on function public.get_cashier_shifts(uuid,integer) from public,anon;
grant execute on function public.get_cashier_shifts(uuid,integer) to authenticated;

create or replace function public.request_guest_payment_refund(p_payment_id uuid,p_amount_kobo bigint,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p public.payments%rowtype;f public.folios%rowtype;d public.guest_deposits%rowtype;prior public.refund_approval_requests%rowtype;used bigint;pending bigint;result uuid;
begin
  select * into p from public.payments where id=p_payment_id for update;
  if not found or not public.can_access_property(p.organization_id,p.property_id) or not public.has_org_role(p.organization_id,array['owner','manager','front_desk']::public.member_role[]) then
    raise exception 'You cannot request a refund for this payment.' using errcode='42501'; end if;
  if p_amount_kobo is null or p_amount_kobo<=0 or coalesce(length(btrim(p_reason)),0) not between 5 and 500 or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter a positive refund, a reason and transaction key.' using errcode='22023'; end if;
  select * into prior from public.refund_approval_requests where organization_id=p.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.payment_id<>p_payment_id or prior.amount_kobo<>p_amount_kobo or prior.reason<>btrim(p_reason) then raise exception 'Transaction key was already used for another refund request.' using errcode='23505'; end if;
    return prior.id;
  end if;
  select * into f from public.folios where id=p.folio_id for update;
  if f.status<>'open' then raise exception 'Only payments on an open folio can be refunded.' using errcode='23514'; end if;
  select coalesce(sum(amount_kobo),0) into used from public.payment_refunds where organization_id=p.organization_id and payment_id=p.id;
  select coalesce(sum(amount_kobo),0) into pending from public.refund_approval_requests where organization_id=p.organization_id and payment_id=p.id and status='pending';
  if p.is_deposit then
    select * into d from public.guest_deposits where payment_id=p.id for update;
    if p_amount_kobo>d.amount_kobo-d.applied_kobo-d.refunded_kobo-pending then raise exception 'Refund request exceeds the unapplied deposit after pending requests.' using errcode='23514'; end if;
  elsif p_amount_kobo>p.amount_kobo-used-pending then raise exception 'Refund request exceeds the remaining payment after pending requests.' using errcode='23514'; end if;
  insert into public.refund_approval_requests(organization_id,property_id,payment_id,amount_kobo,reason,idempotency_key,requested_by)
    values(p.organization_id,p.property_id,p.id,p_amount_kobo,btrim(p_reason),p_idempotency_key,auth.uid()) returning id into result;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(p.organization_id,p.property_id,auth.uid(),'guest_refund_requested','refund_approval_request',result,jsonb_build_object('payment_id',p.id,'amount_kobo',p_amount_kobo,'reason',btrim(p_reason)));
  return result;
end $$;
revoke all on function public.request_guest_payment_refund(uuid,bigint,text,text) from public,anon;
grant execute on function public.request_guest_payment_refund(uuid,bigint,text,text) to authenticated;

create or replace function public.review_guest_payment_refund(p_request_id uuid,p_approve boolean,p_review_note text)
returns uuid language plpgsql security definer set search_path='' as $$
declare r public.refund_approval_requests%rowtype;refund uuid;
begin
  select * into r from public.refund_approval_requests where id=p_request_id for update;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can review refund requests.' using errcode='42501'; end if;
  if r.status<>'pending' then return r.refund_id; end if;
  if r.requested_by=auth.uid() then raise exception 'You cannot approve your own refund request.' using errcode='23514'; end if;
  if p_approve is null or (not p_approve and coalesce(length(btrim(p_review_note)),0) not between 5 and 500) or coalesce(length(p_review_note),0)>500 then
    raise exception 'Enter valid review details and explain a rejection.' using errcode='22023'; end if;
  if p_approve then
    refund:=public.refund_guest_payment(r.payment_id,r.amount_kobo,r.reason,r.idempotency_key);
    update public.refund_approval_requests set status='approved',reviewed_by=auth.uid(),reviewed_at=now(),review_note=nullif(btrim(p_review_note),''),refund_id=refund where id=r.id;
  else
    update public.refund_approval_requests set status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(p_review_note) where id=r.id;
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(r.organization_id,r.property_id,auth.uid(),case when p_approve then 'guest_refund_approved' else 'guest_refund_rejected' end,'refund_approval_request',r.id,
      jsonb_build_object('requested_by',r.requested_by,'amount_kobo',r.amount_kobo),jsonb_build_object('refund_id',refund,'review_note',nullif(btrim(p_review_note),'')));
  return refund;
end $$;
revoke all on function public.review_guest_payment_refund(uuid,boolean,text) from public,anon;
grant execute on function public.review_guest_payment_refund(uuid,boolean,text) to authenticated;

create or replace function public.get_refund_approval_requests(p_property_id uuid,p_status text default 'pending')
returns table(request_id uuid,payment_id uuid,amount_kobo bigint,reason text,status text,requested_by uuid,requester_email text,requested_at timestamptz,reviewed_by uuid,reviewed_at timestamptz,review_note text,refund_id uuid)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;
begin
  select organization_id into org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(org,p_property_id) or not public.has_org_role(org,array['owner','manager','front_desk']::public.member_role[]) then raise exception 'You cannot view refund requests for this property.' using errcode='42501'; end if;
  if p_status not in ('pending','approved','rejected','all') then raise exception 'Choose a valid refund request status.' using errcode='22023'; end if;
  return query select r.id,r.payment_id,r.amount_kobo,r.reason,r.status,r.requested_by,u.email::text,r.requested_at,r.reviewed_by,r.reviewed_at,r.review_note,r.refund_id
    from public.refund_approval_requests r join auth.users u on u.id=r.requested_by where r.organization_id=org and r.property_id=p_property_id
      and (p_status='all' or r.status=p_status) and (public.has_org_role(org,array['owner','manager']::public.member_role[]) or r.requested_by=auth.uid())
    order by r.requested_at desc limit 100;
end $$;
revoke all on function public.get_refund_approval_requests(uuid,text) from public,anon;
grant execute on function public.get_refund_approval_requests(uuid,text) to authenticated;

revoke execute on function public.refund_guest_payment(uuid,bigint,text,text) from authenticated;
notify pgrst,'reload schema';
