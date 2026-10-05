-- Maintenance lifecycle remains separate from cleanliness and occupancy.
create table if not exists public.maintenance_work_orders (
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,room_id uuid not null,
  title text not null check(length(title) between 3 and 120),description text,
  priority text not null check(priority in ('low','normal','urgent')),
  status text not null default 'open' check(status in ('open','in_progress','resolved','cancelled')),
  blocks_inventory boolean not null default false,resolution_notes text,
  reported_by uuid not null references auth.users,closed_by uuid references auth.users,
  created_at timestamptz not null default now(),closed_at timestamptz,idempotency_key text not null,
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,room_id) references public.rooms(organization_id,id),
  unique(organization_id,idempotency_key),
  check((status in ('resolved','cancelled'))=(closed_at is not null and closed_by is not null))
);

create index if not exists maintenance_room_blocks on public.maintenance_work_orders(room_id) where blocks_inventory and status in ('open','in_progress');

alter table public.maintenance_work_orders enable row level security;

drop policy if exists maintenance_read on public.maintenance_work_orders;
create policy maintenance_read on public.maintenance_work_orders for select to authenticated
  using(public.can_access_property(organization_id,property_id));

grant select on public.maintenance_work_orders to authenticated;

create or replace function public.report_maintenance(p_room_id uuid,p_title text,p_description text,p_priority text,p_blocks_inventory boolean,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_room public.rooms%rowtype; v_existing public.maintenance_work_orders%rowtype; v_id uuid;
begin
  select * into v_room from public.rooms where id=p_room_id and active;
  if not found or not public.can_access_property(v_room.organization_id,v_room.property_id)
    or not public.has_org_role(v_room.organization_id,array['owner','manager','front_desk','housekeeping']::public.member_role[]) then
    raise exception 'You cannot report maintenance for this room.' using errcode='42501'; end if;
  if p_blocks_inventory is null or p_priority is null or p_priority not in ('low','normal','urgent')
    or coalesce(length(btrim(p_title)),0) not between 3 and 120 or coalesce(length(p_description),0)>2000
    or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter a title, valid priority and transaction reference.' using errcode='22023'; end if;
  if p_blocks_inventory and not public.has_org_role(v_room.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can block a room for maintenance.' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_room.organization_id::text||':maintenance:'||p_idempotency_key,0));
  select * into v_existing from public.maintenance_work_orders where organization_id=v_room.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.room_id<>p_room_id or v_existing.title<>btrim(p_title) or v_existing.description is distinct from nullif(btrim(p_description),'')
      or v_existing.priority<>p_priority or v_existing.blocks_inventory<>p_blocks_inventory then
      raise exception 'Transaction reference was already used for another issue.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_room_id::text,0));
  perform 1 from public.rooms where id=p_room_id for update;
  if p_blocks_inventory and exists(select 1 from public.reservation_rooms rr join public.reservations r
    on r.organization_id=rr.organization_id and r.id=rr.reservation_id where rr.room_id=p_room_id and r.status='checked_in') then
    raise exception 'Move or check out the in-house guest before blocking this room.' using errcode='23514'; end if;
  insert into public.maintenance_work_orders(organization_id,property_id,room_id,title,description,priority,blocks_inventory,reported_by,idempotency_key)
    values(v_room.organization_id,v_room.property_id,p_room_id,btrim(p_title),nullif(btrim(p_description),''),p_priority,p_blocks_inventory,auth.uid(),p_idempotency_key) returning id into v_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_room.organization_id,v_room.property_id,auth.uid(),'maintenance_reported','maintenance_work_order',v_id,
      jsonb_build_object('room_id',p_room_id,'title',btrim(p_title),'priority',p_priority,'blocks_inventory',p_blocks_inventory));
  return v_id;
end $$;

revoke all on function public.report_maintenance(uuid,text,text,text,boolean,text) from public,anon;

grant execute on function public.report_maintenance(uuid,text,text,text,boolean,text) to authenticated;

create or replace function public.transition_maintenance(p_work_order_id uuid,p_status text,p_notes text default null)
returns void language plpgsql security definer set search_path='' as $$
declare v public.maintenance_work_orders%rowtype; v_terminal boolean;
begin
  select * into v from public.maintenance_work_orders where id=p_work_order_id;
  if not found or not public.can_access_property(v.organization_id,v.property_id)
    or not public.has_org_role(v.organization_id,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an owner or manager can update this maintenance task.' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v.room_id::text,0));
  select * into v from public.maintenance_work_orders where id=p_work_order_id for update;
  if p_status is null or p_status not in ('in_progress','resolved','cancelled') then
    raise exception 'Choose a valid maintenance status.' using errcode='22023'; end if;
  if v.status=p_status then return; end if;
  if v.status in ('resolved','cancelled') then raise exception 'Closed maintenance tasks cannot be changed. Report a new issue.' using errcode='23514'; end if;
  v_terminal:=p_status in ('resolved','cancelled');
  if coalesce(length(p_notes),0)>2000 or (v_terminal and coalesce(length(btrim(p_notes)),0)<5) then
    raise exception 'Closing a task requires notes between 5 and 2000 characters.' using errcode='22023'; end if;
  update public.maintenance_work_orders set status=p_status,resolution_notes=nullif(btrim(p_notes),''),
    closed_by=case when v_terminal then auth.uid() end,closed_at=case when v_terminal then now() end where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'maintenance_status_changed','maintenance_work_order',v.id,
      jsonb_build_object('status',v.status),jsonb_build_object('status',p_status,'notes',nullif(btrim(p_notes),'')));
end $$;

revoke all on function public.transition_maintenance(uuid,text,text) from public,anon;

grant execute on function public.transition_maintenance(uuid,text,text) to authenticated;



-- Guards protect existing booking, check-in and room-move entry points too.
create or replace function public.guard_maintenance_allocation() returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.room_id::text,0));
  if not exists(select 1 from public.rooms r where r.id=new.room_id and r.organization_id=new.organization_id and r.property_id=new.property_id)
    or not exists(select 1 from public.reservations r where r.id=new.reservation_id and r.organization_id=new.organization_id and r.property_id=new.property_id) then
    raise exception 'Room and reservation must belong to the same property.' using errcode='23514'; end if;
  if exists(select 1 from public.maintenance_work_orders m where m.room_id=new.room_id and m.blocks_inventory and m.status in ('open','in_progress')) then
    raise exception 'This room is blocked for maintenance.' using errcode='23514'; end if;
  return new;
