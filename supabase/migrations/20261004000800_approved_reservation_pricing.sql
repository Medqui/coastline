-- Snapshot the offered standard rate and require managerial approval for overrides.
-- Historical reservations keep null snapshots rather than inventing old approvals.
alter table public.reservation_rooms
  add column if not exists quoted_standard_rate_kobo bigint check (quoted_standard_rate_kobo >= 0),
  add column if not exists pricing_reason text,
  add column if not exists pricing_approved_by uuid references auth.users;

-- Only the validated wrapper may invoke the original booking transaction.
revoke execute on function public.create_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text) from authenticated;

-- Keep the current quoted-booking RPC when older SQL is replayed.
do $pms_pricing$ begin
  if to_regprocedure('public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text,jsonb)') is not null then
    raise notice 'Date-effective booking is already installed; preserving its current pricing rules.';
    return;
  end if;
  execute $pms_pricing_ddl$
create or replace function public.create_priced_reservation(
  p_organization_id uuid,p_property_id uuid,p_room_id uuid,
  p_guest_name text,p_guest_phone text,p_guest_email text,
  p_arrival_date date,p_departure_date date,p_adults smallint,
  p_nightly_rate_kobo bigint,p_notes text default null,p_pricing_reason text default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_standard bigint; v_override boolean; v_reservation uuid; v_reason text;
begin
  if not public.has_org_role(p_organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(p_organization_id,p_property_id) then
    raise exception 'You cannot create reservations for this property.' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_room_id::text,0));
  select rt.base_rate_kobo into v_standard from public.rooms r
    join public.room_types rt on rt.id=r.room_type_id and rt.organization_id=r.organization_id and rt.property_id=r.property_id
    where r.id=p_room_id and r.organization_id=p_organization_id and r.property_id=p_property_id and r.active and rt.active
    for share of rt;
  if not found then raise exception 'Choose an active room and room type.' using errcode='22023'; end if;
  if p_nightly_rate_kobo is null or p_nightly_rate_kobo<0 then
    raise exception 'Enter a valid nightly rate.' using errcode='22023'; end if;
  v_override:=p_nightly_rate_kobo<>v_standard or p_nightly_rate_kobo=0;
  v_reason:=nullif(btrim(p_pricing_reason),'');
  if v_override then
    if not public.has_org_role(p_organization_id,array['owner','manager']::public.member_role[]) then
      raise exception 'An owner or manager must approve discounts, complimentary stays and rate overrides.' using errcode='42501'; end if;
    if coalesce(length(v_reason),0)<5 or length(v_reason)>500 then
      raise exception 'Enter an approval reason between 5 and 500 characters.' using errcode='22023'; end if;
  end if;
  v_reservation:=public.create_reservation(p_organization_id,p_property_id,p_room_id,p_guest_name,p_guest_phone,p_guest_email,
    p_arrival_date,p_departure_date,p_adults,p_nightly_rate_kobo,p_notes);
  update public.reservation_rooms set quoted_standard_rate_kobo=v_standard,
    pricing_reason=case when v_override then v_reason end,
    pricing_approved_by=case when v_override then auth.uid() end
    where organization_id=p_organization_id and reservation_id=v_reservation;
  if v_override then
    insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
      values(p_organization_id,p_property_id,auth.uid(),'reservation_pricing_approved','reservation',v_reservation,
        jsonb_build_object('standard_rate_kobo',v_standard,'approved_rate_kobo',p_nightly_rate_kobo,
          'reason',v_reason,'complimentary',p_nightly_rate_kobo=0));
  end if;
  return v_reservation;
end $$;
revoke all on function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text) from public,anon;
grant execute on function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text) to authenticated;

$pms_pricing_ddl$;
end $pms_pricing$;
