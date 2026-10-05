-- Financial statements read immutable posted journals. Charge aging uses FIFO
-- allocation for reporting, not a mutation of the original guest subledger.
create index if not exists folio_items_journal_report_idx on public.folio_items(organization_id,property_id,journal_id) where journal_id is not null;

create or replace function public.assert_finance_report_access(p_property_id uuid) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501';
  end if;
  return v_org;
end $$;
revoke all on function public.assert_finance_report_access(uuid) from public,anon,authenticated;

create or replace function public.get_balance_sheet(p_property_id uuid,p_as_of date)
returns table(account_code text,account_name text,account_type text,amount_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid:=public.assert_finance_report_access(p_property_id);
begin
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query
  with balances as (
    select a.code,a.name,a.account_type as kind,sum(l.debit_kobo-l.credit_kobo)::bigint as net
    from public.journal_lines l join public.journals j on (j.organization_id,j.id)=(l.organization_id,l.journal_id)
      join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_as_of
    group by a.code,a.name,a.account_type
  )
  select b.code,b.name,b.kind,case when b.kind='asset' then b.net else -b.net end from balances b where b.kind in ('asset','liability','equity') and b.net<>0
  union all
  select '__earnings__','Accumulated earnings (unclosed)','equity',coalesce(-sum(b.net),0)::bigint from balances b where b.kind in ('revenue','expense');
end $$;
revoke all on function public.get_balance_sheet(uuid,date) from public,anon;
grant execute on function public.get_balance_sheet(uuid,date) to authenticated;

create or replace function public.get_guest_receivables_aging(p_property_id uuid,p_as_of date)
returns table(folio_id uuid,reservation_id uuid,guest_name text,oldest_unpaid_charge date,net_balance_kobo bigint,
  outstanding_kobo bigint,credit_kobo bigint,age_0_30_kobo bigint,age_31_60_kobo bigint,age_61_90_kobo bigint,age_90_plus_kobo bigint,unaged_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid:=public.assert_finance_report_access(p_property_id);
begin
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query
  with mapping as (
    select fi.journal_id,min(fi.folio_id::text)::uuid as fid,
      bool_or(fi.item_type in ('room_charge','extra','tax','fee','adjustment')) as is_charge
    from public.folio_items fi where fi.organization_id=v_org and fi.property_id=p_property_id and fi.journal_id is not null
    group by fi.journal_id having count(distinct fi.folio_id)=1
  ), events as (
    select m.fid,j.id as jid,j.journal_date,m.is_charge,sum(l.debit_kobo-l.credit_kobo)::bigint as net
    from mapping m join public.journals j on j.id=m.journal_id
      join public.journal_lines l on (l.organization_id,l.journal_id)=(j.organization_id,j.id)
      join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_as_of and a.code='1100'
    group by m.fid,j.id,j.journal_date,m.is_charge
  ), balances as (
    select e.fid,sum(e.net)::bigint as net,sum(case when e.is_charge then greatest(e.net,0) else 0 end)::bigint as charges
    from events e group by e.fid
  ), charges as (
    select e.fid,e.journal_date,e.net,
      sum(e.net) over(partition by e.fid order by e.journal_date,e.jid rows between unbounded preceding and current row) as cumulative
    from events e where e.is_charge and e.net>0
  ), allocated as (
    select c.fid,c.journal_date,least(c.net,greatest(c.cumulative-greatest(b.charges-b.net,0),0))::bigint as owed
    from charges c join balances b on b.fid=c.fid
  ), ages as (
    select x.fid,min(x.journal_date) filter(where x.owed>0) as oldest,
      coalesce(sum(x.owed) filter(where p_as_of-x.journal_date between 0 and 30),0)::bigint as a0,
      coalesce(sum(x.owed) filter(where p_as_of-x.journal_date between 31 and 60),0)::bigint as a31,
      coalesce(sum(x.owed) filter(where p_as_of-x.journal_date between 61 and 90),0)::bigint as a61,
      coalesce(sum(x.owed) filter(where p_as_of-x.journal_date>90),0)::bigint as a90,
      coalesce(sum(x.owed),0)::bigint as aged
    from allocated x group by x.fid
  )
  select f.id,r.id,g.full_name,x.oldest,b.net,greatest(b.net,0),greatest(-b.net,0),
    coalesce(x.a0,0),coalesce(x.a31,0),coalesce(x.a61,0),coalesce(x.a90,0),greatest(b.net,0)-coalesce(x.aged,0)
  from balances b join public.folios f on f.id=b.fid
    join public.reservations r on (r.organization_id,r.id)=(f.organization_id,f.reservation_id)
    join public.guests g on (g.organization_id,g.id)=(r.organization_id,r.guest_id)
    left join ages x on x.fid=b.fid
  where f.organization_id=v_org and f.property_id=p_property_id and b.net<>0 order by x.oldest nulls last,g.full_name,f.id;
end $$;
revoke all on function public.get_guest_receivables_aging(uuid,date) from public,anon;
grant execute on function public.get_guest_receivables_aging(uuid,date) to authenticated;

create or replace function public.get_guest_receivables_summary(p_property_id uuid,p_as_of date)
returns table(ledger_kobo bigint,folio_net_kobo bigint,outstanding_kobo bigint,credit_kobo bigint,age_0_30_kobo bigint,
  age_31_60_kobo bigint,age_61_90_kobo bigint,age_90_plus_kobo bigint,unaged_kobo bigint,unassigned_kobo bigint,unpaid_folios bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid:=public.assert_finance_report_access(p_property_id);
begin
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query with ledger as (
    select coalesce(sum(l.debit_kobo-l.credit_kobo),0)::bigint as amount from public.journal_lines l
      join public.journals j on (j.organization_id,j.id)=(l.organization_id,l.journal_id)
      join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_as_of and a.code='1100'
  ), folios as (
    select coalesce(sum(b.net_balance_kobo),0)::bigint as net,coalesce(sum(b.outstanding_kobo),0)::bigint as owed,
      coalesce(sum(b.credit_kobo),0)::bigint as credit,coalesce(sum(b.age_0_30_kobo),0)::bigint as a0,
      coalesce(sum(b.age_31_60_kobo),0)::bigint as a31,coalesce(sum(b.age_61_90_kobo),0)::bigint as a61,
      coalesce(sum(b.age_90_plus_kobo),0)::bigint as a90,coalesce(sum(b.unaged_kobo),0)::bigint as unaged,
      count(*) filter(where b.outstanding_kobo>0) as unpaid
    from public.get_guest_receivables_aging(p_property_id,p_as_of) b
  ) select l.amount,f.net,f.owed,f.credit,f.a0,f.a31,f.a61,f.a90,f.unaged,l.amount-f.net,f.unpaid from ledger l cross join folios f;
end $$;
revoke all on function public.get_guest_receivables_summary(uuid,date) from public,anon;
grant execute on function public.get_guest_receivables_summary(uuid,date) to authenticated;

create or replace function public.default_cash_flow_activity(p_source text) returns text
language sql immutable set search_path='' as $$
  select case when p_source in ('folio_payment','guest_deposit','payment_refund','expense','supplier_payment','supplier_payment_reversal') then 'operating' else 'unclassified' end
$$;
revoke all on function public.default_cash_flow_activity(text) from public,anon,authenticated;

create table if not exists public.cash_flow_classifications(
  id uuid primary key default gen_random_uuid(),revision bigint generated always as identity unique,
  organization_id uuid not null,property_id uuid not null,journal_id uuid not null,
  activity text not null check(activity in ('operating','investing','financing')),
  reason text not null check(length(btrim(reason)) between 5 and 500),
  idempotency_key text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  foreign key(organization_id,property_id,journal_id) references public.journals(organization_id,property_id,id),
  unique(organization_id,idempotency_key)
);
create index if not exists cash_flow_classification_latest_idx on public.cash_flow_classifications(journal_id,revision desc);
alter table public.cash_flow_classifications enable row level security;
drop policy if exists cash_flow_classification_read on public.cash_flow_classifications;
create policy cash_flow_classification_read on public.cash_flow_classifications for select to authenticated using(
  public.can_access_property(organization_id,property_id) and public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
revoke all on public.cash_flow_classifications from public,anon,authenticated;
grant select on public.cash_flow_classifications to authenticated;
revoke all on sequence public.cash_flow_classifications_revision_seq from public,anon,authenticated;

create or replace function public.guard_cash_flow_classification() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Cash-flow classifications are immutable. Record a new classification with a reason.' using errcode='23514'; end $$;
revoke all on function public.guard_cash_flow_classification() from public,anon,authenticated;
drop trigger if exists cash_flow_classification_immutable on public.cash_flow_classifications;
create trigger cash_flow_classification_immutable before update or delete on public.cash_flow_classifications for each row execute function public.guard_cash_flow_classification();

create or replace function public.classify_cash_flow(p_journal_id uuid,p_activity text,p_reason text,p_idempotency_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v public.journals%rowtype; prior public.cash_flow_classifications%rowtype; result uuid; cash bigint;
begin
  select * into v from public.journals where id=p_journal_id for update;
  if not found or not public.can_access_property(v.organization_id,v.property_id) or not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can classify this cash movement.' using errcode='42501'; end if;
  if p_activity is null or p_activity not in ('operating','investing','financing') or length(btrim(coalesce(p_reason,''))) not between 5 and 500 or length(coalesce(p_idempotency_key,''))<8 then
    raise exception 'Choose an activity and enter a reason and transaction key.' using errcode='22023'; end if;
  if v.status<>'posted' or public.default_cash_flow_activity(v.source_type)<>'unclassified' then
    raise exception 'This entry already has a workflow-defined cash classification.' using errcode='23514'; end if;
  select coalesce(sum(l.debit_kobo-l.credit_kobo),0)::bigint into cash from public.journal_lines l join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    where l.organization_id=v.organization_id and l.journal_id=v.id and a.code in ('1000','1010');
  if cash=0 then raise exception 'This entry has no net cash or bank movement.' using errcode='23514'; end if;
  select * into prior from public.cash_flow_classifications where organization_id=v.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.journal_id<>p_journal_id or prior.activity<>p_activity or prior.reason<>btrim(p_reason) then
      raise exception 'Transaction key was already used for a different classification.' using errcode='23505'; end if;
    return prior.id;
  end if;
  insert into public.cash_flow_classifications(organization_id,property_id,journal_id,activity,reason,idempotency_key,created_by)
    values(v.organization_id,v.property_id,v.id,p_activity,btrim(p_reason),p_idempotency_key,auth.uid()) returning id into result;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'cash_flow_classified','journal',v.id,jsonb_build_object('classification_id',result,'activity',p_activity,'reason',btrim(p_reason)));
  return result;
end $$;
revoke all on function public.classify_cash_flow(uuid,text,text,text) from public,anon;
grant execute on function public.classify_cash_flow(uuid,text,text,text) to authenticated;

create or replace function public.get_cash_flow_journals(p_property_id uuid,p_from date,p_to date)
returns table(journal_id uuid,journal_date date,memo text,source_type text,activity text,amount_kobo bigint,classification_reason text)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid:=public.assert_finance_report_access(p_property_id);
begin
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to one year.' using errcode='22023'; end if;
  return query select j.id,j.journal_date,j.memo,j.source_type,coalesce(c.activity,public.default_cash_flow_activity(j.source_type)),
    sum(l.debit_kobo-l.credit_kobo)::bigint,c.reason
  from public.journals j join public.journal_lines l on (l.organization_id,l.journal_id)=(j.organization_id,j.id)
    join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    left join lateral(select x.activity,x.reason from public.cash_flow_classifications x where x.organization_id=j.organization_id and x.property_id=j.property_id and x.journal_id=j.id order by x.revision desc limit 1) c on true
  where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date between p_from and p_to and a.code in ('1000','1010')
  group by j.id,j.journal_date,j.memo,j.source_type,c.activity,c.reason having sum(l.debit_kobo-l.credit_kobo)<>0 order by j.journal_date desc,j.id;
end $$;
revoke all on function public.get_cash_flow_journals(uuid,date,date) from public,anon;
grant execute on function public.get_cash_flow_journals(uuid,date,date) to authenticated;

create or replace function public.get_cash_flow(p_property_id uuid,p_from date,p_to date)
returns table(activity text,inflow_kobo bigint,outflow_kobo bigint,net_kobo bigint)
language sql stable security definer set search_path='' as $$
  with movements as (select * from public.get_cash_flow_journals(p_property_id,p_from,p_to))
  select t.activity,coalesce(sum(greatest(m.amount_kobo,0)),0)::bigint,coalesce(sum(greatest(-m.amount_kobo,0)),0)::bigint,coalesce(sum(m.amount_kobo),0)::bigint
  from (values('operating'),('investing'),('financing'),('unclassified')) t(activity) left join movements m on m.activity=t.activity group by t.activity;
$$;
revoke all on function public.get_cash_flow(uuid,date,date) from public,anon;
grant execute on function public.get_cash_flow(uuid,date,date) to authenticated;

create or replace function public.get_cash_flow_summary(p_property_id uuid,p_from date,p_to date)
returns table(opening_cash_kobo bigint,closing_cash_kobo bigint,net_change_kobo bigint,unclassified_journals bigint,pos_clearing_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid:=public.assert_finance_report_access(p_property_id);
begin
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to one year.' using errcode='22023'; end if;
  return query with ledger as (
    select coalesce(sum(l.debit_kobo-l.credit_kobo) filter(where a.code in ('1000','1010') and j.journal_date<p_from),0)::bigint as opening,
      coalesce(sum(l.debit_kobo-l.credit_kobo) filter(where a.code in ('1000','1010')),0)::bigint as closing,
      coalesce(sum(l.debit_kobo-l.credit_kobo) filter(where a.code='1020'),0)::bigint as clearing
    from public.journal_lines l join public.journals j on (j.organization_id,j.id)=(l.organization_id,l.journal_id)
      join public.accounts a on (a.organization_id,a.id)=(l.organization_id,l.account_id)
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_to
  ) select l.opening,l.closing,l.closing-l.opening,
    (select count(*) from public.get_cash_flow_journals(p_property_id,p_from,p_to) m where m.activity='unclassified'),l.clearing from ledger l;
end $$;
revoke all on function public.get_cash_flow_summary(uuid,date,date) from public,anon;
grant execute on function public.get_cash_flow_summary(uuid,date,date) to authenticated;

notify pgrst,'reload schema';
