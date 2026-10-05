-- Guest cash collected includes advances and subtracts refunds.
create or replace function public.get_property_financial_summary(p_property_id uuid,p_from date,p_to date)
returns table(room_revenue_kobo bigint,other_revenue_kobo bigint,expense_kobo bigint,
  payments_kobo bigint,outstanding_kobo bigint,room_nights bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found then raise exception 'Property not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[])
    or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then
    raise exception 'Choose a date range of up to one year.' using errcode='22023'; end if;
  return query
  select
    coalesce(sum(case when a.code='4000' then l.credit_kobo-l.debit_kobo else 0 end),0)::bigint,
    coalesce(sum(case when a.code='4100' then l.credit_kobo-l.debit_kobo else 0 end),0)::bigint,
    coalesce(sum(case when a.account_type='expense' then l.debit_kobo-l.credit_kobo else 0 end),0)::bigint,
    coalesce(sum(case when j.source_type in ('folio_payment','guest_deposit','payment_refund')
      and a.code in ('1000','1010','1020') then l.debit_kobo-l.credit_kobo else 0 end),0)::bigint,
    (select coalesce(sum(fi.total_amount_kobo),0)::bigint from public.folios f
      join public.folio_items fi on fi.organization_id=f.organization_id and fi.folio_id=f.id
      where f.organization_id=v_org and f.property_id=p_property_id and f.status='open'),
    (select count(*)::bigint from public.folio_items fi where fi.organization_id=v_org and fi.property_id=p_property_id
      and fi.item_type='room_charge' and fi.service_date between p_from and p_to)
  from public.journals j join public.journal_lines l on l.organization_id=j.organization_id and l.journal_id=j.id
    join public.accounts a on a.organization_id=l.organization_id and a.id=l.account_id
  where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted'
    and j.journal_date between p_from and p_to;
end $$;
revoke all on function public.get_property_financial_summary(uuid,date,date) from public,anon;
grant execute on function public.get_property_financial_summary(uuid,date,date) to authenticated;
