-- Folio and accounting transactions. Run after the first two migrations.
alter table public.folio_items add column if not exists source_key text;
alter table public.folio_items add column if not exists journal_id uuid;
create unique index if not exists folio_items_source_key_uidx on public.folio_items(organization_id,source_key);
create unique index if not exists folios_one_per_reservation_uidx on public.folios(organization_id,reservation_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='folio_items_journal_tenant_fk') then
    alter table public.folio_items add constraint folio_items_journal_tenant_fk
      foreign key (organization_id,journal_id) references public.journals(organization_id,id);
  end if;
end $$;

create or replace function public.seed_finance_defaults() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='organizations' then
    insert into public.accounts(organization_id,code,name,account_type) values
      (new.id,'1000','Cash on hand','asset'),(new.id,'1010','Bank','asset'),
      (new.id,'1020','POS clearing','asset'),(new.id,'1100','Guest receivables','asset'),
      (new.id,'4000','Room revenue','revenue'),(new.id,'4100','Other guest revenue','revenue'),
      (new.id,'5000','Operating expenses','expense') on conflict (organization_id,code) do nothing;
  elsif tg_table_name='properties' then
    insert into public.payment_methods(organization_id,property_id,name,clearing_account_code) values
      (new.organization_id,new.id,'Cash','1000'),
      (new.organization_id,new.id,'Bank transfer','1010'),
      (new.organization_id,new.id,'POS / card','1020') on conflict (property_id,name) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists seed_finance_org on public.organizations;
create trigger seed_finance_org after insert on public.organizations for each row execute function public.seed_finance_defaults();
drop trigger if exists seed_finance_property on public.properties;
create trigger seed_finance_property after insert on public.properties for each row execute function public.seed_finance_defaults();
insert into public.accounts(organization_id,code,name,account_type)
select o.id,v.code,v.name,v.kind from public.organizations o cross join
  (values ('1000','Cash on hand','asset'),('1010','Bank','asset'),('1020','POS clearing','asset'),
   ('1100','Guest receivables','asset'),('4000','Room revenue','revenue'),
   ('4100','Other guest revenue','revenue'),('5000','Operating expenses','expense')) v(code,name,kind)
on conflict (organization_id,code) do nothing;
insert into public.payment_methods(organization_id,property_id,name,clearing_account_code)
select p.organization_id,p.id,v.name,v.code from public.properties p cross join
  (values ('Cash','1000'),('Bank transfer','1010'),('POS / card','1020')) v(name,code)
on conflict (property_id,name) do nothing;

-- A posted journal and its lines cannot be changed. Posting checks both sides in the same transaction.
create or replace function public.guard_journal() returns trigger language plpgsql set search_path='' as $$
declare v_debits bigint; v_credits bigint; v_count integer;
begin
  if tg_op='DELETE' then
    if old.status<>'draft' then raise exception 'Posted journals cannot be deleted.' using errcode='23514'; end if;
    return old;
  end if;
  if old.status<>'draft' then raise exception 'Posted journals are immutable.' using errcode='23514'; end if;
  if new.status='draft' then return new; end if;
  if new.status<>'posted' or new.posted_at is null or new.posted_by is null then
    raise exception 'A journal must be posted with actor and timestamp.' using errcode='23514';
  end if;
  select count(*),coalesce(sum(debit_kobo),0),coalesce(sum(credit_kobo),0)
    into v_count,v_debits,v_credits from public.journal_lines where organization_id=new.organization_id and journal_id=new.id;
  if v_count<2 or v_debits<>v_credits or v_debits<=0 then
    raise exception 'Journal debits and credits must balance.' using errcode='23514';
  end if;
  return new;
end $$;
drop trigger if exists guard_journal_changes on public.journals;
create trigger guard_journal_changes before update or delete on public.journals for each row execute function public.guard_journal();
create or replace function public.guard_journal_line() returns trigger language plpgsql set search_path='' as $$
declare v_status public.journal_status; v_org uuid; v_property uuid;
begin
  if tg_op='UPDATE' and (new.journal_id<>old.journal_id or new.organization_id<>old.organization_id) then
    raise exception 'Journal lines cannot move between journals.' using errcode='23514';
  end if;
  select status,organization_id,property_id into v_status,v_org,v_property from public.journals
    where id=coalesce(new.journal_id,old.journal_id) for update;
  if v_status<>'draft' then raise exception 'Posted journal lines are immutable.' using errcode='23514'; end if;
  if tg_op<>'DELETE' and (new.organization_id<>v_org or new.property_id<>v_property) then
    raise exception 'Journal line must belong to its journal property.' using errcode='23514';
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
drop trigger if exists guard_journal_line_changes on public.journal_lines;
create trigger guard_journal_line_changes before insert or update or delete on public.journal_lines
  for each row execute function public.guard_journal_line();

