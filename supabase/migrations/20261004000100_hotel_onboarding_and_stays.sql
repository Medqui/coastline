-- Safe, transactional entry points for the first hotel onboarding and stay workflows.
-- All browser writes go through these functions; each function checks auth and tenant scope.

create or replace function public.setup_hotel(
  p_organization_name text,
  p_property_name text,
  p_address text,
  p_room_count integer,
  p_standard_rate_kobo bigint
)
returns table (organization_id uuid, property_id uuid, organization_slug text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_org_id uuid;
  v_property_id uuid;
  v_room_type_id uuid;
  v_org_name text := btrim(p_organization_name);
  v_property_name text := btrim(p_property_name);
  v_slug text;
  v_room integer;
begin
  if v_user is null then raise exception 'You must sign in before setting up a hotel.' using errcode='28000'; end if;
  if v_org_name is null or length(v_org_name) < 2 or length(v_org_name) > 120 then raise exception 'Enter an organization name between 2 and 120 characters.' using errcode='22023'; end if;
  if v_property_name is null or length(v_property_name) < 2 or length(v_property_name) > 120 then raise exception 'Enter a property name between 2 and 120 characters.' using errcode='22023'; end if;
  if p_room_count is null or p_room_count < 1 or p_room_count > 300 then raise exception 'Room count must be between 1 and 300.' using errcode='22023'; end if;
  if p_standard_rate_kobo is null or p_standard_rate_kobo < 0 then raise exception 'Nightly room rate cannot be negative.' using errcode='22023'; end if;
  if exists (select 1 from public.organization_memberships m where m.user_id = v_user and m.active) then
    raise exception 'Your account already belongs to a hotel organization.' using errcode='23505';
  end if;

  v_slug := regexp_replace(lower(v_org_name), '[^a-z0-9]+', '-', 'g');
  v_slug := trim(both '-' from v_slug) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  insert into public.organizations(name,slug) values (v_org_name,v_slug) returning id into v_org_id;
  insert into public.properties(organization_id,name,address,city,currency,timezone)
    values (v_org_id,v_property_name,nullif(btrim(p_address),''),'Calabar','NGN','Africa/Lagos') returning id into v_property_id;
  insert into public.organization_memberships(organization_id,user_id,role,active,all_properties)
    values (v_org_id,v_user,'owner',true,true);
  insert into public.room_types(organization_id,property_id,name,base_rate_kobo,max_occupancy)
    values (v_org_id,v_property_id,'Standard',p_standard_rate_kobo,2) returning id into v_room_type_id;

  for v_room in 1..p_room_count loop
    insert into public.rooms(organization_id,property_id,room_type_id,room_number,floor_label,housekeeping_status)
      values (v_org_id,v_property_id,v_room_type_id,(100+v_room)::text,'Floor 1','dirty');
  end loop;

  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_org_id,v_property_id,v_user,'hotel_setup','property',v_property_id,
      jsonb_build_object('organization_name',v_org_name,'property_name',v_property_name,'room_count',p_room_count));
  return query select v_org_id,v_property_id,v_slug;
end;
$$;

