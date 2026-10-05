-- MVP configuration and quantity inventory. Existing booking prices/journals stay unchanged.
create table if not exists public.property_floors (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null, property_id uuid not null,
  name text not null check(length(btrim(name)) between 1 and 120),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  unique(property_id,name)
);
insert into public.property_floors(organization_id,property_id,name)
select distinct organization_id,property_id,floor_label from public.rooms where nullif(btrim(floor_label),'') is not null
on conflict(property_id,name) do nothing;
-- Preserve the existing onboarding/create-property flows which populate floor_label.
create or replace function public.register_room_floor() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if nullif(btrim(new.floor_label),'') is not null then
    insert into public.property_floors(organization_id,property_id,name) values(new.organization_id,new.property_id,new.floor_label) on conflict(property_id,name) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.register_room_floor() from public,anon,authenticated;
drop trigger if exists register_room_floor on public.rooms;
create trigger register_room_floor after insert or update of floor_label on public.rooms for each row execute function public.register_room_floor();
create table if not exists public.property_tax_rules (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null, property_id uuid not null,
  name text not null check(length(btrim(name)) between 1 and 120),
  rate_basis_points integer not null check(rate_basis_points between 0 and 10000), active boolean not null default true,
  foreign key(organization_id,property_id) references public.properties(organization_id,id), unique(property_id,name)
);
alter table public.property_floors enable row level security;
alter table public.property_tax_rules enable row level security;
drop policy if exists floors_read on public.property_floors;
create policy floors_read on public.property_floors for select to authenticated using(public.can_access_property(organization_id,property_id));
drop policy if exists tax_rules_read on public.property_tax_rules;
create policy tax_rules_read on public.property_tax_rules for select to authenticated using(public.can_access_property(organization_id,property_id));
grant select on public.property_floors,public.property_tax_rules to authenticated;

