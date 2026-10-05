-- Date-effective standard rates and immutable nightly booking prices.
create table if not exists public.room_rate_periods (
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,room_type_id uuid not null,
  name text not null check(length(name) between 2 and 120),starts_on date not null,ends_before date not null,
  nightly_rate_kobo bigint not null check(nightly_rate_kobo>=0),active boolean not null default true,
  created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,room_type_id) references public.room_types(organization_id,id),
  check(ends_before>starts_on and ends_before-starts_on<=366)
);

create index if not exists room_rate_period_lookup on public.room_rate_periods(room_type_id,starts_on,ends_before) where active;

alter table public.room_rate_periods enable row level security;

drop policy if exists room_rate_period_read on public.room_rate_periods;
create policy room_rate_period_read on public.room_rate_periods for select to authenticated using(public.can_access_property(organization_id,property_id));

grant select on public.room_rate_periods to authenticated;

create or replace function public.set_room_base_rate(p_room_type_id uuid,p_rate_kobo bigint,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare v public.room_types%rowtype;
begin
  select * into v from public.room_types where id=p_room_type_id for update;
  if not found or not public.can_access_property(v.organization_id,v.property_id)
    or not public.has_org_role(v.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can manage room rates.' using errcode='42501'; end if;
  if p_rate_kobo is null or p_rate_kobo<0 or coalesce(length(btrim(p_reason)),0) not between 5 and 500 then
    raise exception 'Enter a nonnegative rate and a reason between 5 and 500 characters.' using errcode='22023'; end if;
  if v.base_rate_kobo=p_rate_kobo then return; end if;
  update public.room_types set base_rate_kobo=p_rate_kobo where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'room_base_rate_changed','room_type',v.id,
      jsonb_build_object('rate_kobo',v.base_rate_kobo),jsonb_build_object('rate_kobo',p_rate_kobo,'reason',btrim(p_reason)));
end $$;

revoke all on function public.set_room_base_rate(uuid,bigint,text) from public,anon;

grant execute on function public.set_room_base_rate(uuid,bigint,text) to authenticated;

create or replace function public.schedule_room_rate(p_room_type_id uuid,p_name text,p_starts_on date,p_ends_before date,p_rate_kobo bigint)
returns uuid language plpgsql security definer set search_path='' as $$
declare v public.room_types%rowtype; v_id uuid;
begin
  -- The room-type row serializes rate writes with each other and with booking snapshots.
  select * into v from public.room_types where id=p_room_type_id and active for update;
  if not found or not public.can_access_property(v.organization_id,v.property_id)
    or not public.has_org_role(v.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can schedule room rates.' using errcode='42501'; end if;
  if coalesce(length(btrim(p_name)),0) not between 2 and 120 or p_starts_on is null or p_ends_before is null
    or p_ends_before<=p_starts_on or p_ends_before-p_starts_on>366 or p_rate_kobo is null or p_rate_kobo<0 then
    raise exception 'Enter a name, nonnegative rate and date range of up to one year.' using errcode='22023'; end if;
  if exists(select 1 from public.room_rate_periods p where p.room_type_id=v.id and p.active
    and p.starts_on<p_ends_before and p.ends_before>p_starts_on) then
    raise exception 'This room type already has a scheduled rate during part of those dates.' using errcode='23P01'; end if;
  insert into public.room_rate_periods(organization_id,property_id,room_type_id,name,starts_on,ends_before,nightly_rate_kobo,created_by)
    values(v.organization_id,v.property_id,v.id,btrim(p_name),p_starts_on,p_ends_before,p_rate_kobo,auth.uid()) returning id into v_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'room_rate_scheduled','room_rate_period',v_id,
      jsonb_build_object('room_type_id',v.id,'name',btrim(p_name),'starts_on',p_starts_on,'ends_before',p_ends_before,'rate_kobo',p_rate_kobo));
  return v_id;
end $$;

revoke all on function public.schedule_room_rate(uuid,text,date,date,bigint) from public,anon;

grant execute on function public.schedule_room_rate(uuid,text,date,date,bigint) to authenticated;

create or replace function public.retire_room_rate(p_period_id uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare v public.room_rate_periods%rowtype;
begin
  select * into v from public.room_rate_periods where id=p_period_id;
  if not found or not public.can_access_property(v.organization_id,v.property_id)
    or not public.has_org_role(v.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can retire a scheduled rate.' using errcode='42501'; end if;
  if coalesce(length(btrim(p_reason)),0) not between 5 and 500 then raise exception 'Enter a reason between 5 and 500 characters.' using errcode='22023'; end if;
  perform 1 from public.room_types where id=v.room_type_id for update;
  select * into v from public.room_rate_periods where id=p_period_id for update;
  if not v.active then return; end if;
  update public.room_rate_periods set active=false where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'room_rate_retired','room_rate_period',v.id,jsonb_build_object('reason',btrim(p_reason)));
end $$;

revoke all on function public.retire_room_rate(uuid,text) from public,anon;

grant execute on function public.retire_room_rate(uuid,text) to authenticated;

create or replace function public.get_room_rate_quote(p_room_id uuid,p_arrival date,p_departure date)
returns table(service_date date,standard_rate_kobo bigint,rate_name text)
language plpgsql stable security definer set search_path='' as $$
declare v_room public.rooms%rowtype; v_type public.room_types%rowtype;
begin
  select * into v_room from public.rooms where id=p_room_id and active;
  if not found or not public.can_access_property(v_room.organization_id,v_room.property_id) then
    raise exception 'You cannot view rates for this room.' using errcode='42501'; end if;
  select * into v_type from public.room_types where id=v_room.room_type_id and organization_id=v_room.organization_id and property_id=v_room.property_id and active;
  if not found then raise exception 'The room type is unavailable.' using errcode='23514'; end if;
  if p_arrival is null or p_departure is null or p_departure<=p_arrival or p_departure-p_arrival>366 then
    raise exception 'Choose a stay of one to 366 nights.' using errcode='22023'; end if;
  return query select d.night::date,coalesce(p.nightly_rate_kobo,v_type.base_rate_kobo),coalesce(p.name,'Base rate')
    from generate_series(p_arrival::timestamp,(p_departure-1)::timestamp,'1 day') d(night)
    left join public.room_rate_periods p on p.room_type_id=v_type.id and p.active and d.night::date>=p.starts_on and d.night::date<p.ends_before
    order by d.night;
end $$;

revoke all on function public.get_room_rate_quote(uuid,date,date) from public,anon;

grant execute on function public.get_room_rate_quote(uuid,date,date) to authenticated;

create table if not exists public.reservation_night_rates (
  organization_id uuid not null,property_id uuid not null,reservation_id uuid not null,service_date date not null,
  standard_rate_kobo bigint not null check(standard_rate_kobo>=0),charged_rate_kobo bigint not null check(charged_rate_kobo>=0),rate_name text not null,
  primary key(organization_id,reservation_id,service_date),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,reservation_id) references public.reservations(organization_id,id)
);

alter table public.reservation_night_rates enable row level security;

drop policy if exists reservation_night_rate_read on public.reservation_night_rates;
create policy reservation_night_rate_read on public.reservation_night_rates for select to authenticated using(public.can_access_property(organization_id,property_id));

grant select on public.reservation_night_rates to authenticated;



-- Preserve historical agreed amounts; do not reprice old bookings using new schedules.
insert into public.reservation_night_rates(organization_id,property_id,reservation_id,service_date,standard_rate_kobo,charged_rate_kobo,rate_name)
  select rr.organization_id,rr.property_id,rr.reservation_id,d.night::date,coalesce(rr.quoted_standard_rate_kobo,rr.nightly_rate_kobo),rr.nightly_rate_kobo,'Historical agreed rate'
  from public.reservation_rooms rr, lateral generate_series(rr.check_in_date::timestamp,(rr.check_out_date-1)::timestamp,'1 day') d(night)
  on conflict do nothing;

create or replace function public.guard_nightly_rate_snapshot() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Agreed nightly rates cannot be edited or deleted.' using errcode='23514'; end $$;

drop trigger if exists nightly_rate_snapshot_immutable on public.reservation_night_rates;
create trigger nightly_rate_snapshot_immutable before update or delete on public.reservation_night_rates for each row execute function public.guard_nightly_rate_snapshot();

revoke all on function public.guard_nightly_rate_snapshot() from public,anon,authenticated;

do $pms_legacy_pricing$ begin
  if to_regprocedure('public.create_priced_reservation_legacy(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text)') is null then
    alter function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text) rename to create_priced_reservation_legacy;
  else
    drop function if exists public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text);
  end if;