create or replace function public.post_accounting_event(
  p_org uuid,p_property uuid,p_source_type text,p_source_id uuid,p_date date,p_memo text,
  p_amount bigint,p_debit_code text,p_credit_code text,p_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_debit uuid; v_credit uuid; v_journal uuid;
begin
  if p_amount is null or p_amount<=0 or length(coalesce(p_key,''))<8 then
    raise exception 'Invalid accounting amount or transaction key.' using errcode='22023';
  end if;
  select id into v_debit from public.accounts where organization_id=p_org and code=p_debit_code and active;
  select id into v_credit from public.accounts where organization_id=p_org and code=p_credit_code and active;
  if v_debit is null or v_credit is null or v_debit=v_credit then
    raise exception 'Required accounting accounts are unavailable.' using errcode='23514';
  end if;
  insert into public.journals(organization_id,property_id,source_type,source_id,journal_date,memo,idempotency_key,created_by)
    values(p_org,p_property,p_source_type,p_source_id,p_date,p_memo,p_key,auth.uid()) returning id into v_journal;
  insert into public.journal_lines(organization_id,journal_id,property_id,account_id,description,debit_kobo,credit_kobo) values
    (p_org,v_journal,p_property,v_debit,p_memo,p_amount,0),
    (p_org,v_journal,p_property,v_credit,p_memo,0,p_amount);
  update public.journals set status='posted',posted_by=auth.uid(),posted_at=now() where id=v_journal;
  return v_journal;
end $$;
revoke all on function public.post_accounting_event(uuid,uuid,text,uuid,date,text,bigint,text,text,text) from public,anon,authenticated;

create or replace function public.post_due_room_nights(p_reservation_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_folio public.folios%rowtype;
  v_today date; v_night date; v_rate bigint; v_room text; v_key text; v_journal uuid; v_count integer:=0;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk','accountant']::public.member_role[])
     or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot post this reservation.' using errcode='42501'; end if;
  if v_res.status<>'checked_in' then raise exception 'Room nights can post only for an in-house stay.' using errcode='23514'; end if;
  select * into v_folio from public.folios where organization_id=v_res.organization_id and reservation_id=v_res.id for update;
  if not found or v_folio.status<>'open' then raise exception 'An open folio is required.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  select rr.nightly_rate_kobo,r.room_number into v_rate,v_room from public.reservation_rooms rr
    join public.rooms r on r.id=rr.room_id where rr.organization_id=v_res.organization_id and rr.reservation_id=v_res.id limit 1;
  if v_rate is null then raise exception 'No room assigned to this stay.' using errcode='23514'; end if;
  for v_night in select generate_series(v_res.arrival_date,least(v_today-1,v_res.departure_date-1),'1 day')::date loop
    v_key:='room:'||v_res.id::text||':'||v_night::text;
    if v_rate>0 and not exists(select 1 from public.folio_items where organization_id=v_res.organization_id and source_key=v_key) then
      v_journal:=public.post_accounting_event(v_res.organization_id,v_res.property_id,'room_night',v_res.id,v_night,
        'Room '||v_room||' · '||v_night,v_rate,'1100','4000',v_key);
      insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,
        unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
        values(v_res.organization_id,v_res.property_id,v_folio.id,'room_charge','Room '||v_room||' · '||v_night,
          v_night,v_rate,v_rate,auth.uid(),v_key,v_journal);
      v_count:=v_count+1;
    end if;
  end loop;
  return v_count;
end $$;

create or replace function public.post_folio_charge(p_folio_id uuid,p_description text,p_amount_kobo bigint,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_folio public.folios%rowtype; v_existing uuid; v_existing_folio uuid; v_existing_amount bigint;
  v_existing_description text; v_date date; v_item uuid; v_journal uuid; v_key text;
begin
  select * into v_folio from public.folios where id=p_folio_id for update;
  if not found then raise exception 'Folio not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_folio.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_folio.organization_id,v_folio.property_id) then
    raise exception 'You cannot charge this folio.' using errcode='42501'; end if;
  if v_folio.status<>'open' then raise exception 'Folio is closed.' using errcode='23514'; end if;
  if length(btrim(coalesce(p_description,'')))<2 or p_amount_kobo is null or p_amount_kobo<=0
    or length(coalesce(p_idempotency_key,''))<8 then raise exception 'Enter a description and positive amount.' using errcode='22023'; end if;
  v_key:='extra:'||p_idempotency_key;
  select id,folio_id,total_amount_kobo,description into v_existing,v_existing_folio,v_existing_amount,v_existing_description
    from public.folio_items where organization_id=v_folio.organization_id and source_key=v_key;
  if v_existing is not null then
    if v_existing_folio<>p_folio_id or v_existing_amount<>p_amount_kobo or v_existing_description<>btrim(p_description) then
      raise exception 'Transaction key was already used for a different charge.' using errcode='23505'; end if;
    return v_existing;
  end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_folio.property_id;
  v_journal:=public.post_accounting_event(v_folio.organization_id,v_folio.property_id,'folio_extra',p_folio_id,v_date,
    btrim(p_description),p_amount_kobo,'1100','4100',v_key);
  insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,
    unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
    values(v_folio.organization_id,v_folio.property_id,p_folio_id,'extra',btrim(p_description),v_date,
      p_amount_kobo,p_amount_kobo,auth.uid(),v_key,v_journal) returning id into v_item;
  return v_item;
end $$;

create or replace function public.record_folio_payment(p_folio_id uuid,p_payment_method_id uuid,p_amount_kobo bigint,
  p_reference text,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_folio public.folios%rowtype; v_method public.payment_methods%rowtype; v_balance bigint;
  v_existing uuid; v_existing_folio uuid; v_existing_method uuid; v_existing_amount bigint;
  v_payment uuid; v_date date; v_journal uuid; v_key text;
begin
  select * into v_folio from public.folios where id=p_folio_id for update;
  if not found then raise exception 'Folio not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_folio.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_folio.organization_id,v_folio.property_id) then
    raise exception 'You cannot collect payment for this folio.' using errcode='42501'; end if;
  if v_folio.status<>'open' then raise exception 'Folio is closed.' using errcode='23514'; end if;
  if p_amount_kobo is null or p_amount_kobo<=0 or length(coalesce(p_idempotency_key,''))<8 then
    raise exception 'Enter a positive payment and transaction key.' using errcode='22023'; end if;
  select id,folio_id,payment_method_id,amount_kobo into v_existing,v_existing_folio,v_existing_method,v_existing_amount
    from public.payments where organization_id=v_folio.organization_id and idempotency_key=p_idempotency_key;
  if v_existing is not null then
    if v_existing_folio<>p_folio_id or v_existing_method<>p_payment_method_id or v_existing_amount<>p_amount_kobo then
      raise exception 'Transaction key was already used for a different payment.' using errcode='23505'; end if;
    return v_existing;
  end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_folio.organization_id
    and property_id=v_folio.property_id and active;
  if not found then raise exception 'Choose a valid payment method.' using errcode='22023'; end if;
  select coalesce(sum(total_amount_kobo),0) into v_balance from public.folio_items
    where organization_id=v_folio.organization_id and folio_id=p_folio_id;
  if p_amount_kobo>v_balance then raise exception 'Payment exceeds the folio balance.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_date from public.properties where id=v_folio.property_id;
  insert into public.payments(organization_id,property_id,folio_id,payment_method_id,amount_kobo,reference,idempotency_key,received_by)
    values(v_folio.organization_id,v_folio.property_id,p_folio_id,p_payment_method_id,p_amount_kobo,
      nullif(btrim(p_reference),''),p_idempotency_key,auth.uid()) returning id into v_payment;
  v_key:='payment:'||p_idempotency_key;
  v_journal:=public.post_accounting_event(v_folio.organization_id,v_folio.property_id,'folio_payment',v_payment,v_date,
    'Guest payment via '||v_method.name,p_amount_kobo,v_method.clearing_account_code,'1100',v_key);
  insert into public.folio_items(organization_id,property_id,folio_id,item_type,description,service_date,
    unit_amount_kobo,total_amount_kobo,created_by,source_key,journal_id)
    values(v_folio.organization_id,v_folio.property_id,p_folio_id,'payment','Payment · '||v_method.name,v_date,
      -p_amount_kobo,-p_amount_kobo,auth.uid(),v_key,v_journal);
  return v_payment;
end $$;

create or replace function public.post_paid_expense(p_property_id uuid,p_description text,p_vendor text,
  p_amount_kobo bigint,p_payment_method_id uuid,p_idempotency_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_org uuid; v_method public.payment_methods%rowtype; v_date date; v_expense uuid;
  v_existing uuid; v_existing_property uuid; v_existing_amount bigint; v_existing_description text;
  v_account uuid; v_payment_account uuid; v_journal uuid; v_key text;
begin
  select organization_id,(now() at time zone timezone)::date into v_org,v_date from public.properties where id=p_property_id;
  if not found then raise exception 'Property not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_org,array['owner','manager','accountant']::public.member_role[])
    or not public.can_access_property(v_org,p_property_id) then
    raise exception 'You cannot post expenses for this property.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_description,'')))<2 or p_amount_kobo is null or p_amount_kobo<=0
    or length(coalesce(p_idempotency_key,''))<8 then raise exception 'Enter an expense description and positive amount.' using errcode='22023'; end if;
  v_key:='expense:'||p_idempotency_key;
  select e.id,e.property_id,e.amount_kobo,e.description into v_existing,v_existing_property,v_existing_amount,v_existing_description
    from public.journals j join public.expenses e on e.id=j.source_id
    where j.organization_id=v_org and j.idempotency_key=v_key;
  if v_existing is not null then
    if v_existing_property<>p_property_id or v_existing_amount<>p_amount_kobo or v_existing_description<>btrim(p_description) then
      raise exception 'Transaction key was already used for a different expense.' using errcode='23505'; end if;
    return v_existing;
  end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and organization_id=v_org
    and property_id=p_property_id and active;
  if not found then raise exception 'Choose a valid payment method.' using errcode='22023'; end if;
  select id into v_account from public.accounts where organization_id=v_org and code='5000' and active;
  select id into v_payment_account from public.accounts where organization_id=v_org and code=v_method.clearing_account_code and active;
  insert into public.expenses(organization_id,property_id,expense_date,vendor,description,expense_account_id,
    payment_account_id,amount_kobo,status,created_by)
    values(v_org,p_property_id,v_date,nullif(btrim(p_vendor),''),btrim(p_description),v_account,
      v_payment_account,p_amount_kobo,'posted',auth.uid()) returning id into v_expense;
  v_journal:=public.post_accounting_event(v_org,p_property_id,'expense',v_expense,v_date,
    btrim(p_description),p_amount_kobo,'5000',v_method.clearing_account_code,v_key);
  update public.expenses set journal_id=v_journal where id=v_expense;
  return v_expense;
end $$;

create or replace function public.check_out_reservation(p_reservation_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_res public.reservations%rowtype; v_folio public.folios%rowtype; v_today date; v_balance bigint;
begin
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'Reservation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v_res.organization_id,array['owner','manager','front_desk']::public.member_role[])
    or not public.can_access_property(v_res.organization_id,v_res.property_id) then
    raise exception 'You cannot check out this reservation.' using errcode='42501'; end if;
  if v_res.status<>'checked_in' then raise exception 'Only in-house guests can check out.' using errcode='23514'; end if;
  select (now() at time zone timezone)::date into v_today from public.properties where id=v_res.property_id;
  if v_today<v_res.departure_date then raise exception 'Early checkout is not yet supported. Update the stay dates first.' using errcode='23514'; end if;
  perform public.post_due_room_nights(p_reservation_id);
  select * into v_folio from public.folios where organization_id=v_res.organization_id and reservation_id=p_reservation_id for update;
  select coalesce(sum(total_amount_kobo),0) into v_balance from public.folio_items
    where organization_id=v_res.organization_id and folio_id=v_folio.id;
  if v_balance<>0 then raise exception 'Settle the folio balance before checkout.' using errcode='23514'; end if;
  update public.folios set status='closed',closed_at=now() where id=v_folio.id;
  update public.reservations set status='checked_out' where id=v_res.id;
  update public.rooms set housekeeping_status='dirty' where id in
    (select room_id from public.reservation_rooms where organization_id=v_res.organization_id and reservation_id=v_res.id);
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v_res.organization_id,v_res.property_id,auth.uid(),'guest_checked_out','reservation',v_res.id,
      jsonb_build_object('folio_id',v_folio.id));
end $$;

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
    coalesce(sum(case when j.source_type='folio_payment' and a.account_type='asset' and l.debit_kobo>0
      then l.debit_kobo else 0 end),0)::bigint,
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

revoke all on function public.post_due_room_nights(uuid) from public,anon;
revoke all on function public.post_folio_charge(uuid,text,bigint,text) from public,anon;
revoke all on function public.record_folio_payment(uuid,uuid,bigint,text,text) from public,anon;
revoke all on function public.post_paid_expense(uuid,text,text,bigint,uuid,text) from public,anon;
revoke all on function public.check_out_reservation(uuid) from public,anon;
revoke all on function public.get_property_financial_summary(uuid,date,date) from public,anon;
grant execute on function public.post_due_room_nights(uuid) to authenticated;
grant execute on function public.post_folio_charge(uuid,text,bigint,text) to authenticated;
grant execute on function public.record_folio_payment(uuid,uuid,bigint,text,text) to authenticated;
grant execute on function public.post_paid_expense(uuid,text,text,bigint,uuid,text) to authenticated;
grant execute on function public.check_out_reservation(uuid) to authenticated;
grant execute on function public.get_property_financial_summary(uuid,date,date) to authenticated;

drop policy if exists accounts_read on public.accounts;
create policy accounts_read on public.accounts for select to authenticated using
  (public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
drop policy if exists journals_read on public.journals;
create policy journals_read on public.journals for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
drop policy if exists journal_lines_read on public.journal_lines;
create policy journal_lines_read on public.journal_lines for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
drop policy if exists expenses_read on public.expenses;
create policy expenses_read on public.expenses for select to authenticated using
  (public.can_access_property(organization_id,property_id) and
   public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));
