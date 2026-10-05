-- Guest advances remain liabilities until applied. Refunds retain source and reason.
alter table public.payments add column if not exists is_deposit boolean not null default false;
create unique index if not exists payments_org_id_uidx on public.payments(organization_id,id);
insert into public.accounts(organization_id,code,name,account_type)
select id,'2100','Guest deposits','liability' from public.organizations
on conflict (organization_id,code) do nothing;
create or replace function public.seed_guest_deposit_account() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.accounts(organization_id,code,name,account_type)
    values(new.id,'2100','Guest deposits','liability') on conflict (organization_id,code) do nothing;
  return new;
end $$;
drop trigger if exists seed_deposit_account on public.organizations;
create trigger seed_deposit_account after insert on public.organizations for each row execute function public.seed_guest_deposit_account();

create table if not exists public.guest_deposits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  folio_id uuid not null,
  payment_id uuid not null,
  amount_kobo bigint not null check(amount_kobo>0),
  applied_kobo bigint not null default 0 check(applied_kobo>=0),
  refunded_kobo bigint not null default 0 check(refunded_kobo>=0),
  created_at timestamptz not null default now(),
  unique(organization_id,payment_id), unique(organization_id,id),
  check(applied_kobo+refunded_kobo<=amount_kobo),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,folio_id) references public.folios(organization_id,id),
  foreign key(organization_id,payment_id) references public.payments(organization_id,id)
);
create table if not exists public.guest_deposit_applications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  deposit_id uuid not null,
  amount_kobo bigint not null check(amount_kobo>0),
  idempotency_key text not null,
  journal_id uuid not null,
  created_by uuid references auth.users,
  created_at timestamptz not null default now(),
  unique(organization_id,idempotency_key),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,deposit_id) references public.guest_deposits(organization_id,id),
  foreign key(organization_id,journal_id) references public.journals(organization_id,id)
);
create table if not exists public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  payment_id uuid not null,
  amount_kobo bigint not null check(amount_kobo>0),
  reason text not null check(length(btrim(reason))>=3),
  idempotency_key text not null,
  journal_id uuid not null,
  created_by uuid references auth.users,
  created_at timestamptz not null default now(),
  unique(organization_id,idempotency_key),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,payment_id) references public.payments(organization_id,id),
  foreign key(organization_id,journal_id) references public.journals(organization_id,id)
);
alter table public.guest_deposits enable row level security;
alter table public.guest_deposit_applications enable row level security;
alter table public.payment_refunds enable row level security;
drop policy if exists guest_deposits_read on public.guest_deposits;
create policy guest_deposits_read on public.guest_deposits for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
drop policy if exists guest_deposit_applications_read on public.guest_deposit_applications;
create policy guest_deposit_applications_read on public.guest_deposit_applications for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
drop policy if exists payment_refunds_read on public.payment_refunds;
create policy payment_refunds_read on public.payment_refunds for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
grant select on public.guest_deposits,public.guest_deposit_applications,public.payment_refunds to authenticated;

