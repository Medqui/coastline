-- Supplier subledger: accrual bills, partial settlement and linked corrections.
insert into public.accounts(organization_id,code,name,account_type)
  select id,'2000','Supplier payables','liability' from public.organizations on conflict(organization_id,code) do nothing;

create or replace function public.seed_supplier_payable_account() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.accounts(organization_id,code,name,account_type) values(new.id,'2000','Supplier payables','liability') on conflict(organization_id,code) do nothing;return new;end $$;

revoke all on function public.seed_supplier_payable_account() from public,anon,authenticated;

drop trigger if exists seed_supplier_payable_on_org on public.organizations;
create trigger seed_supplier_payable_on_org after insert on public.organizations for each row execute function public.seed_supplier_payable_account();

create table if not exists public.suppliers(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  name text not null check(length(name) between 2 and 120),phone text,email text,address text,active boolean not null default true,
  created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),unique(organization_id,property_id,id)
);

create unique index if not exists supplier_name_unique on public.suppliers(property_id,lower(name));

create table if not exists public.supplier_bills(
  id uuid primary key,organization_id uuid not null,property_id uuid not null,supplier_id uuid not null,bill_number text not null,
  invoice_date date not null,posting_date date not null,due_date date not null,description text not null,
  debit_account_id uuid not null,department_id uuid not null,amount_kobo bigint not null check(amount_kobo>0),
  journal_id uuid not null,status text not null default 'posted' check(status in ('posted','void')),
  receipt_path text,idempotency_key text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  voided_by uuid references auth.users,voided_at timestamptz,void_reason text,reversal_journal_id uuid,
  foreign key(organization_id,property_id,supplier_id) references public.suppliers(organization_id,property_id,id),
  foreign key(organization_id,debit_account_id) references public.accounts(organization_id,id),
  foreign key(organization_id,property_id,department_id) references public.departments(organization_id,property_id,id),
  foreign key(organization_id,property_id,journal_id) references public.journals(organization_id,property_id,id),
  foreign key(organization_id,property_id,reversal_journal_id) references public.journals(organization_id,property_id,id),
  unique(organization_id,idempotency_key),unique(organization_id,property_id,id),
  check(due_date>=invoice_date and posting_date>=invoice_date),
  check((status='void' and voided_by is not null and voided_at is not null and reversal_journal_id is not null and void_reason is not null and length(void_reason)>=5) or (status='posted' and voided_by is null and voided_at is null and reversal_journal_id is null and void_reason is null))
);

create unique index if not exists supplier_bill_number_unique on public.supplier_bills(supplier_id,bill_number) where status='posted';

create table if not exists public.supplier_bill_payments(
  id uuid primary key,organization_id uuid not null,property_id uuid not null,bill_id uuid not null,payment_method_id uuid not null,
  payment_date date not null,amount_kobo bigint not null check(amount_kobo>0),reference text,journal_id uuid not null,
  idempotency_key text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  status text not null default 'posted' check(status in ('posted','reversed')),reversed_by uuid references auth.users,
  reversed_at timestamptz,reversal_reason text,reversal_journal_id uuid,
  foreign key(organization_id,property_id,bill_id) references public.supplier_bills(organization_id,property_id,id),
  foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id),
  foreign key(organization_id,property_id,journal_id) references public.journals(organization_id,property_id,id),
  foreign key(organization_id,property_id,reversal_journal_id) references public.journals(organization_id,property_id,id),
  unique(organization_id,idempotency_key),
  check((status='reversed' and reversed_by is not null and reversed_at is not null and reversal_journal_id is not null and reversal_reason is not null and length(reversal_reason)>=5) or (status='posted' and reversed_by is null and reversed_at is null and reversal_journal_id is null and reversal_reason is null))
);

