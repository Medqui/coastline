-- Named staff identities and operational shifts. Cash reconciliation remains in cashier_shifts.
alter table public.organization_memberships add column if not exists full_name text check(full_name is null or length(btrim(full_name)) between 2 and 120);
alter table public.team_invitations add column if not exists full_name text;

create or replace function public.save_staff_name(p_organization_id uuid,p_full_name text,p_user_id uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare target uuid:=coalesce(p_user_id,auth.uid());
begin
 if not public.has_org_role(p_organization_id,array['owner','manager','front_desk','housekeeping','accountant']::public.member_role[]) or (target<>auth.uid() and not public.has_org_role(p_organization_id,array['owner']::public.member_role[])) then raise exception 'You can only change your own name; owners can manage staff names.' using errcode='42501'; end if;
 if length(btrim(coalesce(p_full_name,''))) not between 2 and 120 then raise exception 'Enter a full name between 2 and 120 characters.'; end if;
 update public.organization_memberships set full_name=btrim(p_full_name) where organization_id=p_organization_id and user_id=target and active;
 if not found then raise exception 'Staff membership is unavailable.'; end if;
 insert into public.audit_events(organization_id,actor_user_id,action,entity_type,after_data) values(p_organization_id,auth.uid(),'staff_name_updated','membership',jsonb_build_object('user_id',target,'full_name',btrim(p_full_name)));
end $$;
revoke all on function public.save_staff_name(uuid,text,uuid) from public,anon;
grant execute on function public.save_staff_name(uuid,text,uuid) to authenticated;

create or replace function public.create_named_team_invitation(p_organization_id uuid,p_property_id uuid,p_email text,p_role public.member_role,p_full_name text)
returns text language plpgsql security definer set search_path='' as $$
declare token text;
begin
 if length(btrim(coalesce(p_full_name,''))) not between 2 and 120 then raise exception 'Enter the staff member’s full name.'; end if;
 token:=public.create_team_invitation(p_organization_id,p_property_id,p_email,p_role);
 update public.team_invitations set full_name=btrim(p_full_name) where token_hash=encode(public.digest(token,'sha256'),'hex');
 return token;
end $$;
revoke all on function public.create_named_team_invitation(uuid,uuid,text,public.member_role,text) from public,anon;
grant execute on function public.create_named_team_invitation(uuid,uuid,text,public.member_role,text) to authenticated;

create or replace function public.apply_invited_staff_name() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.accepted_at is null and new.accepted_at is not null and new.full_name is not null then
  update public.organization_memberships set full_name=new.full_name where organization_id=new.organization_id and user_id=auth.uid();
 end if;
 return new;
end $$;
revoke all on function public.apply_invited_staff_name() from public,anon,authenticated;
drop trigger if exists invited_staff_name on public.team_invitations;
create trigger invited_staff_name after update on public.team_invitations for each row execute function public.apply_invited_staff_name();

create or replace function public.get_staff_directory(p_organization_id uuid)
returns table(user_id uuid,email text,full_name text,role public.member_role,active boolean)
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.has_org_role(p_organization_id,array['owner']::public.member_role[]) then raise exception 'Only owners can view the staff directory.' using errcode='42501'; end if;
 return query select m.user_id,u.email::text,coalesce(m.full_name,u.raw_user_meta_data->>'full_name',''),m.role,m.active from public.organization_memberships m join auth.users u on u.id=m.user_id where m.organization_id=p_organization_id order by m.created_at;
end $$;
revoke all on function public.get_staff_directory(uuid) from public,anon;
grant execute on function public.get_staff_directory(uuid) to authenticated;

create table if not exists public.staff_shifts(
 id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
 user_id uuid not null references auth.users,staff_name text not null,staff_role public.member_role not null,
 started_at timestamptz not null default now(),ended_at timestamptz,handover_note text,handover_summary jsonb,
 foreign key(organization_id,property_id) references public.properties(organization_id,id),
 check(ended_at is null or ended_at>=started_at),check(handover_note is null or length(handover_note) between 5 and 2000)
);
create unique index if not exists staff_one_open_shift on public.staff_shifts(organization_id,user_id) where ended_at is null;
create index if not exists staff_shifts_property_date on public.staff_shifts(property_id,started_at desc);
alter table public.staff_shifts enable row level security;
grant select on public.staff_shifts to authenticated;
drop policy if exists staff_shifts_read on public.staff_shifts;
create policy staff_shifts_read on public.staff_shifts for select to authenticated using(public.can_access_property(organization_id,property_id) and (user_id=auth.uid() or public.has_org_role(organization_id,array['owner','manager']::public.member_role[])));

create or replace function public.start_staff_shift(p_property_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;name text;staffrole public.member_role;result uuid;prior public.staff_shifts%rowtype;
begin
 select organization_id into org from public.properties where id=p_property_id;
 if org is null or not public.can_access_property(org,p_property_id) then raise exception 'You cannot start a shift at this property.' using errcode='42501'; end if;
 select full_name,role into name,staffrole from public.organization_memberships where organization_id=org and user_id=auth.uid() and active;
 if name is null or length(btrim(name))<2 then raise exception 'Save your full name before starting a shift.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':staff-shift:'||auth.uid()::text,0));
 select * into prior from public.staff_shifts where organization_id=org and user_id=auth.uid() and ended_at is null;
 if found then
  if prior.property_id<>p_property_id then raise exception 'End your shift at the other property first.'; end if;
  return prior.id;
 end if;
 insert into public.staff_shifts(organization_id,property_id,user_id,staff_name,staff_role) values(org,p_property_id,auth.uid(),name,staffrole) returning id into result;
 insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id) values(org,p_property_id,auth.uid(),'staff_shift_started','staff_shift',result);
 return result;
end $$;
revoke all on function public.start_staff_shift(uuid) from public,anon;
grant execute on function public.start_staff_shift(uuid) to authenticated;

create or replace function public.staff_handover_summary(p_property_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare org uuid;today date;result jsonb;start_time timestamptz;
begin
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
revoke all on function public.staff_handover_summary(uuid) from public,anon;
grant execute on function public.staff_handover_summary(uuid) to authenticated;

create or replace function public.end_staff_shift(p_shift_id uuid,p_handover_note text) returns void language plpgsql security definer set search_path='' as $$
declare s public.staff_shifts%rowtype;summary jsonb;
begin
 select * into s from public.staff_shifts where id=p_shift_id for update;
 if not found or s.user_id<>auth.uid() or not public.can_access_property(s.organization_id,s.property_id) then raise exception 'You can only end your own shift.' using errcode='42501'; end if;
 if s.ended_at is not null then return; end if;
 if length(btrim(coalesce(p_handover_note,''))) not between 5 and 2000 then raise exception 'Leave a handover note between 5 and 2000 characters.'; end if;
 if exists(select 1 from public.cashier_shifts where property_id=s.property_id and cashier_user_id=auth.uid() and status in ('open','pending_approval')) then raise exception 'Close your cashier shift and resolve any variance review before ending your staff shift.'; end if;
 summary:=public.staff_handover_summary(s.property_id);
 update public.staff_shifts set ended_at=now(),handover_note=btrim(p_handover_note),handover_summary=summary where id=s.id;
 insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data) values(s.organization_id,s.property_id,auth.uid(),'staff_shift_ended','staff_shift',s.id,jsonb_build_object('summary',summary));
end $$;
revoke all on function public.end_staff_shift(uuid,text) from public,anon;
grant execute on function public.end_staff_shift(uuid,text) to authenticated;

alter table public.audit_events add column if not exists staff_shift_id uuid references public.staff_shifts;
create or replace function public.tag_staff_shift_audit() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.entity_type='staff_shift' then new.staff_shift_id:=new.entity_id; return new; end if;
 select id into new.staff_shift_id from public.staff_shifts where organization_id=new.organization_id and property_id=new.property_id and user_id=new.actor_user_id and ended_at is null;
 return new;
end $$;
revoke all on function public.tag_staff_shift_audit() from public,anon,authenticated;
drop trigger if exists audit_staff_shift on public.audit_events;
create trigger audit_staff_shift before insert on public.audit_events for each row execute function public.tag_staff_shift_audit();
-- Incoming staff can read operational handovers from their own role; managers oversee all.
create or replace function public.get_shift_handovers(p_property_id uuid)
returns table(id uuid,staff_name text,staff_role public.member_role,started_at timestamptz,ended_at timestamptz,handover_note text,handover_summary jsonb)
language plpgsql stable security definer set search_path='' as $$
declare org uuid;myrole public.member_role;
begin
 select organization_id into org from public.properties where public.properties.id=p_property_id;
 if org is null or not public.can_access_property(org,p_property_id) then raise exception 'You cannot view this property’s handovers.' using errcode='42501'; end if;
 select role into myrole from public.organization_memberships where organization_id=org and user_id=auth.uid() and active;
 return query select s.id,s.staff_name,s.staff_role,s.started_at,s.ended_at,s.handover_note,
 case when myrole in ('owner','manager') then s.handover_summary else s.handover_summary-'my_cash_received_kobo' end
 from public.staff_shifts s where s.property_id=p_property_id and s.ended_at is not null and (myrole in ('owner','manager') or s.staff_role=myrole) order by s.ended_at desc limit 20;
end $$;
revoke all on function public.get_shift_handovers(uuid) from public,anon;
grant execute on function public.get_shift_handovers(uuid) to authenticated;