create or replace function public.record_reservation_deposit(p_reservation_id uuid,p_payment_method_id uuid,
  p_amount_kobo bigint,p_reference text,p_idempotency_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_folio uuid; v_method public.payment_methods%rowtype;
  v_existing public.payments%rowtype; v_payment uuid; v_date date; v_journal uuid;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot take deposits for this stay.' using errcode='42501'; end if;
  if v_res.status not in ('confirmed','checked_in') then raise exception 'This stay cannot accept deposits.' using errcode='23514'; end if;
  if p_amount_kobo is null or p_amount_kobo<=0 or length(coalesce(p_idempotency_key,''))<8 then
    raise exception 'Enter a positive deposit and transaction key.' using errcode='22023'; end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_res.organization_id
    and property_id=v_res.property_id and active;
  if not found then raise exception 'Choose a valid payment method.' using errcode='22023'; end if;
  select * into v_existing from public.payments where organization_id=v_res.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if not v_existing.is_deposit or v_existing.amount_kobo<>p_amount_kobo or
      v_existing.payment_method_id<>p_payment_method_id or
      not exists(select 1 from public.folios where id=v_existing.folio_id and reservation_id=p_reservation_id) then
      raise exception 'Transaction key was already used for a different payment.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  select id into v_folio from public.folios where organization_id=v_res.organization_id and reservation_id=p_reservation_id for update;
  if v_folio is null then
    insert into public.folios(organization_id,property_id,reservation_id,status)
      values(v_res.organization_id,v_res.property_id,p_reservation_id,'open') returning id into v_folio;
  end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_res.property_id;
  insert into public.payments(organization_id,property_id,folio_id,payment_method_id,amount_kobo,
    reference,idempotency_key,received_by,is_deposit)
    values(v_res.organization_id,v_res.property_id,v_folio,p_payment_method_id,p_amount_kobo,
      nullif(btrim(p_reference),''),p_idempotency_key,auth.uid(),true) returning id into v_payment;
  v_journal:=public.post_accounting_event(v_res.organization_id,v_res.property_id,'guest_deposit',v_payment,v_date,
    'Guest advance via '||v_method.name,p_amount_kobo,v_method.clearing_account_code,'2100','deposit:'||p_idempotency_key);
  insert into public.guest_deposits(organization_id,property_id,folio_id,payment_id,amount_kobo)
    values(v_res.organization_id,v_res.property_id,v_folio,v_payment,p_amount_kobo);
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_res.organization_id,v_res.property_id,auth.uid(),'guest_deposit_received','payment',v_payment,
      jsonb_build_object('amount_kobo',p_amount_kobo));
  return v_payment;
end $$;