end $$;

drop trigger if exists maintenance_allocation_guard on public.reservation_rooms;
create trigger maintenance_allocation_guard before insert or update of room_id on public.reservation_rooms for each row execute function public.guard_maintenance_allocation();

revoke all on function public.guard_maintenance_allocation() from public,anon,authenticated;

create or replace function public.guard_maintenance_check_in() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='checked_in' and old.status<>'checked_in' and exists(
    select 1 from public.reservation_rooms rr join public.maintenance_work_orders m on m.room_id=rr.room_id
    where rr.reservation_id=new.id and m.blocks_inventory and m.status in ('open','in_progress')) then
    raise exception 'This room is blocked for maintenance. Resolve the issue or assign another room.' using errcode='23514'; end if;
  return new;
end $$;

drop trigger if exists maintenance_check_in_guard on public.reservations;
create trigger maintenance_check_in_guard before update of status on public.reservations for each row execute function public.guard_maintenance_check_in();

revoke all on function public.guard_maintenance_check_in() from public,anon,authenticated;

create or replace function public.get_available_rooms(p_property_id uuid,p_arrival date,p_departure date)
returns table(room_id uuid,room_number text,room_type text,nightly_rate_kobo bigint,housekeeping_status public.room_housekeeping_status)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) then raise exception 'You cannot view this property.' using errcode='42501'; end if;
  if p_arrival is null or p_departure is null or p_departure<=p_arrival or p_departure-p_arrival>366 then raise exception 'Choose valid dates up to one year apart.' using errcode='22023'; end if;
  return query select r.id,r.room_number,rt.name,rt.base_rate_kobo,r.housekeeping_status from public.rooms r
    join public.room_types rt on rt.organization_id=r.organization_id and rt.id=r.room_type_id and rt.property_id=r.property_id
    where r.organization_id=v_org and r.property_id=p_property_id and r.active and rt.active and r.housekeeping_status<>'out_of_order'
      and not exists(select 1 from public.maintenance_work_orders m where m.room_id=r.id and m.blocks_inventory and m.status in ('open','in_progress'))
      and not exists(select 1 from public.reservation_rooms rr join public.reservations rs
        on rs.organization_id=rr.organization_id and rs.id=rr.reservation_id
        where rr.organization_id=v_org and rr.room_id=r.id and rs.status in ('inquiry','confirmed','checked_in')
          and rr.check_in_date<p_departure and rr.check_out_date>p_arrival)
    order by r.room_number;
end $$;



-- Acquire destination advisory lock before the room row lock, as booking does.
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
  perform pg_advisory_xact_lock(hashtextextended(p_to_room_id::text,0));
  select organization_id,housekeeping_status into v_org,v_status from public.rooms where id=p_to_room_id and property_id=v_res.property_id and active for update;
  if not found or v_org<>v_res.organization_id then raise exception 'Choose a room in this property.' using errcode='22023'; end if;
  if v_status not in ('clean','inspected') then raise exception 'The destination room must be clean or inspected.' using errcode='23514'; end if;
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