end $pms_legacy_pricing$;

revoke all on function public.create_priced_reservation_legacy(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text) from public,anon,authenticated;

create or replace function public.create_priced_reservation(
  p_organization_id uuid,p_property_id uuid,p_room_id uuid,p_guest_name text,p_guest_phone text,p_guest_email text,
  p_arrival_date date,p_departure_date date,p_adults smallint,p_nightly_rate_kobo bigint,
  p_notes text default null,p_pricing_reason text default null,p_expected_quote jsonb default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_type uuid; v_quote jsonb; v_expected jsonb; v_override boolean; v_complimentary boolean; v_reservation uuid; v_reason text; v_first bigint;
begin
  if not public.has_org_role(p_organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(p_organization_id,p_property_id) then
    raise exception 'You cannot create reservations for this property.' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_room_id::text,0));
  select rt.id into v_type from public.rooms r join public.room_types rt
    on rt.id=r.room_type_id and rt.organization_id=r.organization_id and rt.property_id=r.property_id
    where r.id=p_room_id and r.organization_id=p_organization_id and r.property_id=p_property_id and r.active and rt.active for share of rt;
  if not found then raise exception 'Choose an active room and room type.' using errcode='22023'; end if;
  if p_nightly_rate_kobo<0 then raise exception 'Enter a nonnegative approved rate.' using errcode='22023'; end if;
  select jsonb_agg(jsonb_build_object('service_date',q.service_date,'standard_rate_kobo',q.standard_rate_kobo,'rate_name',q.rate_name) order by q.service_date),
    jsonb_agg(jsonb_build_object('service_date',q.service_date,'standard_rate_kobo',q.standard_rate_kobo) order by q.service_date)
    into v_quote,v_expected from public.get_room_rate_quote(p_room_id,p_arrival_date,p_departure_date) q;
  if p_expected_quote is not null and p_expected_quote<>v_expected then
    raise exception 'Room rates changed. Review the updated nightly quote before confirming.' using errcode='23514'; end if;
  select exists(select 1 from jsonb_to_recordset(v_quote) q(standard_rate_kobo bigint)
    where coalesce(p_nightly_rate_kobo,q.standard_rate_kobo)=0 or (p_nightly_rate_kobo is not null and p_nightly_rate_kobo<>q.standard_rate_kobo)) into v_override;
  select bool_and(coalesce(p_nightly_rate_kobo,q.standard_rate_kobo)=0) into v_complimentary
    from jsonb_to_recordset(v_quote) q(standard_rate_kobo bigint);
  v_reason:=nullif(btrim(p_pricing_reason),'');
  if v_override then
    if not public.has_org_role(p_organization_id,array['owner','manager']::public.member_role[]) then
      raise exception 'An owner or manager must approve discounts, complimentary stays and rate overrides.' using errcode='42501'; end if;
    if coalesce(length(v_reason),0) not between 5 and 500 then raise exception 'Enter an approval reason between 5 and 500 characters.' using errcode='22023'; end if;
  end if;
  v_first:=(v_quote->0->>'standard_rate_kobo')::bigint;
  v_reservation:=public.create_reservation(p_organization_id,p_property_id,p_room_id,p_guest_name,p_guest_phone,p_guest_email,p_arrival_date,p_departure_date,p_adults,coalesce(p_nightly_rate_kobo,v_first),p_notes);
  insert into public.reservation_night_rates(organization_id,property_id,reservation_id,service_date,standard_rate_kobo,charged_rate_kobo,rate_name)
    select p_organization_id,p_property_id,v_reservation,q.service_date,q.standard_rate_kobo,coalesce(p_nightly_rate_kobo,q.standard_rate_kobo),q.rate_name
    from jsonb_to_recordset(v_quote) q(service_date date,standard_rate_kobo bigint,rate_name text);
  update public.reservation_rooms set quoted_standard_rate_kobo=v_first,pricing_reason=case when v_override then v_reason end,
    pricing_approved_by=case when v_override then auth.uid() end where organization_id=p_organization_id and reservation_id=v_reservation;
  if v_override then
    insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
      values(p_organization_id,p_property_id,auth.uid(),'reservation_pricing_approved','reservation',v_reservation,
        jsonb_build_object('standard_rate_kobo',v_first,'approved_rate_kobo',p_nightly_rate_kobo,'reason',v_reason,'complimentary',v_complimentary,'nightly_quote',v_quote));
  end if;
  return v_reservation;