create or replace function public.create_reservation(
  p_organization_id uuid,
  p_property_id uuid,
  p_room_id uuid,
  p_guest_name text,
  p_guest_phone text,
  p_guest_email text,
  p_arrival_date date,
  p_departure_date date,
  p_adults smallint,
  p_nightly_rate_kobo bigint,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_guest_id uuid;
  v_reservation_id uuid;
  v_room_status public.room_housekeeping_status;
begin
  if v_user is null then raise exception 'Sign in before creating a reservation.' using errcode='28000'; end if;
  if not public.has_org_role(p_organization_id,array['owner','manager','front_desk']::public.member_role[]) then
    raise exception 'You do not have permission to create reservations for this hotel.' using errcode='42501';
  end if;
  if not public.can_access_property(p_organization_id,p_property_id) then raise exception 'You do not have access to this property.' using errcode='42501'; end if;
  if p_room_id is null or p_arrival_date is null or p_departure_date is null or p_departure_date <= p_arrival_date then
    raise exception 'Choose a room and valid arrival and departure dates.' using errcode='22023';
  end if;
  if length(btrim(coalesce(p_guest_name,''))) < 2 then raise exception 'Enter the guest name.' using errcode='22023'; end if;
  if p_adults is null or p_adults < 1 or p_adults > 12 then raise exception 'Adult count must be between 1 and 12.' using errcode='22023'; end if;
  if p_nightly_rate_kobo is null or p_nightly_rate_kobo < 0 then raise exception 'Nightly rate cannot be negative.' using errcode='22023'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_room_id::text,0));
  select r.housekeeping_status into v_room_status from public.rooms r
    where r.id=p_room_id and r.organization_id=p_organization_id and r.property_id=p_property_id and r.active for update;
  if not found then raise exception 'That room is no longer available.' using errcode='P0002'; end if;
  if v_room_status='out_of_order' then raise exception 'That room is out of order.' using errcode='23514'; end if;
  if exists (
    select 1 from public.reservation_rooms rr join public.reservations r
      on r.organization_id=rr.organization_id and r.id=rr.reservation_id
    where rr.organization_id=p_organization_id and rr.room_id=p_room_id
      and rr.check_in_date < p_departure_date and rr.check_out_date > p_arrival_date
      and r.status in ('inquiry','confirmed','checked_in')
  ) then raise exception 'That room is already reserved for part of those dates.' using errcode='23P01'; end if;

  insert into public.guests(organization_id,full_name,phone,email)
    values(p_organization_id,btrim(p_guest_name),nullif(btrim(p_guest_phone),''),nullif(lower(btrim(p_guest_email)),''))
    returning id into v_guest_id;
  insert into public.reservations(organization_id,property_id,guest_id,status,source,arrival_date,departure_date,adults,notes,created_by)
    values(p_organization_id,p_property_id,v_guest_id,'confirmed','direct',p_arrival_date,p_departure_date,p_adults,nullif(btrim(p_notes),''),v_user)
    returning id into v_reservation_id;
  insert into public.reservation_rooms(organization_id,property_id,reservation_id,room_id,nightly_rate_kobo,check_in_date,check_out_date)
    values(p_organization_id,p_property_id,v_reservation_id,p_room_id,p_nightly_rate_kobo,p_arrival_date,p_departure_date);
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(p_organization_id,p_property_id,v_user,'reservation_created','reservation',v_reservation_id,
      jsonb_build_object('guest_id',v_guest_id,'room_id',p_room_id,'arrival_date',p_arrival_date,'departure_date',p_departure_date,'nightly_rate_kobo',p_nightly_rate_kobo));
  return v_reservation_id;
end;
$$;

