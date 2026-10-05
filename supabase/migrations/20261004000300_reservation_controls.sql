-- Operational close-out and least-privilege reads.
create or replace function public.close_unchecked_reservation(
  p_reservation_id uuid,p_status public.reservation_status,p_reason text
) returns void language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_today date;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot change this reservation.' using errcode='42501'; end if;
  if v_res.status<>'confirmed' then raise exception 'Only confirmed stays can be cancelled or marked no-show.' using errcode='23514'; end if;
  if p_status not in ('cancelled','no_show') then raise exception 'Choose cancelled or no-show.' using errcode='22023'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Enter a reason for this change.' using errcode='22023'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  if p_status='no_show' and v_today<v_res.arrival_date then
    raise exception 'A no-show can be marked on or after arrival.' using errcode='23514'; end if;
  update public.reservations set status=p_status where id=v_res.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v_res.organization_id,v_res.property_id,auth.uid(),'reservation_closed','reservation',v_res.id,
      jsonb_build_object('status',v_res.status),jsonb_build_object('status',p_status,'reason',btrim(p_reason)));
end $$;
revoke all on function public.close_unchecked_reservation(uuid,public.reservation_status,text) from public,anon;
grant execute on function public.close_unchecked_reservation(uuid,public.reservation_status,text) to authenticated;

drop policy if exists folios_read on public.folios;
create policy folios_read on public.folios for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
drop policy if exists folio_items_read on public.folio_items;
create policy folio_items_read on public.folio_items for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
drop policy if exists guests_read on public.guests;
create policy guests_read on public.guests for select to authenticated using
  (public.has_org_role(organization_id,array['owner','manager','front_desk','accountant']::public.member_role[]));
