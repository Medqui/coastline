-- Department dimensions are captured before posting; historical journals stay immutable.
create table if not exists public.departments(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  code text not null,name text not null,active boolean not null default true,
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  unique(property_id,code),unique(organization_id,property_id,id)
);

alter table public.departments enable row level security;

drop policy if exists departments_read on public.departments;
create policy departments_read on public.departments for select to authenticated using(public.can_access_property(organization_id,property_id));

grant select on public.departments to authenticated;

create or replace function public.seed_property_departments() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.departments(organization_id,property_id,code,name) values
    (new.organization_id,new.id,'accommodation','Accommodation'),(new.organization_id,new.id,'restaurant','Restaurant'),
    (new.organization_id,new.id,'bar','Bar'),(new.organization_id,new.id,'laundry','Laundry'),
    (new.organization_id,new.id,'services','Guest services'),(new.organization_id,new.id,'administration','Administration') on conflict(property_id,code) do nothing;
  return new;
end $$;

revoke all on function public.seed_property_departments() from public,anon,authenticated;

drop trigger if exists seed_departments_on_property on public.properties;
create trigger seed_departments_on_property after insert on public.properties for each row execute function public.seed_property_departments();

insert into public.departments(organization_id,property_id,code,name)
  select p.organization_id,p.id,v.code,v.name from public.properties p cross join (values
    ('accommodation','Accommodation'),('restaurant','Restaurant'),('bar','Bar'),('laundry','Laundry'),
    ('services','Guest services'),('administration','Administration')) v(code,name) on conflict(property_id,code) do nothing;

do $pms_constraint$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.journals'::regclass and conname='journals_org_property_id_unique') then
    execute 'alter table public.journals add constraint journals_org_property_id_unique unique(organization_id,property_id,id)';
  end if;
end $pms_constraint$;

do $pms_constraint$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.payment_methods'::regclass and conname='payment_methods_org_property_id_unique') then
    execute 'alter table public.payment_methods add constraint payment_methods_org_property_id_unique unique(organization_id,property_id,id)';
  end if;
end $pms_constraint$;

alter table public.journals add column if not exists department_id uuid;

do $pms_constraint$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.journals'::regclass and conname='journals_department_property_fk') then
    execute 'alter table public.journals add constraint journals_department_property_fk foreign key(organization_id,property_id,department_id) references public.departments(organization_id,property_id,id)';
  end if;
end $pms_constraint$;

alter table public.expenses add column if not exists payment_method_id uuid;

do $pms_constraint$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.expenses'::regclass and conname='expenses_payment_method_fk') then
    execute 'alter table public.expenses add constraint expenses_payment_method_fk foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id)';
  end if;
end $pms_constraint$;

create or replace function public.post_department_accounting_event(
  p_org uuid,p_property uuid,p_source_type text,p_source_id uuid,p_date date,p_memo text,
  p_amount bigint,p_debit_code text,p_credit_code text,p_key text,p_department_id uuid,p_reverses uuid default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_debit uuid;v_credit uuid;v_journal uuid;v_department uuid;
begin
  if p_amount is null or p_amount<=0 or coalesce(length(p_key),0) not between 8 and 250 then
    raise exception 'Invalid accounting amount or transaction reference.' using errcode='22023'; end if;
  select id into v_debit from public.accounts where organization_id=p_org and code=p_debit_code and active;
  select id into v_credit from public.accounts where organization_id=p_org and code=p_credit_code and active;
  if v_debit is null or v_credit is null or v_debit=v_credit then raise exception 'Required accounts are unavailable.' using errcode='23514'; end if;
  v_department:=p_department_id;
  if v_department is null then
    select id into v_department from public.departments where organization_id=p_org and property_id=p_property and active and code=
      case when p_source_type='room_night' then 'accommodation' when p_source_type='folio_extra' then 'services'
        when p_source_type in ('expense','supplier_bill') then 'administration' else null end;
  elsif not exists(select 1 from public.departments where id=v_department and organization_id=p_org and property_id=p_property and active) then
    raise exception 'Choose an active department in this property.' using errcode='22023'; end if;
  if p_reverses is not null and not exists(select 1 from public.journals where id=p_reverses and organization_id=p_org and property_id=p_property and status='posted') then
    raise exception 'The original posting is unavailable.' using errcode='23514'; end if;
  insert into public.journals(organization_id,property_id,source_type,source_id,journal_date,memo,idempotency_key,created_by,department_id,reverses_journal_id)
    values(p_org,p_property,p_source_type,p_source_id,p_date,p_memo,p_key,auth.uid(),v_department,p_reverses) returning id into v_journal;
  insert into public.journal_lines(organization_id,journal_id,property_id,account_id,description,debit_kobo,credit_kobo) values
    (p_org,v_journal,p_property,v_debit,p_memo,p_amount,0),(p_org,v_journal,p_property,v_credit,p_memo,0,p_amount);
  update public.journals set status='posted',posted_by=auth.uid(),posted_at=now() where id=v_journal;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(p_org,p_property,auth.uid(),'journal_posted','journal',v_journal,jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'amount_kobo',p_amount,'department_id',v_department,'reverses_journal_id',p_reverses));
  return v_journal;