do $$ declare t text;begin
  foreach t in array array['suppliers','supplier_bills','supplier_bill_payments'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists finance_read on public.%I',t);
    execute format('create policy finance_read on public.%I for select to authenticated using(public.can_access_property(organization_id,property_id) and public.has_org_role(organization_id,array[''owner'',''manager'',''accountant'']::public.member_role[]))',t);
    execute format('grant select on public.%I to authenticated',t);
  end loop;
end $$;

create or replace function public.save_supplier(p_property_id uuid,p_supplier_id uuid,p_name text,p_phone text,p_email text,p_address text,p_active boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid;v_id uuid;v_before jsonb;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot manage suppliers for this property.' using errcode='42501'; end if;
  if coalesce(length(btrim(p_name)),0) not between 2 and 120 or p_active is null or coalesce(length(p_phone),0)>80
    or coalesce(length(p_email),0)>254 or coalesce(length(p_address),0)>500 then raise exception 'Enter a supplier name and valid contact details.' using errcode='22023'; end if;
  if p_supplier_id is null then
    insert into public.suppliers(organization_id,property_id,name,phone,email,address,active,created_by)
      values(v_org,p_property_id,btrim(p_name),nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),nullif(btrim(p_address),''),p_active,auth.uid()) returning id into v_id;
  else
    select to_jsonb(s) into v_before from public.suppliers s where id=p_supplier_id and organization_id=v_org and property_id=p_property_id for update;
    if not found then raise exception 'Choose a supplier in this property.' using errcode='22023'; end if;
    update public.suppliers set name=btrim(p_name),phone=nullif(btrim(p_phone),''),email=nullif(lower(btrim(p_email)),''),address=nullif(btrim(p_address),''),active=p_active where id=p_supplier_id returning id into v_id;
  end if;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v_org,p_property_id,auth.uid(),'supplier_saved','supplier',v_id,v_before,jsonb_build_object('name',btrim(p_name),'active',p_active));
  return v_id;
exception when unique_violation then raise exception 'A supplier with this name already exists in the property.' using errcode='23505';
end $$;

revoke all on function public.save_supplier(uuid,uuid,text,text,text,text,boolean) from public,anon;

grant execute on function public.save_supplier(uuid,uuid,text,text,text,text,boolean) to authenticated;

create or replace function public.post_supplier_bill(p_property_id uuid,p_supplier_id uuid,p_bill_number text,p_invoice_date date,p_posting_date date,p_due_date date,
  p_description text,p_account_code text,p_department_id uuid,p_amount_kobo bigint,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_org uuid;v_today date;v_account uuid;v_bill public.supplier_bills%rowtype;v_id uuid:=gen_random_uuid();v_journal uuid;v_number text:=upper(btrim(p_bill_number));
begin
  select organization_id,(now() at time zone timezone)::date into v_org,v_today from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot record bills for this property.' using errcode='42501'; end if;
  if coalesce(length(v_number),0) not between 1 and 80 or p_invoice_date is null or p_posting_date is null or p_due_date is null
    or p_posting_date<p_invoice_date or p_posting_date>v_today or p_due_date<p_invoice_date or p_amount_kobo is null or p_amount_kobo<=0
    or coalesce(length(btrim(p_description)),0) not between 2 and 500 or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter valid invoice dates, a description, positive amount and transaction reference.' using errcode='22023'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id and organization_id=v_org and property_id=p_property_id and active) then
    raise exception 'Choose an active supplier in this property.' using errcode='22023'; end if;
  if not exists(select 1 from public.departments where id=p_department_id and organization_id=v_org and property_id=p_property_id and active) then
    raise exception 'Choose an active department in this property.' using errcode='22023'; end if;
  select id into v_account from public.accounts where organization_id=v_org and code=p_account_code and account_type='expense' and active;
  if not found then raise exception 'Choose an expense category.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_org::text||':supplier-bill:'||p_idempotency_key,0));
  select * into v_bill from public.supplier_bills where organization_id=v_org and idempotency_key=p_idempotency_key;
  if found then
    if v_bill.property_id<>p_property_id or v_bill.supplier_id<>p_supplier_id or v_bill.bill_number<>v_number or v_bill.invoice_date<>p_invoice_date
      or v_bill.posting_date<>p_posting_date or v_bill.due_date<>p_due_date or v_bill.description<>btrim(p_description) or v_bill.debit_account_id<>v_account
      or v_bill.department_id<>p_department_id or v_bill.amount_kobo<>p_amount_kobo then
      raise exception 'Transaction reference was already used for a different bill.' using errcode='23505'; end if;
    return v_bill.id;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_supplier_id::text||':invoice:'||v_number,0));
  if exists(select 1 from public.supplier_bills where supplier_id=p_supplier_id and bill_number=v_number and status='posted') then
    raise exception 'This supplier invoice has already been recorded.' using errcode='23505'; end if;
  v_journal:=public.post_department_accounting_event(v_org,p_property_id,'supplier_bill',v_id,p_posting_date,btrim(p_description),p_amount_kobo,p_account_code,'2000','supplier-bill:'||p_idempotency_key,p_department_id);
  insert into public.supplier_bills(id,organization_id,property_id,supplier_id,bill_number,invoice_date,posting_date,due_date,description,debit_account_id,department_id,amount_kobo,journal_id,idempotency_key,created_by)
    values(v_id,v_org,p_property_id,p_supplier_id,v_number,p_invoice_date,p_posting_date,p_due_date,btrim(p_description),v_account,p_department_id,p_amount_kobo,v_journal,p_idempotency_key,auth.uid());
  return v_id;