create or replace function public.apply_guest_deposit(p_deposit_id uuid,p_amount_kobo bigint,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_deposit public.guest_deposits%rowtype; v_folio public.folios%rowtype;
  v_balance bigint; v_date date; v_journal uuid; v_application uuid; v_existing uuid; v_existing_amount bigint;
begin
  select * into v_deposit from public.guest_deposits where id=p_deposit_id for update;
  if not found then raise exception 'Deposit not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_deposit.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_deposit.organization_id,v_deposit.property_id) then
    raise exception 'You cannot apply this deposit.' using errcode='42501'; end if;
  if p_amount_kobo is null or p_amount_kobo<=0 or length(coalesce(p_idempotency_key,''))<8 then
    raise exception 'Enter a positive amount and transaction key.' using errcode='22023'; end if;
  select id,amount_kobo into v_existing,v_existing_amount from public.guest_deposit_applications
    where organization_id=v_deposit.organization_id and idempotency_key=p_idempotency_key;
  if v_existing is not null then
    if v_existing_amount<>p_amount_kobo or not exists(select 1 from public.guest_deposit_applications
      where id=v_existing and deposit_id=p_deposit_id) then
      raise exception 'Transaction key was already used for a different application.' using errcode='23505'; end if;
    return v_existing;
  end if;
  select * into v_folio from public.folios where id=v_deposit.folio_id for update;
  if v_folio.status<>'open' then raise exception 'Folio is closed.' using errcode='23514'; end if;
  if p_amount_kobo>v_deposit.amount_kobo-v_deposit.applied_kobo-v_deposit.refunded_kobo then
    raise exception 'Deposit amount exceeds the unapplied balance.' using errcode='23514'; end if;
  select coalesce(sum(total_amount_kobo),0) into v_balance from public.folio_items
    where organization_id=v_deposit.organization_id and folio_id=v_deposit.folio_id;
  if p_amount_kobo>v_balance then raise exception 'Apply no more than the folio balance.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_deposit.property_id;
  v_journal:=public.post_accounting_event(v_deposit.organization_id,v_deposit.property_id,'deposit_application',p_deposit_id,
    v_date,'Apply guest deposit',p_amount_kobo,'2100','1100','apply:'||p_idempotency_key);
  insert into public.guest_deposit_applications(organization_id,property_id,deposit_id,amount_kobo,idempotency_key,journal_id,created_by)
    values(v_deposit.organization_id,v_deposit.property_id,p_deposit_id,p_amount_kobo,p_idempotency_key,v_journal,auth.uid())
    returning id into v_application;
  update public.guest_deposits set applied_kobo=applied_kobo+p_amount_kobo where id=p_deposit_id;
  insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,
    unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
    values(v_deposit.organization_id,v_deposit.property_id,v_deposit.folio_id,'payment','Deposit applied',v_date,
      -p_amount_kobo,-p_amount_kobo,auth.uid(),'apply:'||p_idempotency_key,v_journal);
  return v_application;
end $$;

create or replace function public.refund_guest_payment(p_payment_id uuid,p_amount_kobo bigint,p_reason text,
  p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_payment public.payments%rowtype; v_method public.payment_methods%rowtype;
  v_folio public.folios%rowtype; v_deposit public.guest_deposits%rowtype;
  v_prior bigint; v_date date; v_journal uuid; v_refund uuid; v_existing public.payment_refunds%rowtype;
begin
  select * into v_payment from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_payment.organization_id,array['owner','manager']::public.member_role[])
    or not public.can_access_property(v_payment.organization_id,v_payment.property_id) then
    raise exception 'Only an owner or manager can refund this payment.' using errcode='42501'; end if;
  if p_amount_kobo is null or p_amount_kobo<=0 or length(btrim(coalesce(p_reason,'')))<3
    or length(coalesce(p_idempotency_key,''))<8 then
    raise exception 'Enter a positive refund, reason and transaction key.' using errcode='22023'; end if;
  select * into v_existing from public.payment_refunds
    where organization_id=v_payment.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.payment_id<>p_payment_id or v_existing.amount_kobo<>p_amount_kobo then
      raise exception 'Transaction key was already used for a different refund.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  select * into v_method from public.payment_methods where id=v_payment.payment_method_id;
  select * into v_folio from public.folios where id=v_payment.folio_id for update;
  if v_folio.status<>'open' then raise exception 'Only payments on an open folio can be refunded.' using errcode='23514'; end if;
  select coalesce(sum(amount_kobo),0) into v_prior from public.payment_refunds
    where organization_id=v_payment.organization_id and payment_id=p_payment_id;
  if v_payment.is_deposit then
    select * into v_deposit from public.guest_deposits where payment_id=p_payment_id for update;
    if p_amount_kobo>v_deposit.amount_kobo-v_deposit.applied_kobo-v_deposit.refunded_kobo then
      raise exception 'Refund exceeds the unapplied deposit.' using errcode='23514'; end if;
  elsif p_amount_kobo>v_payment.amount_kobo-v_prior then
    raise exception 'Refund exceeds the remaining payment.' using errcode='23514';
  end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_payment.property_id;
  v_journal:=public.post_accounting_event(v_payment.organization_id,v_payment.property_id,'payment_refund',p_payment_id,
    v_date,'Refund · '||btrim(p_reason),p_amount_kobo,
    case when v_payment.is_deposit then '2100' else '1100' end,v_method.clearing_account_code,
    'refund:'||p_idempotency_key);
  insert into public.payment_refunds(organization_id,property_id,payment_id,amount_kobo,reason,idempotency_key,journal_id,created_by)
    values(v_payment.organization_id,v_payment.property_id,p_payment_id,p_amount_kobo,btrim(p_reason),
      p_idempotency_key,v_journal,auth.uid()) returning id into v_refund;
  if v_payment.is_deposit then
    update public.guest_deposits set refunded_kobo=refunded_kobo+p_amount_kobo where id=v_deposit.id;
  else
    insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,
      unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
      values(v_payment.organization_id,v_payment.property_id,v_payment.folio_id,'refund','Refund · '||btrim(p_reason),
        v_date,p_amount_kobo,p_amount_kobo,auth.uid(),'refund:'||p_idempotency_key,v_journal);
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_payment.organization_id,v_payment.property_id,auth.uid(),'guest_payment_refunded','payment',p_payment_id,
      jsonb_build_object('amount_kobo',p_amount_kobo,'reason',btrim(p_reason),'refund_id',v_refund));
  return v_refund;
end $$;

