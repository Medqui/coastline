-- Multi-property administration, scoped staff invitations, date availability,
-- in-house room moves, and early checkout. Apply after migration 005.
alter table public.reservations add column if not exists actual_departure_date date;

create table if not exists public.team_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations on delete cascade,
  property_id uuid not null,
  email text not null,
  role public.member_role not null check (role in ('manager','front_desk','accountant','housekeeping')),
  token_hash text not null unique,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_by uuid not null references auth.users,
  created_at timestamptz not null default now(),
  foreign key (organization_id,property_id) references public.properties (organization_id,id) on delete cascade,
  unique (organization_id,email,property_id,accepted_at)
);

create table if not exists public.room_move_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  reservation_id uuid not null,
  from_room_id uuid not null,
  to_room_id uuid not null,
  moved_at timestamptz not null default now(),
  moved_by uuid references auth.users,
  reason text,
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,reservation_id) references public.reservations (organization_id,id),
  foreign key (organization_id,from_room_id) references public.rooms (organization_id,id),
  foreign key (organization_id,to_room_id) references public.rooms (organization_id,id)
);

alter table public.team_invitations enable row level security;

drop policy if exists team_invitations_owner_read on public.team_invitations;

drop policy if exists team_invitations_owner_read on public.team_invitations;
create policy team_invitations_owner_read on public.team_invitations for select to authenticated
  using (public.has_org_role(organization_id,array['owner']::public.member_role[])
    and public.can_access_property(organization_id,property_id));

alter table public.room_move_events enable row level security;

drop policy if exists room_moves_staff_read on public.room_move_events;

drop policy if exists room_moves_staff_read on public.room_move_events;
create policy room_moves_staff_read on public.room_move_events for select to authenticated
  using (public.can_access_property(organization_id,property_id)
    and public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));