end $$;

revoke all on function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text,jsonb) from public,anon;

grant execute on function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text,jsonb) to authenticated;

create or replace function public.post_due_room_nights(p_reservation_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_folio public.folios%rowtype; v_today date; v_night date;
  v_rate bigint; v_room text; v_key text; v_journal uuid; v_count integer:=0;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk','accountant']::public.member_role[])
    or not public.can_access_property(v_res.organization_id,v_res.property_id) then raise exception 'You cannot post this reservation.' using errcode='42501'; end if;
  if v_res.status<>'checked_in' then raise exception 'Room nights can post only for an in-house stay.' using errcode='23514'; end if;
  select * into v_folio from public.folios where organization_id=v_res.organization_id and reservation_id=v_res.id for update;
  if not found or v_folio.status<>'open' then raise exception 'An open folio is required.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  select r.room_number into v_room from public.reservation_rooms rr join public.rooms r on r.id=rr.room_id
    where rr.organization_id=v_res.organization_id and rr.reservation_id=v_res.id limit 1;
  if v_room is null then raise exception 'No room assigned to this stay.' using errcode='23514'; end if;
  for v_night in select generate_series(v_res.arrival_date::timestamp,least(v_today-1,v_res.departure_date-1)::timestamp,'1 day')::date loop
    select n.charged_rate_kobo into v_rate from public.reservation_night_rates n
      where n.organization_id=v_res.organization_id and n.reservation_id=v_res.id and n.service_date=v_night;
    if not found then raise exception 'The agreed nightly rate is missing. Ask your manager to review this stay.' using errcode='23514'; end if;
    v_key:='room:'||v_res.id::text||':'||v_night::text;
    if v_rate>0 and not exists(select 1 from public.folio_items where organization_id=v_res.organization_id and source_key=v_key) then
      v_journal:=public.post_accounting_event(v_res.organization_id,v_res.property_id,'room_night',v_res.id,v_night,'Room '||v_room||' · '||v_night,v_rate,'1100','4000',v_key);
      insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
        values(v_res.organization_id,v_res.property_id,v_folio.id,'room_charge','Room '||v_room||' · '||v_night,v_night,v_rate,v_rate,auth.uid(),v_key,v_journal);
      v_count:=v_count+1;
    end if;
  end loop;
  return v_count;
end $$;