-- Reuse a deposit folio on check-in instead of creating a second folio.
create or replace function public.check_in_reservation(p_reservation_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_reservation public.reservations%rowtype; v_room_id uuid;
  v_room_status public.room_housekeeping_status; v_folio_id uuid; v_today date;
begin
  if v_user is null then raise exception 'Sign in before checking in a guest.' using errcode='28000'; end if;
  select * into v_reservation from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_reservation.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_reservation.organization_id,v_reservation.property_id) then
    raise exception 'You do not have permission to check in this reservation.' using errcode='42501'; end if;
  if v_reservation.status='checked_in' then
    select id into v_folio_id from public.folios where organization_id=v_reservation.organization_id and reservation_id=p_reservation_id;
    return v_folio_id;
  end if;
  if v_reservation.status<>'confirmed' then raise exception 'Only confirmed reservations can be checked in.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_reservation.property_id;
  if v_today<v_reservation.arrival_date or v_today>=v_reservation.departure_date then
    raise exception 'Check-in is available on the arrival date and before departure.' using errcode='22023'; end if;
  select room_id into v_room_id from public.reservation_rooms
    where organization_id=v_reservation.organization_id and reservation_id=p_reservation_id limit 1;
  if v_room_id is null then raise exception 'Assign a room before checking in.' using errcode='23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_room_id::text,0));
  select housekeeping_status into v_room_status from public.rooms where id=v_room_id for update;
  if v_room_status not in ('clean','inspected') then raise exception 'Room is not ready. Mark it clean first.' using errcode='23514'; end if;
  if exists(select 1 from public.reservation_rooms rr join public.reservations r
    on r.organization_id=rr.organization_id and r.id=rr.reservation_id
    where rr.room_id=v_room_id and rr.reservation_id<>p_reservation_id
      and rr.check_in_date<=v_today and rr.check_out_date>v_today and r.status='checked_in') then
    raise exception 'This room is currently occupied by another stay.' using errcode='23P01'; end if;
  update public.reservations set status='checked_in' where id=p_reservation_id;
  select id into v_folio_id from public.folios where organization_id=v_reservation.organization_id and reservation_id=p_reservation_id for update;
  if v_folio_id is null then
    insert into public.folios(organization_id,property_id,reservation_id,status)
      values(v_reservation.organization_id,v_reservation.property_id,p_reservation_id,'open') returning id into v_folio_id;
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_reservation.organization_id,v_reservation.property_id,v_user,'guest_checked_in','reservation',p_reservation_id,
      jsonb_build_object('folio_id',v_folio_id));
  return v_folio_id;
end $$;

create or replace function public.guard_unapplied_deposit_checkout() returns trigger language plpgsql set search_path='' as $$
begin
  if old.status='open' and new.status='closed' and exists(select 1 from public.guest_deposits
    where organization_id=new.organization_id and folio_id=new.id and amount_kobo>applied_kobo+refunded_kobo) then
    raise exception 'Apply or refund every deposit before checkout.' using errcode='23514'; end if;
  return new;
end $$;
drop trigger if exists guard_unapplied_deposit_checkout on public.folios;
create trigger guard_unapplied_deposit_checkout before update of status on public.folios
  for each row execute function public.guard_unapplied_deposit_checkout();

create or replace function public.guard_reservation_close_with_deposit() returns trigger language plpgsql set search_path='' as $$
begin
  if old.status='confirmed' and new.status in ('cancelled','no_show') and exists(
    select 1 from public.folios f join public.guest_deposits d
      on d.organization_id=f.organization_id and d.folio_id=f.id
    where f.organization_id=new.organization_id and f.reservation_id=new.id
      and d.amount_kobo>d.applied_kobo+d.refunded_kobo) then
    raise exception 'Refund the remaining deposit before cancelling or marking no-show.' using errcode='23514'; end if;
  return new;
end $$;
drop trigger if exists guard_reservation_close_with_deposit on public.reservations;
create trigger guard_reservation_close_with_deposit before update of status on public.reservations
  for each row execute function public.guard_reservation_close_with_deposit();

revoke all on function public.record_reservation_deposit(uuid,uuid,bigint,text,text) from public,anon;
revoke all on function public.apply_guest_deposit(uuid,bigint,text) from public,anon;
revoke all on function public.refund_guest_payment(uuid,bigint,text,text) from public,anon;
grant execute on function public.record_reservation_deposit(uuid,uuid,bigint,text,text) to authenticated;
grant execute on function public.apply_guest_deposit(uuid,bigint,text) to authenticated;
grant execute on function public.refund_guest_payment(uuid,bigint,text,text) to authenticated;