create or replace function public.create_property(
  p_organization_id uuid,p_name text,p_address text,p_room_count integer,p_standard_rate_kobo bigint
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_property uuid; v_type uuid; i integer;
begin
  if not public.has_org_role(p_organization_id,array['owner','manager']::public.member_role[]) or not exists(select 1 from public.organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active and all_properties) then
    raise exception 'Only an owner or hotel-wide manager can add a property.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_name,'')))<2 or length(btrim(p_name))>120 then raise exception 'Enter a property name between 2 and 120 characters.' using errcode='22023'; end if;
  if p_room_count is null or p_room_count<1 or p_room_count>300 or p_standard_rate_kobo is null or p_standard_rate_kobo<0 then
    raise exception 'Enter a valid room count and nightly rate.' using errcode='22023'; end if;
  insert into public.properties(organization_id,name,address,city,currency,timezone)
    values(p_organization_id,btrim(p_name),nullif(btrim(p_address),''),'Calabar','NGN','Africa/Lagos') returning id into v_property;
  insert into public.room_types(organization_id,property_id,name,base_rate_kobo,max_occupancy)
    values(p_organization_id,v_property,'Standard',p_standard_rate_kobo,2) returning id into v_type;
  for i in 1..p_room_count loop
    insert into public.rooms(organization_id,property_id,room_type_id,room_number,floor_label,housekeeping_status)
      values(p_organization_id,v_property,v_type,(100+i)::text,'Floor 1','dirty');
  end loop;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(p_organization_id,v_property,auth.uid(),'property_created','property',v_property,
      jsonb_build_object('name',btrim(p_name),'room_count',p_room_count));
  return v_property;
end $$;

revoke all on function public.create_property(uuid,text,text,integer,bigint) from public,anon;

grant execute on function public.create_property(uuid,text,text,integer,bigint) to authenticated;

create or replace function public.create_team_invitation(
  p_organization_id uuid,p_property_id uuid,p_email text,p_role public.member_role
) returns text language plpgsql security definer set search_path='' as $$
declare v_token text:=encode(public.gen_random_bytes(32),'hex'); v_email text:=lower(btrim(coalesce(p_email,'')));
begin
  if not public.has_org_role(p_organization_id,array['owner']::public.member_role[])
    or not public.can_access_property(p_organization_id,p_property_id) then
    raise exception 'Only an owner with access to this property can invite staff.' using errcode='42501'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email address.' using errcode='22023'; end if;
  if p_role not in ('manager','front_desk','accountant','housekeeping') then raise exception 'Choose a staff role.' using errcode='22023'; end if;
  if exists(select 1 from public.organization_memberships m join auth.users u on u.id=m.user_id
    where m.organization_id=p_organization_id and m.active and lower(u.email)=v_email) then
    raise exception 'This person is already a member of this hotel.' using errcode='23505'; end if;
  insert into public.team_invitations(organization_id,property_id,email,role,token_hash,expires_at,created_by)
    values(p_organization_id,p_property_id,v_email,p_role,encode(public.digest(v_token,'sha256'),'hex'),now()+interval '7 days',auth.uid());
  return v_token;
end $$;

revoke all on function public.create_team_invitation(uuid,uuid,text,public.member_role) from public,anon;

grant execute on function public.create_team_invitation(uuid,uuid,text,public.member_role) to authenticated;

create or replace function public.accept_team_invitation(p_token text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_inv public.team_invitations%rowtype; v_email text:=lower(coalesce(auth.jwt()->>'email',''));
begin
  if auth.uid() is null or length(coalesce(p_token,''))<>64 or v_email='' then raise exception 'Sign in with the invited email address.' using errcode='28000'; end if;
  select * into v_inv from public.team_invitations where token_hash=encode(public.digest(p_token,'sha256'),'hex') for update;
  if not found or v_inv.accepted_at is not null or v_inv.expires_at<=now() then raise exception 'Invitation is invalid or expired.' using errcode='22023'; end if;
  if v_email<>v_inv.email then raise exception 'Sign in with the email address that received this invitation.' using errcode='42501'; end if;
  insert into public.organization_memberships(organization_id,user_id,role,active,all_properties)
    values(v_inv.organization_id,auth.uid(),v_inv.role,true,false)
    on conflict(organization_id,user_id) do update set role=excluded.role,active=true,all_properties=false;
  delete from public.membership_properties where organization_id=v_inv.organization_id and user_id=auth.uid();
  insert into public.membership_properties(organization_id,user_id,property_id)
    values(v_inv.organization_id,auth.uid(),v_inv.property_id) on conflict do nothing;
  update public.team_invitations set accepted_at=now() where id=v_inv.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,after_data)
    values(v_inv.organization_id,v_inv.property_id,auth.uid(),'team_invitation_accepted','membership',
      jsonb_build_object('email',v_inv.email,'role',v_inv.role));
  return v_inv.organization_id;
end $$;

revoke all on function public.accept_team_invitation(text) from public,anon;

grant execute on function public.accept_team_invitation(text) to authenticated;

create or replace function public.change_member_role(p_organization_id uuid,p_user_id uuid,p_role public.member_role)
returns void language plpgsql security definer set search_path='' as $$
declare v_before public.member_role;
begin
  if not public.has_org_role(p_organization_id,array['owner']::public.member_role[]) then raise exception 'Only an owner can change staff roles.' using errcode='42501'; end if;
  if p_role not in ('manager','front_desk','accountant','housekeeping') then raise exception 'Choose a staff role.' using errcode='22023'; end if;
  select role into v_before from public.organization_memberships where organization_id=p_organization_id and user_id=p_user_id and active for update;
  if not found or v_before='owner' then raise exception 'That staff member cannot be changed here.' using errcode='23514'; end if;
  update public.organization_memberships set role=p_role where organization_id=p_organization_id and user_id=p_user_id;
  insert into public.audit_events(organization_id,actor_user_id,action,entity_type,after_data)
    values(p_organization_id,auth.uid(),'team_role_changed','membership',jsonb_build_object('user_id',p_user_id,'from',v_before,'to',p_role));
end $$;

revoke all on function public.change_member_role(uuid,uuid,public.member_role) from public,anon;

grant execute on function public.change_member_role(uuid,uuid,public.member_role) to authenticated;

create or replace function public.get_available_rooms(p_property_id uuid,p_arrival date,p_departure date)
returns table(room_id uuid,room_number text,room_type text,nightly_rate_kobo bigint,housekeeping_status public.room_housekeeping_status)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) then raise exception 'You cannot view this property.' using errcode='42501'; end if;
  if p_arrival is null or p_departure is null or p_departure<=p_arrival or p_departure-p_arrival>366 then raise exception 'Choose valid dates up to one year apart.' using errcode='22023'; end if;
  return query select r.id,r.room_number,rt.name,rt.base_rate_kobo,r.housekeeping_status from public.rooms r
    join public.room_types rt on rt.organization_id=r.organization_id and rt.id=r.room_type_id
    where r.organization_id=v_org and r.property_id=p_property_id and r.active and r.housekeeping_status<>'out_of_order'
      and not exists(select 1 from public.reservation_rooms rr join public.reservations rs
        on rs.organization_id=rr.organization_id and rs.id=rr.reservation_id
        where rr.organization_id=v_org and rr.room_id=r.id and rs.status in ('inquiry','confirmed','checked_in')
          and rr.check_in_date<p_departure and rr.check_out_date>p_arrival)
    order by r.room_number;
end $$;

revoke all on function public.get_available_rooms(uuid,date,date) from public,anon;

grant execute on function public.get_available_rooms(uuid,date,date) to authenticated;