create or replace function public.check_in_reservation(p_reservation_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_reservation public.reservations%rowtype;
  v_room_id uuid;
  v_room_status public.room_housekeeping_status;
  v_folio_id uuid;
  v_today date;
begin
  if v_user is null then raise exception 'Sign in before checking in a guest.' using errcode='28000'; end if;
  select r.* into v_reservation from public.reservations r where r.id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_reservation.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_reservation.organization_id,v_reservation.property_id) then
    raise exception 'You do not have permission to check in this reservation.' using errcode='42501';
  end if;
  if v_reservation.status='checked_in' then
    select f.id into v_folio_id from public.folios f where f.organization_id=v_reservation.organization_id and f.reservation_id=p_reservation_id;
    return v_folio_id;
  end if;
  if v_reservation.status<>'confirmed' then raise exception 'Only confirmed reservations can be checked in.' using errcode='23514'; end if;
  select (now() at time zone p.timezone)::date into v_today from public.properties p where p.id=v_reservation.property_id;
  if v_today < v_reservation.arrival_date or v_today >= v_reservation.departure_date then
    raise exception 'Check-in is available on the arrival date and before the departure date.' using errcode='22023';
  end if;
  select rr.room_id into v_room_id from public.reservation_rooms rr
    where rr.organization_id=v_reservation.organization_id and rr.reservation_id=p_reservation_id limit 1;
  if v_room_id is null then raise exception 'Assign a room before checking in.' using errcode='23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_room_id::text,0));
  select r.housekeeping_status into v_room_status from public.rooms r where r.id=v_room_id for update;
  if v_room_status not in ('clean','inspected') then raise exception 'Room is not ready. Housekeeping must mark it clean first.' using errcode='23514'; end if;
  if exists (
    select 1 from public.reservation_rooms rr join public.reservations r
      on r.organization_id=rr.organization_id and r.id=rr.reservation_id
    where rr.room_id=v_room_id and rr.reservation_id<>p_reservation_id
      and rr.check_in_date <= v_today and rr.check_out_date > v_today and r.status='checked_in'
  ) then raise exception 'This room is currently occupied by another stay.' using errcode='23P01'; end if;
  update public.reservations set status='checked_in' where id=p_reservation_id;
  insert into public.folios(organization_id,property_id,reservation_id,status)
    values(v_reservation.organization_id,v_reservation.property_id,p_reservation_id,'open') returning id into v_folio_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_reservation.organization_id,v_reservation.property_id,v_user,'guest_checked_in','reservation',p_reservation_id,jsonb_build_object('folio_id',v_folio_id));
  return v_folio_id;
end;
$$;

revoke all on function public.setup_hotel(text,text,text,integer,bigint) from public, anon;
revoke all on function public.create_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text) from public, anon;
revoke all on function public.check_in_reservation(uuid) from public, anon;
grant execute on function public.setup_hotel(text,text,text,integer,bigint) to authenticated;
grant execute on function public.create_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text) to authenticated;
grant execute on function public.check_in_reservation(uuid) to authenticated;

create or replace function public.update_room_housekeeping_status(p_room_id uuid,p_status public.room_housekeeping_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_org_id uuid;
  v_property_id uuid;
  v_old_status public.room_housekeeping_status;
begin
  if v_user is null then raise exception 'Sign in before updating a room.' using errcode='28000'; end if;
  select r.organization_id,r.property_id,r.housekeeping_status into v_org_id,v_property_id,v_old_status
    from public.rooms r where r.id=p_room_id for update;
  if not found then raise exception 'Room not found.' using errcode='P0002'; end if;
  if not public.can_access_property(v_org_id,v_property_id) then raise exception 'You do not have access to this property.' using errcode='42501'; end if;
  if p_status='out_of_order' then
    if not public.has_org_role(v_org_id,array['owner','manager']::public.member_role[]) then
      raise exception 'Only a hotel owner or manager can take a room out of order.' using errcode='42501';
    end if;
  elsif not public.has_org_role(v_org_id,array['owner','manager','front_desk','housekeeping']::public.member_role[]) then
    raise exception 'You do not have permission to update housekeeping status.' using errcode='42501';
  end if;
  update public.rooms set housekeeping_status=p_status where id=p_room_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v_org_id,v_property_id,v_user,'room_status_changed','room',p_room_id,
      jsonb_build_object('housekeeping_status',v_old_status),jsonb_build_object('housekeeping_status',p_status));
end;
$$;

revoke all on function public.update_room_housekeeping_status(uuid,public.room_housekeeping_status) from public, anon;
grant execute on function public.update_room_housekeeping_status(uuid,public.room_housekeeping_status) to authenticated;

grant select on public.organizations,public.organization_memberships,public.properties,public.membership_properties,
  public.room_types,public.rooms,public.guests,public.reservations,public.reservation_rooms,public.folios,
  public.folio_items,public.payment_methods,public.payments,public.accounts,public.journals,public.journal_lines,
  public.expenses,public.audit_events to authenticated;