create or replace function public.save_property_configuration(p_property_id uuid,p_kind text,p_id uuid,p_values jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid; v_id uuid:=coalesce(p_id,gen_random_uuid()); v_name text:=btrim(p_values->>'name');
  v_before jsonb; v_after jsonb; v_type uuid; v_floor text; v_active boolean:=coalesce((p_values->>'active')::boolean,true);
begin
  select organization_id into v_org from public.properties where id=p_property_id for update;
  if v_org is null or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager']::public.member_role[]) then
    raise exception 'Only an authorized owner or manager can configure this property.' using errcode='42501';
  end if;
  if p_kind is null or p_kind not in ('property','room_type','room','floor','payment_method','tax') then raise exception 'Choose a supported setting.'; end if;
  if p_kind<>'room' and (v_name is null or length(v_name) not between 1 and 120) then raise exception 'Enter a name between 1 and 120 characters.'; end if;
  if p_kind='property' then
    if p_id is distinct from p_property_id then raise exception 'Select this property to edit.'; end if;
    select to_jsonb(p) into v_before from public.properties p where id=p_id;
    if nullif(btrim(p_values->>'city'),'') is null then raise exception 'Enter the hotel city.'; end if;
    update public.properties set name=v_name,address=nullif(btrim(p_values->>'address'),''),city=btrim(p_values->>'city'),
      check_in_time=(p_values->>'check_in_time')::time,check_out_time=(p_values->>'check_out_time')::time where id=p_id;
    select to_jsonb(p) into v_after from public.properties p where id=p_id;
  elsif p_kind='room_type' then
    if coalesce((p_values->>'max_occupancy')::integer,0) not between 1 and 20 then raise exception 'Capacity must be between 1 and 20.'; end if;
    if p_id is not null then
      select to_jsonb(t) into v_before from public.room_types t where id=p_id and property_id=p_property_id for update;
      if v_before is null then raise exception 'Room type is unavailable.'; end if;
      if not v_active and exists(select 1 from public.rooms where room_type_id=p_id and active) then raise exception 'Deactivate the rooms in this type first.'; end if;
      update public.room_types set name=v_name,max_occupancy=(p_values->>'max_occupancy')::smallint,active=v_active where id=p_id;
    else
      insert into public.room_types(id,organization_id,property_id,name,base_rate_kobo,max_occupancy,active)
      values(v_id,v_org,p_property_id,v_name,(p_values->>'base_rate_kobo')::bigint,(p_values->>'max_occupancy')::smallint,v_active);
    end if;
    select to_jsonb(t) into v_after from public.room_types t where id=v_id;
  elsif p_kind='room' then
    v_type:=(p_values->>'room_type_id')::uuid; v_floor:=nullif(btrim(p_values->>'floor_label'),'');
    if length(btrim(coalesce(p_values->>'room_number',''))) not between 1 and 120 then raise exception 'Enter a valid room number.'; end if;
    if not exists(select 1 from public.room_types where id=v_type and property_id=p_property_id and active) then raise exception 'Select an active room type in this property.'; end if;
    if v_floor is not null and not exists(select 1 from public.property_floors where property_id=p_property_id and name=v_floor) then raise exception 'Select a floor in this property.'; end if;
    if p_id is not null then
      select to_jsonb(r) into v_before from public.rooms r where id=p_id and property_id=p_property_id for update;
      if v_before is null then raise exception 'Room is unavailable.'; end if;
      if exists(select 1 from public.reservation_rooms rr join public.reservations b on b.id=rr.reservation_id where rr.room_id=p_id and b.status in ('confirmed','checked_in'))
        and (not v_active or (v_before->>'room_type_id')::uuid<>v_type or v_before->>'room_number'<>btrim(p_values->>'room_number')) then
        raise exception 'Move or close active reservations before renumbering, changing type or deactivating this room.';
      end if;
      update public.rooms set room_number=btrim(p_values->>'room_number'),room_type_id=v_type,floor_label=v_floor,active=v_active where id=p_id;
    else
      insert into public.rooms(id,organization_id,property_id,room_type_id,room_number,floor_label,active)
      values(v_id,v_org,p_property_id,v_type,btrim(p_values->>'room_number'),v_floor,v_active);
    end if;
    select to_jsonb(r) into v_after from public.rooms r where id=v_id;
  elsif p_kind='floor' then
    if p_id is not null then
      select to_jsonb(f) into v_before from public.property_floors f where id=p_id and property_id=p_property_id for update;
      if v_before is null then raise exception 'Floor is unavailable.'; end if;
      update public.property_floors set name=v_name where id=p_id;
      update public.rooms set floor_label=v_name where property_id=p_property_id and floor_label=v_before->>'name';
    else
      insert into public.property_floors(id,organization_id,property_id,name) values(v_id,v_org,p_property_id,v_name);
    end if;
    select to_jsonb(f) into v_after from public.property_floors f where id=v_id;
  elsif p_kind='payment_method' then
    if coalesce(p_values->>'clearing_account_code','') not in ('1000','1010','1020') then raise exception 'Select Cash, Bank or Card clearing.'; end if;
    if p_id is not null then
      select to_jsonb(m) into v_before from public.payment_methods m where id=p_id and property_id=p_property_id for update;
      if v_before is null then raise exception 'Payment method is unavailable.'; end if;
      if v_before->>'clearing_account_code'<>p_values->>'clearing_account_code' then raise exception 'Create a new payment method to use a different account.'; end if;
      update public.payment_methods set name=v_name,active=v_active where id=p_id;
    else
      insert into public.payment_methods(id,organization_id,property_id,name,clearing_account_code,active)
      values(v_id,v_org,p_property_id,v_name,p_values->>'clearing_account_code',v_active);
    end if;
    select to_jsonb(m) into v_after from public.payment_methods m where id=v_id;
  elsif p_kind='tax' then
    if p_id is not null then
      select to_jsonb(t) into v_before from public.property_tax_rules t where id=p_id and property_id=p_property_id for update;
      if v_before is null then raise exception 'Tax rule is unavailable.'; end if;
      update public.property_tax_rules set name=v_name,rate_basis_points=(p_values->>'rate_basis_points')::integer,active=v_active where id=p_id;
    else
      insert into public.property_tax_rules(id,organization_id,property_id,name,rate_basis_points,active)
      values(v_id,v_org,p_property_id,v_name,(p_values->>'rate_basis_points')::integer,v_active);
    end if;
    select to_jsonb(t) into v_after from public.property_tax_rules t where id=v_id;
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
  values(v_org,p_property_id,auth.uid(),'configuration_saved',p_kind,v_id,v_before,v_after);
  return v_id;
end $$;
revoke all on function public.save_property_configuration(uuid,text,uuid,jsonb) from public,anon;
grant execute on function public.save_property_configuration(uuid,text,uuid,jsonb) to authenticated;

create table if not exists public.stock_items (
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  name text not null check(length(btrim(name)) between 1 and 120),unit text not null check(length(btrim(unit)) between 1 and 40),
  par_level numeric(14,3) not null default 0 check(par_level>=0),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),unique(property_id,name),unique(organization_id,property_id,id)
);
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,item_id uuid not null,
  quantity numeric(14,3) not null check(quantity<>0),reason text not null check(length(btrim(reason)) between 5 and 500),
  idempotency_key text not null check(length(idempotency_key) between 1 and 120),created_by uuid not null references auth.users,
  created_at timestamptz not null default now(),
  foreign key(organization_id,property_id,item_id) references public.stock_items(organization_id,property_id,id),unique(property_id,idempotency_key)
);
alter table public.stock_items enable row level security;
alter table public.stock_movements enable row level security;
drop policy if exists stock_items_read on public.stock_items;
create policy stock_items_read on public.stock_items for select to authenticated using(public.can_access_property(organization_id,property_id) and public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
drop policy if exists stock_movements_read on public.stock_movements;
create policy stock_movements_read on public.stock_movements for select to authenticated using(public.can_access_property(organization_id,property_id) and public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
grant select on public.stock_items,public.stock_movements to authenticated;
create or replace view public.stock_balances with(security_invoker=true) as
select i.id,i.organization_id,i.property_id,i.name,i.unit,i.par_level,coalesce(sum(m.quantity),0) as on_hand
from public.stock_items i left join public.stock_movements m on m.item_id=i.id group by i.id;
grant select on public.stock_balances to authenticated;
create or replace function public.reject_stock_movement_change() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Stock movements are immutable. Record a correcting movement with a reason.'; end $$;
drop trigger if exists immutable_stock_movement on public.stock_movements;
create trigger immutable_stock_movement before update or delete on public.stock_movements for each row execute function public.reject_stock_movement_change();

create or replace function public.save_stock_item(p_property_id uuid,p_name text,p_unit text,p_par_level numeric)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid;v_id uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if v_org is null or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then raise exception 'You cannot manage inventory at this property.' using errcode='42501'; end if;
  if p_par_level is null or p_par_level::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a valid par level.'; end if;
  insert into public.stock_items(organization_id,property_id,name,unit,par_level) values(v_org,p_property_id,btrim(p_name),btrim(p_unit),p_par_level) returning id into v_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id) values(v_org,p_property_id,auth.uid(),'stock_item_created','stock_item',v_id);
  return v_id;
end $$;
create or replace function public.record_stock_movement(p_item_id uuid,p_quantity numeric,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_item public.stock_items;v_existing public.stock_movements;v_id uuid;v_balance numeric;
begin
  select * into v_item from public.stock_items where id=p_item_id for update;
  if v_item.id is null or not public.can_access_property(v_item.organization_id,v_item.property_id) or not public.has_org_role(v_item.organization_id,array['owner','manager','accountant']::public.member_role[]) then raise exception 'You cannot manage this stock item.' using errcode='42501'; end if;
  if p_quantity is null or p_quantity=0 or p_quantity::text in ('NaN','Infinity','-Infinity') or p_quantity<>round(p_quantity,3) then raise exception 'Enter a nonzero quantity with at most three decimals.'; end if;
  select * into v_existing from public.stock_movements where property_id=v_item.property_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.item_id<>p_item_id or v_existing.quantity<>p_quantity or v_existing.reason<>btrim(p_reason) or v_existing.created_by<>auth.uid() then raise exception 'This movement reference was already used.'; end if;
    return v_existing.id;
  end if;
  select coalesce(sum(quantity),0) into v_balance from public.stock_movements where item_id=p_item_id;
  if v_balance+p_quantity<0 then raise exception 'Stock issued cannot exceed the quantity on hand.'; end if;
  insert into public.stock_movements(organization_id,property_id,item_id,quantity,reason,idempotency_key,created_by)
  values(v_item.organization_id,v_item.property_id,p_item_id,p_quantity,btrim(p_reason),p_idempotency_key,auth.uid()) returning id into v_id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
  values(v_item.organization_id,v_item.property_id,auth.uid(),'stock_movement_recorded','stock_movement',v_id,jsonb_build_object('item_id',p_item_id,'quantity',p_quantity,'reason',btrim(p_reason)));
  return v_id;
end $$;
revoke all on function public.save_stock_item(uuid,text,text,numeric),public.record_stock_movement(uuid,numeric,text,text),public.reject_stock_movement_change() from public,anon;
grant execute on function public.save_stock_item(uuid,text,text,numeric),public.record_stock_movement(uuid,numeric,text,text) to authenticated;