create or replace function public.move_checked_in_reservation(p_reservation_id uuid,p_to_room_id uuid,p_reason text default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_from uuid; v_today date; v_status public.room_housekeeping_status; v_org uuid;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk']::public.member_role[]) or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot move this reservation.' using errcode='42501'; end if;
  if v_res.status<>'checked_in' then raise exception 'Only an in-house guest can be moved.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  select room_id into v_from from public.reservation_rooms where organization_id=v_res.organization_id and reservation_id=v_res.id limit 1 for update;
  if v_from is null or v_from=p_to_room_id then raise exception 'Choose a different room.' using errcode='22023'; end if;
  select organization_id,housekeeping_status into v_org,v_status from public.rooms where id=p_to_room_id and property_id=v_res.property_id and active for update;
  if not found or v_org<>v_res.organization_id then raise exception 'Choose a room in this property.' using errcode='22023'; end if;
  if v_status not in ('clean','inspected') then raise exception 'The destination room must be clean or inspected.' using errcode='23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_to_room_id::text,0));
  if exists(select 1 from public.reservation_rooms rr join public.reservations rs on rs.organization_id=rr.organization_id and rs.id=rr.reservation_id
    where rr.organization_id=v_res.organization_id and rr.room_id=p_to_room_id and rs.id<>v_res.id
      and rs.status in ('inquiry','confirmed','checked_in') and rr.check_in_date< v_res.departure_date and rr.check_out_date>v_today) then
    raise exception 'That room is already assigned during the remaining stay.' using errcode='23P01'; end if;
  insert into public.room_move_events(organization_id,property_id,reservation_id,from_room_id,to_room_id,moved_by,reason)
    values(v_res.organization_id,v_res.property_id,v_res.id,v_from,p_to_room_id,auth.uid(),nullif(btrim(p_reason),''));
  update public.reservation_rooms set room_id=p_to_room_id where organization_id=v_res.organization_id and reservation_id=v_res.id and room_id=v_from;
  update public.rooms set housekeeping_status='dirty' where id=v_from;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v_res.organization_id,v_res.property_id,auth.uid(),'room_moved','reservation',v_res.id,
      jsonb_build_object('room_id',v_from),jsonb_build_object('room_id',p_to_room_id,'reason',nullif(btrim(p_reason),'')));
end $$;

revoke all on function public.move_checked_in_reservation(uuid,uuid,text) from public,anon;

grant execute on function public.move_checked_in_reservation(uuid,uuid,text) to authenticated;

create or replace function public.early_check_out_reservation(p_reservation_id uuid,p_actual_departure_date date default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_folio public.folios%rowtype; v_today date; v_date date; v_balance bigint;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk']::public.member_role[]) or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot check out this reservation.' using errcode='42501'; end if;
  if v_res.status<>'checked_in' then raise exception 'Only in-house guests can check out.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  v_date:=coalesce(p_actual_departure_date,v_today);
  if v_date<>v_today or v_date<v_res.arrival_date or v_date>=v_res.departure_date then raise exception 'Choose today as the early checkout date.' using errcode='22023'; end if;
  perform public.post_due_room_nights(p_reservation_id);
  select * into v_folio from public.folios where organization_id=v_res.organization_id and reservation_id=v_res.id for update;
  select coalesce(sum(total_amount_kobo),0) into v_balance from public.folio_items where organization_id=v_res.organization_id and folio_id=v_folio.id;
  if v_balance<>0 then raise exception 'Settle the folio balance before checkout.' using errcode='23514'; end if;
  update public.folios set status='closed',closed_at=now() where id=v_folio.id;
  update public.reservations set status='checked_out',actual_departure_date=v_date where id=v_res.id;
  update public.rooms set housekeeping_status='dirty' where id in (select room_id from public.reservation_rooms where organization_id=v_res.organization_id and reservation_id=v_res.id);
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v_res.organization_id,v_res.property_id,auth.uid(),'early_checkout','reservation',v_res.id,
      jsonb_build_object('planned_departure_date',v_res.departure_date),jsonb_build_object('actual_departure_date',v_date));
end $$;

revoke all on function public.early_check_out_reservation(uuid,date) from public,anon;

grant execute on function public.early_check_out_reservation(uuid,date) to authenticated;

create or replace function public.get_team_members(p_organization_id uuid)
returns table(user_id uuid,email text,role public.member_role,active boolean,all_properties boolean)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.has_org_role(p_organization_id,array['owner']::public.member_role[]) then raise exception 'Only an owner can view team access.' using errcode='42501'; end if;
  return query select m.user_id,u.email::text,m.role,m.active,m.all_properties from public.organization_memberships m join auth.users u on u.id=m.user_id where m.organization_id=p_organization_id order by m.created_at;
end $$;

revoke all on function public.get_team_members(uuid) from public,anon;

grant execute on function public.get_team_members(uuid) to authenticated;

grant select on public.team_invitations,public.room_move_events to authenticated;