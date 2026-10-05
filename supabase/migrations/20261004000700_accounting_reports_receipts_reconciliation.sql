-- Historical financial reports, receipt storage, and balance-based cash reconciliation.

alter table public.expenses add column if not exists receipt_path text;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('expense-receipts','expense-receipts',false,10485760,array['image/jpeg','image/png','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['image/jpeg','image/png','application/pdf'];

drop policy if exists expense_receipts_read on storage.objects;
create policy expense_receipts_read on storage.objects for select to authenticated using (
  bucket_id='expense-receipts'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and public.can_access_property((storage.foldername(name))[1]::uuid,(storage.foldername(name))[2]::uuid)
  and public.has_org_role((storage.foldername(name))[1]::uuid,array['owner','manager','accountant']::public.member_role[])
);
drop policy if exists expense_receipts_upload on storage.objects;
create policy expense_receipts_upload on storage.objects for insert to authenticated with check (
  bucket_id='expense-receipts'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and public.can_access_property((storage.foldername(name))[1]::uuid,(storage.foldername(name))[2]::uuid)
  and public.has_org_role((storage.foldername(name))[1]::uuid,array['owner','manager','accountant']::public.member_role[])
);

create or replace function public.attach_expense_receipt(p_expense_id uuid,p_storage_path text)
returns void language plpgsql security definer set search_path='' as $$
declare v_exp public.expenses%rowtype;
begin
  select * into v_exp from public.expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_exp.organization_id,array['owner','manager','accountant']::public.member_role[])
    or not public.can_access_property(v_exp.organization_id,v_exp.property_id) then raise exception 'You cannot attach a receipt to this expense.' using errcode='42501'; end if;
  if p_storage_path !~ ('^'||v_exp.organization_id::text||'/'||v_exp.property_id::text||'/'||v_exp.id::text||'/[^/]+$') then
    raise exception 'Receipt path does not match this expense.' using errcode='22023'; end if;
  if not exists(select 1 from storage.objects where bucket_id='expense-receipts' and name=p_storage_path) then raise exception 'Upload the receipt before linking it.' using errcode='P0002'; end if;
  update public.expenses set receipt_path=p_storage_path where id=v_exp.id;
end $$;
revoke all on function public.attach_expense_receipt(uuid,text) from public,anon;
grant execute on function public.attach_expense_receipt(uuid,text) to authenticated;

create or replace function public.get_profit_and_loss(p_property_id uuid,p_from date,p_to date)
returns table(account_code text,account_name text,account_type text,amount_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to one year.' using errcode='22023'; end if;
  return query select a.code,a.name,a.account_type,
    sum(case when a.account_type='revenue' then l.credit_kobo-l.debit_kobo else l.debit_kobo-l.credit_kobo end)::bigint
  from public.journal_lines l join public.journals j on j.organization_id=l.organization_id and j.id=l.journal_id
    join public.accounts a on a.organization_id=l.organization_id and a.id=l.account_id
  where j.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date between p_from and p_to
    and a.account_type in ('revenue','expense')
  group by a.code,a.name,a.account_type having sum(l.debit_kobo+l.credit_kobo)>0 order by a.account_type,a.code;
end $$;
revoke all on function public.get_profit_and_loss(uuid,date,date) from public,anon;
grant execute on function public.get_profit_and_loss(uuid,date,date) to authenticated;

create or replace function public.get_trial_balance(p_property_id uuid,p_as_of date)
returns table(account_code text,account_name text,account_type text,debit_balance_kobo bigint,credit_balance_kobo bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot view this property’s accounts.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select a.code,a.name,a.account_type,
    greatest(sum(l.debit_kobo-l.credit_kobo),0)::bigint,greatest(sum(l.credit_kobo-l.debit_kobo),0)::bigint
  from public.accounts a join public.journal_lines l on l.organization_id=a.organization_id and l.account_id=a.id
    join public.journals j on j.organization_id=l.organization_id and j.id=l.journal_id
  where a.organization_id=v_org and j.property_id=p_property_id and j.status='posted' and j.journal_date<=p_as_of
  group by a.code,a.name,a.account_type having sum(l.debit_kobo+l.credit_kobo)>0 order by a.code;
end $$;
revoke all on function public.get_trial_balance(uuid,date) from public,anon;
grant execute on function public.get_trial_balance(uuid,date) to authenticated;

create table if not exists public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  payment_method_id uuid not null,period_from date not null,period_to date not null,
  opening_balance_kobo bigint not null,statement_balance_kobo bigint not null,
  book_balance_kobo bigint not null,difference_kobo bigint not null,
  status text not null default 'open' check(status in ('open','reconciled')),
  created_by uuid references auth.users,created_at timestamptz not null default now(),reconciled_at timestamptz,
  foreign key (organization_id,property_id) references public.properties(organization_id,id),
  foreign key (organization_id,payment_method_id) references public.payment_methods(organization_id,id),
  check(period_to>=period_from), unique(organization_id,property_id,payment_method_id,period_from,period_to)
);
alter table public.bank_reconciliations enable row level security;
drop policy if exists bank_reconciliations_read on public.bank_reconciliations;
create policy bank_reconciliations_read on public.bank_reconciliations for select to authenticated using (
  public.can_access_property(organization_id,property_id)
  and public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[])
);

create or replace function public.create_bank_reconciliation(
  p_property_id uuid,p_payment_method_id uuid,p_from date,p_to date,p_opening_balance_kobo bigint,p_statement_balance_kobo bigint
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid; v_code text; v_account uuid; v_book bigint; v_id uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'Only an owner or accountant can start a reconciliation.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 or p_opening_balance_kobo<0 or p_statement_balance_kobo<0 then
    raise exception 'Enter a valid reconciliation period and balances.' using errcode='22023'; end if;
  select clearing_account_code into v_code from public.payment_methods where id=p_payment_method_id and organization_id=v_org and property_id=p_property_id and active;
  if not found then raise exception 'Choose an active payment method for this property.' using errcode='22023'; end if;
  select id into v_account from public.accounts where organization_id=v_org and code=v_code and active;
  select coalesce(sum(l.debit_kobo-l.credit_kobo),0)::bigint into v_book from public.journal_lines l
    join public.journals j on j.organization_id=l.organization_id and j.id=l.journal_id
    where l.organization_id=v_org and l.property_id=p_property_id and l.account_id=v_account and j.status='posted' and j.journal_date between p_from and p_to;
  v_book:=p_opening_balance_kobo+v_book;
  insert into public.bank_reconciliations(organization_id,property_id,payment_method_id,period_from,period_to,opening_balance_kobo,statement_balance_kobo,book_balance_kobo,difference_kobo,created_by)
    values(v_org,p_property_id,p_payment_method_id,p_from,p_to,p_opening_balance_kobo,p_statement_balance_kobo,v_book,p_statement_balance_kobo-v_book,auth.uid())
    on conflict(organization_id,property_id,payment_method_id,period_from,period_to) do update set
      opening_balance_kobo=excluded.opening_balance_kobo,statement_balance_kobo=excluded.statement_balance_kobo,
      book_balance_kobo=excluded.book_balance_kobo,difference_kobo=excluded.difference_kobo,status='open',reconciled_at=null
    where public.bank_reconciliations.status='open' returning id into v_id;
  if v_id is null then raise exception 'This period is already reconciled.' using errcode='23514'; end if;
  return v_id;
end $$;
revoke all on function public.create_bank_reconciliation(uuid,uuid,date,date,bigint,bigint) from public,anon;
grant execute on function public.create_bank_reconciliation(uuid,uuid,date,date,bigint,bigint) to authenticated;

create or replace function public.refresh_bank_reconciliation(p_reconciliation_id uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare v public.bank_reconciliations%rowtype; v_code text; v_account uuid; v_movement bigint; v_difference bigint;
begin
  select * into v from public.bank_reconciliations where id=p_reconciliation_id for update;
  if not found then raise exception 'Reconciliation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) or not public.can_access_property(v.organization_id,v.property_id) then
    raise exception 'Only an owner or accountant can refresh a reconciliation.' using errcode='42501'; end if;
  if v.status<>'open' then raise exception 'This reconciliation is already complete.' using errcode='23514'; end if;
  select clearing_account_code into v_code from public.payment_methods where id=v.payment_method_id and organization_id=v.organization_id;
  select id into v_account from public.accounts where organization_id=v.organization_id and code=v_code and active;
  if v_account is null then raise exception 'The payment account is unavailable.' using errcode='23514'; end if;
  select coalesce(sum(l.debit_kobo-l.credit_kobo),0)::bigint into v_movement from public.journal_lines l
    join public.journals j on j.organization_id=l.organization_id and j.id=l.journal_id
    where l.organization_id=v.organization_id and l.property_id=v.property_id and l.account_id=v_account and j.status='posted' and j.journal_date between v.period_from and v.period_to;
  v_difference:=v.statement_balance_kobo-(v.opening_balance_kobo+v_movement);
  update public.bank_reconciliations set book_balance_kobo=v.opening_balance_kobo+v_movement,difference_kobo=v_difference where id=v.id;
  return v_difference;
end $$;
revoke all on function public.refresh_bank_reconciliation(uuid) from public,anon;
grant execute on function public.refresh_bank_reconciliation(uuid) to authenticated;

create or replace function public.complete_bank_reconciliation(p_reconciliation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v public.bank_reconciliations%rowtype;
begin
  select * into v from public.bank_reconciliations where id=p_reconciliation_id for update;
  if not found then raise exception 'Reconciliation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) or not public.can_access_property(v.organization_id,v.property_id) then
    raise exception 'Only an owner or accountant can complete a reconciliation.' using errcode='42501'; end if;
  if v.status<>'open' or v.difference_kobo<>0 then raise exception 'Statement and book balances must match before completing.' using errcode='23514'; end if;
  update public.bank_reconciliations set status='reconciled',reconciled_at=now() where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'bank_reconciliation_completed','bank_reconciliation',v.id,
      jsonb_build_object('period_from',v.period_from,'period_to',v.period_to,'statement_balance_kobo',v.statement_balance_kobo));
end $$;
revoke all on function public.complete_bank_reconciliation(uuid) from public,anon;
grant execute on function public.complete_bank_reconciliation(uuid) to authenticated;

insert into public.accounts(organization_id,code,name,account_type)
select o.id,c.code,c.name,'expense' from public.organizations o cross join (values
  ('5010','Utilities'),('5020','Repairs and maintenance'),('5030','Staff costs'),
  ('5040','Guest and housekeeping supplies'),('5050','Food and beverage'),
  ('5060','Transport and logistics'),('5070','Sales and marketing'),('5090','Other operating expenses')
) c(code,name) on conflict(organization_id,code) do nothing;

create or replace function public.post_categorized_expense(
  p_property_id uuid,p_expense_account_code text,p_description text,p_vendor text,
  p_amount_kobo bigint,p_payment_method_id uuid,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid; v_date date; v_method public.payment_methods%rowtype; v_expense uuid;
  v_expense_account uuid; v_payment_account uuid; v_journal uuid; v_existing uuid;
  v_existing_property uuid; v_existing_amount bigint; v_existing_description text; v_existing_account uuid;
begin
  select organization_id,(now() at time zone timezone)::date into v_org,v_date from public.properties where id=p_property_id;
  if not found or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot post expenses for this property.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_description,'')))<2 or p_amount_kobo is null or p_amount_kobo<=0 or length(coalesce(p_idempotency_key,''))<8 then raise exception 'Enter an expense description and positive amount.' using errcode='22023'; end if;
  select id into v_expense_account from public.accounts where organization_id=v_org and code=p_expense_account_code and account_type='expense' and active;
  if not found then raise exception 'Choose a valid expense category.' using errcode='22023'; end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_org and property_id=p_property_id and active;
  if not found then raise exception 'Choose a valid payment method.' using errcode='22023'; end if;
  select e.id,e.property_id,e.amount_kobo,e.description,e.expense_account_id
    into v_existing,v_existing_property,v_existing_amount,v_existing_description,v_existing_account
    from public.journals j join public.expenses e on e.id=j.source_id
    where j.organization_id=v_org and j.idempotency_key='expense:'||p_idempotency_key;
  if v_existing is not null then
    if v_existing_property<>p_property_id or v_existing_amount<>p_amount_kobo or v_existing_description<>btrim(p_description) or v_existing_account<>v_expense_account then
      raise exception 'Transaction key was already used for a different expense.' using errcode='23505'; end if;
    return v_existing;
  end if;
  select id into v_payment_account from public.accounts where organization_id=v_org and code=v_method.clearing_account_code and active;
  insert into public.expenses(organization_id,property_id,expense_date,vendor,description,expense_account_id,payment_account_id,amount_kobo,status,created_by)
    values(v_org,p_property_id,v_date,nullif(btrim(p_vendor),''),btrim(p_description),v_expense_account,v_payment_account,p_amount_kobo,'posted',auth.uid()) returning id into v_expense;
  v_journal:=public.post_accounting_event(v_org,p_property_id,'expense',v_expense,v_date,btrim(p_description),p_amount_kobo,p_expense_account_code,v_method.clearing_account_code,'expense:'||p_idempotency_key);
  update public.expenses set journal_id=v_journal where id=v_expense;
  return v_expense;
end $$;
revoke all on function public.post_categorized_expense(uuid,text,text,text,bigint,uuid,text) from public,anon;
grant execute on function public.post_categorized_expense(uuid,text,text,text,bigint,uuid,text) to authenticated;

create or replace function public.seed_expense_categories() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.accounts(organization_id,code,name,account_type) values
    (new.id,'5010','Utilities','expense'),(new.id,'5020','Repairs and maintenance','expense'),
    (new.id,'5030','Staff costs','expense'),(new.id,'5040','Guest and housekeeping supplies','expense'),
    (new.id,'5050','Food and beverage','expense'),(new.id,'5060','Transport and logistics','expense'),
    (new.id,'5070','Sales and marketing','expense'),(new.id,'5090','Other operating expenses','expense')
    on conflict(organization_id,code) do nothing;
  return new;
end $$;
drop trigger if exists seed_expense_categories_on_org on public.organizations;
create trigger seed_expense_categories_on_org after insert on public.organizations for each row execute function public.seed_expense_categories();

grant select on public.bank_reconciliations to authenticated;
grant usage on schema storage to authenticated;
grant select,insert on storage.objects to authenticated;