end $$;

revoke all on function public.post_department_accounting_event(uuid,uuid,text,uuid,date,text,bigint,text,text,text,uuid,uuid) from public,anon,authenticated;

create or replace function public.post_accounting_event(
  p_org uuid,p_property uuid,p_source_type text,p_source_id uuid,p_date date,p_memo text,
  p_amount bigint,p_debit_code text,p_credit_code text,p_key text
) returns uuid language sql security definer set search_path='' as $$
  select public.post_department_accounting_event(p_org,p_property,p_source_type,p_source_id,p_date,p_memo,p_amount,p_debit_code,p_credit_code,p_key,null)
$$;

create or replace function public.post_department_folio_charge(p_folio_id uuid,p_description text,p_amount_kobo bigint,p_idempotency_key text,p_department_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_folio public.folios%rowtype;v_department uuid;v_existing public.folio_items%rowtype;v_existing_department uuid;v_date date;v_item uuid;v_journal uuid;v_key text;
begin
  select * into v_folio from public.folios where id=p_folio_id;
  if not found or not public.has_org_role(v_folio.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_folio.organization_id,v_folio.property_id) then raise exception 'You cannot charge this folio.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_description,''))) not between 2 and 500 or p_amount_kobo is null or p_amount_kobo<=0
    or coalesce(length(p_idempotency_key),0) not between 8 and 200 then raise exception 'Enter a description, positive amount and transaction reference.' using errcode='22023'; end if;
  v_department:=p_department_id;
  if v_department is null then select id into v_department from public.departments where property_id=v_folio.property_id and code='services' and active; end if;
  if not exists(select 1 from public.departments where id=v_department and organization_id=v_folio.organization_id and property_id=v_folio.property_id and active) then
    raise exception 'Choose an active department in this property.' using errcode='22023'; end if;
  v_key:='extra:'||p_idempotency_key;
  perform pg_advisory_xact_lock(hashtextextended(v_folio.organization_id::text||':'||v_key,0));
  select * into v_folio from public.folios where id=p_folio_id for update;
  select i.* into v_existing from public.folio_items i where i.organization_id=v_folio.organization_id and i.source_key=v_key;
  select department_id into v_existing_department from public.journals where id=v_existing.journal_id;
  if v_existing.id is not null then
    if v_existing.folio_id<>p_folio_id or v_existing.total_amount_kobo<>p_amount_kobo or v_existing.description<>btrim(p_description)
      or coalesce(v_existing_department,(select id from public.departments where property_id=v_folio.property_id and code='services'))<>v_department then
      raise exception 'Transaction reference was already used for a different charge.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  if v_folio.status<>'open' then raise exception 'Folio is closed.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_folio.property_id;
  v_journal:=public.post_department_accounting_event(v_folio.organization_id,v_folio.property_id,'folio_extra',p_folio_id,v_date,btrim(p_description),p_amount_kobo,'1100','4100',v_key,v_department);
  insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
    values(v_folio.organization_id,v_folio.property_id,p_folio_id,'extra',btrim(p_description),v_date,p_amount_kobo,p_amount_kobo,auth.uid(),v_key,v_journal) returning id into v_item;
  return v_item;
end $$;

revoke all on function public.post_department_folio_charge(uuid,text,bigint,text,uuid) from public,anon;

grant execute on function public.post_department_folio_charge(uuid,text,bigint,text,uuid) to authenticated;

create or replace function public.post_folio_charge(p_folio_id uuid,p_description text,p_amount_kobo bigint,p_idempotency_key text)
returns uuid language sql security definer set search_path='' as $$
  select public.post_department_folio_charge(p_folio_id,p_description,p_amount_kobo,p_idempotency_key,null)
$$;

create or replace function public.post_department_expense(p_property_id uuid,p_expense_account_code text,p_description text,p_vendor text,p_amount_kobo bigint,p_payment_method_id uuid,p_idempotency_key text,p_department_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid;v_date date;v_department uuid;v_method public.payment_methods%rowtype;v_expense_account uuid;v_payment_account uuid;v_existing public.expenses%rowtype;v_existing_department uuid;v_id uuid:=gen_random_uuid();v_journal uuid;
begin
  select organization_id,(now() at time zone timezone)::date into v_org,v_date from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot post expenses for this property.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_description,''))) not between 2 and 500 or p_amount_kobo is null or p_amount_kobo<=0 or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter an expense description and positive amount.' using errcode='22023'; end if;
  select id into v_expense_account from public.accounts where organization_id=v_org and code=p_expense_account_code and account_type='expense' and active;
  if not found then raise exception 'Choose a valid expense category.' using errcode='22023'; end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_org and property_id=p_property_id and active;
  if not found then raise exception 'Choose a valid payment method.' using errcode='22023'; end if;
  select id into v_payment_account from public.accounts where organization_id=v_org and code=v_method.clearing_account_code and active;
  v_department:=p_department_id;
  if v_department is null then select id into v_department from public.departments where property_id=p_property_id and code='administration' and active; end if;
  if not exists(select 1 from public.departments where id=v_department and organization_id=v_org and property_id=p_property_id and active) then
    raise exception 'Choose an active department in this property.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_org::text||':expense:'||p_idempotency_key,0));
  select e.* into v_existing from public.expenses e join public.journals j on j.id=e.journal_id
    where j.organization_id=v_org and j.idempotency_key='expense:'||p_idempotency_key;
  select department_id into v_existing_department from public.journals where id=v_existing.journal_id;
  if v_existing.id is not null then
    if v_existing.property_id<>p_property_id or v_existing.amount_kobo<>p_amount_kobo or v_existing.description<>btrim(p_description)
      or v_existing.expense_account_id<>v_expense_account or v_existing.payment_account_id<>v_payment_account
      or (v_existing.payment_method_id is not null and v_existing.payment_method_id<>p_payment_method_id)
      or v_existing.vendor is distinct from nullif(btrim(p_vendor),'')
      or coalesce(v_existing_department,(select id from public.departments where property_id=p_property_id and code='administration'))<>v_department then
      raise exception 'Transaction reference was already used for a different expense.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  v_journal:=public.post_department_accounting_event(v_org,p_property_id,'expense',v_id,v_date,btrim(p_description),p_amount_kobo,p_expense_account_code,v_method.clearing_account_code,'expense:'||p_idempotency_key,v_department);
  insert into public.expenses(id,organization_id,property_id,expense_date,vendor,description,expense_account_id,payment_account_id,payment_method_id,amount_kobo,status,created_by,journal_id)
    values(v_id,v_org,p_property_id,v_date,nullif(btrim(p_vendor),''),btrim(p_description),v_expense_account,v_payment_account,p_payment_method_id,p_amount_kobo,'posted',auth.uid(),v_journal);
  return v_id;