end $$;

revoke all on function public.post_supplier_bill(uuid,uuid,text,date,date,date,text,text,uuid,bigint,text) from public,anon;

grant execute on function public.post_supplier_bill(uuid,uuid,text,date,date,date,text,text,uuid,bigint,text) to authenticated;

create or replace function public.pay_supplier_bill(p_bill_id uuid,p_payment_method_id uuid,p_payment_date date,p_amount_kobo bigint,p_reference text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_bill public.supplier_bills%rowtype;v_method public.payment_methods%rowtype;v_existing public.supplier_bill_payments%rowtype;v_today date;v_max_paid bigint;v_id uuid:=gen_random_uuid();v_journal uuid;
begin
  select * into v_bill from public.supplier_bills where id=p_bill_id;
  if not found or not public.can_access_property(v_bill.organization_id,v_bill.property_id) or not public.has_org_role(v_bill.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can pay this supplier bill.' using errcode='42501'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_bill.property_id;
  if p_payment_date is null or p_payment_date<v_bill.posting_date or p_payment_date>v_today or p_amount_kobo is null or p_amount_kobo<=0
    or coalesce(length(p_idempotency_key),0) not between 8 and 200 or coalesce(length(p_reference),0)>200 then
    raise exception 'Enter a valid payment date, positive amount and transaction reference.' using errcode='22023'; end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_bill.organization_id and property_id=v_bill.property_id and active;
  if not found then raise exception 'Choose a payment method in this property.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_bill.organization_id::text||':supplier-payment:'||p_idempotency_key,0));
  select * into v_bill from public.supplier_bills where id=p_bill_id for update;
  select * into v_existing from public.supplier_bill_payments where organization_id=v_bill.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.bill_id<>p_bill_id or v_existing.payment_method_id<>p_payment_method_id or v_existing.payment_date<>p_payment_date
      or v_existing.amount_kobo<>p_amount_kobo or v_existing.reference is distinct from nullif(btrim(p_reference),'') then
      raise exception 'Transaction reference was already used for a different supplier payment.' using errcode='23505'; end if;
    return v_existing.id;
  end if;
  if v_bill.status<>'posted' then raise exception 'This bill is void.' using errcode='23514'; end if;
  -- Check the entire dated history, including reversals, so backdating cannot overpay an earlier period.
  with events as(
    select payment_date as day,amount_kobo as amount from public.supplier_bill_payments where bill_id=v_bill.id
    union all select j.journal_date,-p.amount_kobo from public.supplier_bill_payments p join public.journals j on j.id=p.reversal_journal_id where p.bill_id=v_bill.id and p.status='reversed'
    union all select p_payment_date,p_amount_kobo),daily as(select day,sum(amount) as amount from events group by day),running as(select sum(amount) over(order by day) as paid from daily)
    select coalesce(max(paid),0)::bigint into v_max_paid from running;
  if v_max_paid>v_bill.amount_kobo then raise exception 'This payment would exceed the unpaid bill balance in its dated history.' using errcode='23514'; end if;
  v_journal:=public.post_department_accounting_event(v_bill.organization_id,v_bill.property_id,'supplier_payment',v_id,p_payment_date,'Supplier payment · '||v_bill.bill_number,
    p_amount_kobo,'2000',v_method.clearing_account_code,'supplier-payment:'||p_idempotency_key,v_bill.department_id);
  insert into public.supplier_bill_payments(id,organization_id,property_id,bill_id,payment_method_id,payment_date,amount_kobo,reference,journal_id,idempotency_key,created_by)
    values(v_id,v_bill.organization_id,v_bill.property_id,v_bill.id,p_payment_method_id,p_payment_date,p_amount_kobo,nullif(btrim(p_reference),''),v_journal,p_idempotency_key,auth.uid());
  return v_id;
end $$;

revoke all on function public.pay_supplier_bill(uuid,uuid,date,bigint,text,text) from public,anon;

grant execute on function public.pay_supplier_bill(uuid,uuid,date,bigint,text,text) to authenticated;

create or replace function public.reverse_supplier_payment(p_payment_id uuid,p_date date,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v public.supplier_bill_payments%rowtype;v_bill public.supplier_bills%rowtype;v_today date;v_cash_code text;v_journal uuid;
begin
  select * into v from public.supplier_bill_payments where id=p_payment_id;
  if not found or not public.can_access_property(v.organization_id,v.property_id) or not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can reverse this supplier payment.' using errcode='42501'; end if;
  select * into v_bill from public.supplier_bills where id=v.bill_id for update;
  select * into v from public.supplier_bill_payments where id=p_payment_id for update;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v.property_id;
  if p_date is null or p_date<v.payment_date or p_date>v_today or coalesce(length(btrim(p_reason)),0) not between 5 and 500 then
    raise exception 'Enter a valid correction date and a reason between 5 and 500 characters.' using errcode='22023'; end if;
  if v.status='reversed' then
    if v.reversal_reason<>btrim(p_reason) or (select journal_date from public.journals where id=v.reversal_journal_id)<>p_date then
      raise exception 'This payment was already reversed with different correction details.' using errcode='23505'; end if;
    return v.reversal_journal_id;
  end if;
  select a.code into v_cash_code from public.journal_lines l join public.accounts a on a.id=l.account_id where l.journal_id=v.journal_id and l.credit_kobo>0;
  v_journal:=public.post_department_accounting_event(v.organization_id,v.property_id,'supplier_payment_reversal',v.id,p_date,btrim(p_reason),v.amount_kobo,v_cash_code,'2000','supplier-payment-reversal:'||v.id::text,v_bill.department_id,v.journal_id);
  update public.supplier_bill_payments set status='reversed',reversed_by=auth.uid(),reversed_at=now(),reversal_reason=btrim(p_reason),reversal_journal_id=v_journal where id=v.id;
  return v_journal;
end $$;

revoke all on function public.reverse_supplier_payment(uuid,date,text) from public,anon;

grant execute on function public.reverse_supplier_payment(uuid,date,text) to authenticated;

create or replace function public.void_supplier_bill(p_bill_id uuid,p_date date,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v public.supplier_bills%rowtype;v_today date;v_last date;v_code text;v_journal uuid;
begin
  select * into v from public.supplier_bills where id=p_bill_id;
  if not found or not public.can_access_property(v.organization_id,v.property_id) or not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can void this supplier bill.' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v.supplier_id::text||':invoice:'||v.bill_number,0));
  select * into v from public.supplier_bills where id=p_bill_id for update;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v.property_id;
  select max(j.journal_date) into v_last from public.supplier_bill_payments p join public.journals j on j.id=p.reversal_journal_id where p.bill_id=v.id;
  if p_date is null or p_date<greatest(v.posting_date,coalesce(v_last,v.posting_date)) or p_date>v_today or coalesce(length(btrim(p_reason)),0) not between 5 and 500 then
    raise exception 'Enter a correction date after the bill activity and a reason between 5 and 500 characters.' using errcode='22023'; end if;
  if v.status='void' then
    if v.void_reason<>btrim(p_reason) or (select journal_date from public.journals where id=v.reversal_journal_id)<>p_date then raise exception 'This bill was already voided with different details.' using errcode='23505'; end if;
    return v.reversal_journal_id;
  end if;
  if exists(select 1 from public.supplier_bill_payments where bill_id=v.id and status='posted') then
    raise exception 'Reverse recorded payments before voiding this bill.' using errcode='23514'; end if;
  select code into v_code from public.accounts where id=v.debit_account_id;
  v_journal:=public.post_department_accounting_event(v.organization_id,v.property_id,'supplier_bill_void',v.id,p_date,btrim(p_reason),v.amount_kobo,'2000',v_code,'supplier-bill-void:'||v.id::text,v.department_id,v.journal_id);
  update public.supplier_bills set status='void',voided_by=auth.uid(),voided_at=now(),void_reason=btrim(p_reason),reversal_journal_id=v_journal where id=v.id;
  return v_journal;
end $$;

revoke all on function public.void_supplier_bill(uuid,date,text) from public,anon;

grant execute on function public.void_supplier_bill(uuid,date,text) to authenticated;

create or replace function public.guard_supplier_financial_record() returns trigger language plpgsql set search_path='' as $$
declare v_fields text[];
begin
  if tg_op='DELETE' then raise exception 'Supplier financial records cannot be deleted.' using errcode='23514'; end if;
  v_fields:=case when tg_table_name='supplier_bills' then array['status','voided_by','voided_at','void_reason','reversal_journal_id','receipt_path']
    else array['status','reversed_by','reversed_at','reversal_reason','reversal_journal_id'] end;
  if (new.status=old.status and to_jsonb(new)-case when tg_table_name='supplier_bills' then array['receipt_path'] else array[]::text[] end <> to_jsonb(old)-case when tg_table_name='supplier_bills' then array['receipt_path'] else array[]::text[] end)
    or to_jsonb(new)-v_fields<>to_jsonb(old)-v_fields or (old.status<>new.status and old.status<>'posted') then
    raise exception 'Posted supplier financial facts are immutable.' using errcode='23514'; end if;
  return new;
end $$;

drop trigger if exists supplier_bill_immutable on public.supplier_bills;
create trigger supplier_bill_immutable before update or delete on public.supplier_bills for each row execute function public.guard_supplier_financial_record();

drop trigger if exists supplier_payment_immutable on public.supplier_bill_payments;
create trigger supplier_payment_immutable before update or delete on public.supplier_bill_payments for each row execute function public.guard_supplier_financial_record();

revoke all on function public.guard_supplier_financial_record() from public,anon,authenticated;

create or replace function public.attach_supplier_bill_receipt(p_bill_id uuid,p_storage_path text)
returns void language plpgsql security definer set search_path='' as $$
declare v public.supplier_bills%rowtype;
begin
  select * into v from public.supplier_bills where id=p_bill_id for update;
  if not found or not public.can_access_property(v.organization_id,v.property_id) or not public.has_org_role(v.organization_id,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot attach a receipt to this bill.' using errcode='42501'; end if;
  if p_storage_path is null or p_storage_path !~ ('^'||v.organization_id::text||'/'||v.property_id::text||'/'||v.id::text||'/[^/]+$') then
    raise exception 'The receipt path does not match this bill.' using errcode='22023'; end if;
  if not exists(select 1 from storage.objects where bucket_id='expense-receipts' and name=p_storage_path) then raise exception 'Upload the receipt before linking it.' using errcode='P0002'; end if;
  update public.supplier_bills set receipt_path=p_storage_path where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'supplier_bill_receipt_attached','supplier_bill',v.id,
      jsonb_build_object('receipt_path',v.receipt_path),jsonb_build_object('receipt_path',p_storage_path));
end $$;

revoke all on function public.attach_supplier_bill_receipt(uuid,text) from public,anon;

grant execute on function public.attach_supplier_bill_receipt(uuid,text) to authenticated;

create or replace function public.get_supplier_bill_balances(p_property_id uuid,p_as_of date)
returns table(bill_id uuid,supplier_id uuid,supplier_name text,bill_number text,invoice_date date,posting_date date,due_date date,description text,amount_kobo bigint,paid_kobo bigint,outstanding_kobo bigint,status text,receipt_path text)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view supplier accounts for this property.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select b.id,s.id,s.name,b.bill_number,b.invoice_date,b.posting_date,b.due_date,b.description,b.amount_kobo,
    coalesce(p.paid,0)::bigint,case when j.journal_date<=p_as_of then 0 else b.amount_kobo-coalesce(p.paid,0) end::bigint,
    case when j.journal_date<=p_as_of then 'void' else 'posted' end,b.receipt_path
    from public.supplier_bills b join public.suppliers s on s.id=b.supplier_id
      left join public.journals j on j.id=b.reversal_journal_id
      left join lateral(select sum(x.amount_kobo)::bigint as paid from public.supplier_bill_payments x left join public.journals r on r.id=x.reversal_journal_id
        where x.bill_id=b.id and x.payment_date<=p_as_of and (r.journal_date is null or r.journal_date>p_as_of)) p on true
    where b.organization_id=v_org and b.property_id=p_property_id and b.posting_date<=p_as_of order by b.posting_date desc,b.id;
end $$;

revoke all on function public.get_supplier_bill_balances(uuid,date) from public,anon;

grant execute on function public.get_supplier_bill_balances(uuid,date) to authenticated;

create or replace function public.get_supplier_payables_summary(p_property_id uuid,p_as_of date)
returns table(outstanding_kobo bigint,current_kobo bigint,overdue_1_30_kobo bigint,overdue_31_60_kobo bigint,overdue_61_90_kobo bigint,overdue_90_plus_kobo bigint,unpaid_bills bigint)
language sql stable security definer set search_path='' as $$
  select coalesce(sum(b.outstanding_kobo),0)::bigint,
    coalesce(sum(b.outstanding_kobo) filter(where b.due_date>=p_as_of),0)::bigint,
    coalesce(sum(b.outstanding_kobo) filter(where p_as_of-b.due_date between 1 and 30),0)::bigint,
    coalesce(sum(b.outstanding_kobo) filter(where p_as_of-b.due_date between 31 and 60),0)::bigint,
    coalesce(sum(b.outstanding_kobo) filter(where p_as_of-b.due_date between 61 and 90),0)::bigint,
    coalesce(sum(b.outstanding_kobo) filter(where p_as_of-b.due_date>90),0)::bigint,
    count(*) filter(where b.outstanding_kobo>0)
  from public.get_supplier_bill_balances(p_property_id,p_as_of) b
$$;

revoke all on function public.get_supplier_payables_summary(uuid,date) from public,anon;

grant execute on function public.get_supplier_payables_summary(uuid,date) to authenticated;

create or replace function public.get_supplier_payment_history(p_property_id uuid,p_as_of date)
returns table(payment_id uuid,bill_id uuid,bill_number text,supplier_name text,payment_date date,amount_kobo bigint,method_name text,reference text,status text,reversal_date date,reversal_reason text)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.properties where id=p_property_id;
  if not found or not public.can_access_property(v_org,p_property_id) or not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view supplier payments for this property.' using errcode='42501'; end if;
  if p_as_of is null then raise exception 'Choose an as-of date.' using errcode='22023'; end if;
  return query select p.id,b.id,b.bill_number,s.name,p.payment_date,p.amount_kobo,m.name,p.reference,
    case when r.journal_date<=p_as_of then 'reversed' else 'posted' end,
    case when r.journal_date<=p_as_of then r.journal_date end,case when r.journal_date<=p_as_of then p.reversal_reason end
    from public.supplier_bill_payments p join public.supplier_bills b on b.id=p.bill_id join public.suppliers s on s.id=b.supplier_id
      join public.payment_methods m on m.id=p.payment_method_id left join public.journals r on r.id=p.reversal_journal_id
    where p.organization_id=v_org and p.property_id=p_property_id and p.payment_date<=p_as_of order by p.payment_date desc,p.created_at desc;
end $$;

revoke all on function public.get_supplier_payment_history(uuid,date) from public,anon;

grant execute on function public.get_supplier_payment_history(uuid,date) to authenticated;