end $$;

revoke all on function public.post_department_expense(uuid,text,text,text,bigint,uuid,text,uuid) from public,anon;

grant execute on function public.post_department_expense(uuid,text,text,text,bigint,uuid,text,uuid) to authenticated;

create or replace function public.post_categorized_expense(p_property_id uuid,p_expense_account_code text,p_description text,p_vendor text,p_amount_kobo bigint,p_payment_method_id uuid,p_idempotency_key text)
returns uuid language sql security definer set search_path='' as $$
  select public.post_department_expense(p_property_id,p_expense_account_code,p_description,p_vendor,p_amount_kobo,p_payment_method_id,p_idempotency_key,null)
$$;

create or replace function public.post_paid_expense(p_property_id uuid,p_description text,p_vendor text,p_amount_kobo bigint,p_payment_method_id uuid,p_idempotency_key text)
returns uuid language sql security definer set search_path='' as $$
  select public.post_department_expense(p_property_id,'5000',p_description,p_vendor,p_amount_kobo,p_payment_method_id,p_idempotency_key,null)
$$;

create or replace function public.get_department_profit_and_loss(p_property_id uuid,p_from date,p_to date)
returns table(department_code text,department_name text,revenue_kobo bigint,expense_kobo bigint,net_income_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a period of up to one year.' using errcode='22023'; end if;
  return query with amounts as(
    select coalesce(d.code,case j.source_type when 'room_night' then 'accommodation' when 'folio_extra' then 'services' when 'expense' then 'administration' else 'unallocated' end) as code,
      coalesce(d.name,case j.source_type when 'room_night' then 'Accommodation' when 'folio_extra' then 'Guest services' when 'expense' then 'Administration' else 'Unallocated historical entries' end) as name,
      case when a.account_type='revenue' then l.credit_kobo-l.debit_kobo else 0 end as revenue,
      case when a.account_type='expense' then l.debit_kobo-l.credit_kobo else 0 end as expense
    from public.journals j join public.journal_lines l on l.organization_id=j.organization_id and l.journal_id=j.id
      join public.accounts a on a.organization_id=l.organization_id and a.id=l.account_id
      left join public.departments d on d.id=j.department_id
    where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date between p_from and p_to and a.account_type in ('revenue','expense'))
    select x.code,x.name,sum(x.revenue)::bigint,sum(x.expense)::bigint,sum(x.revenue-x.expense)::bigint from amounts x group by x.code,x.name order by x.code;
end $$;

revoke all on function public.get_department_profit_and_loss(uuid,date,date) from public,anon;

grant execute on function public.get_department_profit_and_loss(uuid,date,date) to authenticated;



-- Finance audit records follow the same property boundary as the ledger.
drop policy if exists audit_read on public.audit_events;

drop policy if exists audit_read on public.audit_events;
create policy audit_read on public.audit_events for select to authenticated using(
  public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[])
  and (property_id is null or public.can_access_property(organization_id,property_id)));