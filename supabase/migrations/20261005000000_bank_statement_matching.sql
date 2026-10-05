-- Imported statement facts, ledger matching, reviewed exceptions and completion controls.
alter table public.bank_reconciliations add column if not exists matching_required boolean not null default false;

create table if not exists public.bank_statement_imports(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  reconciliation_id uuid not null references public.bank_reconciliations(id),payment_method_id uuid not null,
  file_name text not null check(length(file_name) between 1 and 240),file_sha256 text not null check(file_sha256~'^[0-9a-f]{64}$'),
  row_count integer not null check(row_count between 1 and 5000),idempotency_key text not null,
  created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  foreign key(organization_id,property_id) references public.properties(organization_id,id),
  foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id),
  unique(organization_id,idempotency_key),unique(organization_id,property_id,payment_method_id,file_sha256),
  unique(organization_id,property_id,id)
);

create table if not exists public.bank_statement_lines(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  reconciliation_id uuid not null references public.bank_reconciliations(id),import_id uuid not null,
  payment_method_id uuid not null,line_number integer not null check(line_number>0),transaction_date date not null,
  description text not null check(length(description) between 1 and 500),reference text,
  amount_kobo bigint not null check(amount_kobo<>0),balance_kobo bigint,fingerprint text not null,
  created_at timestamptz not null default now(),
  foreign key(organization_id,property_id,import_id) references public.bank_statement_imports(organization_id,property_id,id),
  foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id),
  unique(import_id,line_number),unique(organization_id,property_id,id)
);
create index if not exists bank_statement_lines_reconciliation_idx on public.bank_statement_lines(reconciliation_id,transaction_date,line_number);

create table if not exists public.bank_statement_matches(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  reconciliation_id uuid not null references public.bank_reconciliations(id),statement_line_id uuid not null,journal_id uuid not null,
  match_method text not null check(match_method in ('automatic','manual')),reason text,
  status text not null default 'active' check(status in ('active','void')),
  idempotency_key text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  voided_by uuid references auth.users,voided_at timestamptz,void_reason text,
  foreign key(organization_id,property_id,statement_line_id) references public.bank_statement_lines(organization_id,property_id,id),
  foreign key(organization_id,property_id,journal_id) references public.journals(organization_id,property_id,id),
  unique(organization_id,idempotency_key),
  check((status='active' and voided_by is null and voided_at is null and void_reason is null) or
    (status='void' and voided_by is not null and voided_at is not null and length(btrim(void_reason)) between 5 and 500))
);
create unique index if not exists bank_statement_active_line_match on public.bank_statement_matches(statement_line_id) where status='active';
create unique index if not exists bank_statement_active_journal_match on public.bank_statement_matches(reconciliation_id,journal_id) where status='active';

create table if not exists public.bank_statement_exceptions(
  id uuid primary key default gen_random_uuid(),organization_id uuid not null,property_id uuid not null,
  reconciliation_id uuid not null references public.bank_reconciliations(id),statement_line_id uuid not null,
  reason text not null check(length(btrim(reason)) between 5 and 500),status text not null default 'open' check(status in ('open','resolved')),
  idempotency_key text not null,created_by uuid not null references auth.users,created_at timestamptz not null default now(),
  resolved_by uuid references auth.users,resolved_at timestamptz,resolution text,
  foreign key(organization_id,property_id,statement_line_id) references public.bank_statement_lines(organization_id,property_id,id),
  unique(organization_id,idempotency_key),
  check((status='open' and resolved_by is null and resolved_at is null and resolution is null) or
    (status='resolved' and resolved_by is not null and resolved_at is not null and resolution is not null))
);
create unique index if not exists bank_statement_open_line_exception on public.bank_statement_exceptions(statement_line_id) where status='open';

do $$ declare t text;begin
  foreach t in array array['bank_statement_imports','bank_statement_lines','bank_statement_matches','bank_statement_exceptions'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists finance_read on public.%I',t);
    execute format('create policy finance_read on public.%I for select to authenticated using(public.can_access_property(organization_id,property_id) and public.has_org_role(organization_id,array[''owner'',''manager'',''accountant'']::public.member_role[]))',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
  end loop;
end $$;

create or replace function public.guard_imported_bank_fact() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Imported bank statement facts cannot be changed or deleted.' using errcode='23514'; end $$;
revoke all on function public.guard_imported_bank_fact() from public,anon,authenticated;
drop trigger if exists bank_statement_import_immutable on public.bank_statement_imports;
create trigger bank_statement_import_immutable before update or delete on public.bank_statement_imports for each row execute function public.guard_imported_bank_fact();
drop trigger if exists bank_statement_line_immutable on public.bank_statement_lines;
create trigger bank_statement_line_immutable before update or delete on public.bank_statement_lines for each row execute function public.guard_imported_bank_fact();

create or replace function public.import_bank_statement(p_reconciliation_id uuid,p_file_name text,p_file_sha256 text,p_lines jsonb,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;prior public.bank_statement_imports%rowtype;result uuid;item jsonb;n integer:=0;d date;a bigint;b bigint;
begin
  select * into r from public.bank_reconciliations where id=p_reconciliation_id for update;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can import a bank statement.' using errcode='42501'; end if;
  if r.status<>'open' then raise exception 'This reconciliation is already complete.' using errcode='23514'; end if;
  if coalesce(length(btrim(p_file_name)),0) not between 1 and 240 or coalesce(p_file_sha256,'') !~ '^[0-9a-f]{64}$'
    or coalesce(jsonb_typeof(p_lines),'')<>'array'
    or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Choose a valid CSV statement with up to 5,000 rows.' using errcode='22023'; end if;
  if jsonb_array_length(p_lines) not between 1 and 5000 then raise exception 'Choose a valid CSV statement with up to 5,000 rows.' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(r.organization_id::text||':bank-import:'||p_file_sha256,0));
  select * into prior from public.bank_statement_imports where organization_id=r.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.reconciliation_id<>r.id or prior.file_sha256<>p_file_sha256 then raise exception 'Transaction key was already used for another statement.' using errcode='23505'; end if;
    return prior.id;
  end if;
  select * into prior from public.bank_statement_imports where organization_id=r.organization_id and property_id=r.property_id and payment_method_id=r.payment_method_id and file_sha256=p_file_sha256;
  if found then
    if prior.reconciliation_id<>r.id then raise exception 'This statement file was already imported for another reconciliation.' using errcode='23505'; end if;
    return prior.id;
  end if;
  insert into public.bank_statement_imports(organization_id,property_id,reconciliation_id,payment_method_id,file_name,file_sha256,row_count,idempotency_key,created_by)
    values(r.organization_id,r.property_id,r.id,r.payment_method_id,btrim(p_file_name),p_file_sha256,jsonb_array_length(p_lines),p_idempotency_key,auth.uid()) returning id into result;
  for item in select value from jsonb_array_elements(p_lines) loop
    n:=n+1;
    if coalesce(item->>'date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(item->>'amount_kobo','') !~ '^-?[0-9]+$'
      or coalesce(length(btrim(item->>'description')),0) not between 1 and 500 or coalesce(length(item->>'reference'),0)>200
      or (item->>'balance_kobo' is not null and item->>'balance_kobo' !~ '^-?[0-9]+$') then
      raise exception 'Statement row % is invalid.',n using errcode='22023'; end if;
    begin d:=(item->>'date')::date;a:=(item->>'amount_kobo')::bigint;b:=case when item->>'balance_kobo' is null then null else (item->>'balance_kobo')::bigint end;
    exception when others then raise exception 'Statement row % has an invalid date or amount.',n using errcode='22023'; end;
    if d<r.period_from or d>r.period_to or a=0 then raise exception 'Statement row % is outside the reconciliation period or has a zero amount.',n using errcode='22023'; end if;
    insert into public.bank_statement_lines(organization_id,property_id,reconciliation_id,import_id,payment_method_id,line_number,transaction_date,description,reference,amount_kobo,balance_kobo,fingerprint)
      values(r.organization_id,r.property_id,r.id,result,r.payment_method_id,n,d,btrim(item->>'description'),nullif(btrim(item->>'reference'),''),a,b,
        encode(public.digest(d::text||'|'||a::text||'|'||btrim(item->>'description')||'|'||coalesce(btrim(item->>'reference'),''),'sha256'),'hex'));
  end loop;
  update public.bank_reconciliations set matching_required=true where id=r.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(r.organization_id,r.property_id,auth.uid(),'bank_statement_imported','bank_reconciliation',r.id,jsonb_build_object('import_id',result,'file_name',btrim(p_file_name),'row_count',n));
  return result;
end $$;
revoke all on function public.import_bank_statement(uuid,text,text,jsonb,text) from public,anon;
grant execute on function public.import_bank_statement(uuid,text,text,jsonb,text) to authenticated;

create or replace function public.get_bank_statement_lines(p_reconciliation_id uuid)
returns table(line_id uuid,transaction_date date,description text,reference text,amount_kobo bigint,balance_kobo bigint,status text,match_id uuid,matched_journal_id uuid,exception_reason text)
language plpgsql stable security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;
begin
  select * into r from public.bank_reconciliations where id=p_reconciliation_id;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this bank reconciliation.' using errcode='42501'; end if;
  return query select l.id,l.transaction_date,l.description,l.reference,l.amount_kobo,l.balance_kobo,
    case when m.id is not null then 'matched' when e.id is not null then 'exception' else 'unmatched' end,m.id,m.journal_id,e.reason
    from public.bank_statement_lines l
      left join public.bank_statement_matches m on m.statement_line_id=l.id and m.status='active'
      left join public.bank_statement_exceptions e on e.statement_line_id=l.id and e.status='open'
    where l.reconciliation_id=r.id order by l.transaction_date,l.line_number,l.id;
end $$;
revoke all on function public.get_bank_statement_lines(uuid) from public,anon;
grant execute on function public.get_bank_statement_lines(uuid) to authenticated;

create or replace function public.get_bank_ledger_candidates(p_reconciliation_id uuid)
returns table(journal_id uuid,journal_date date,memo text,source_type text,amount_kobo bigint,status text,matched_statement_line_id uuid)
language plpgsql stable security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;account_code text;account uuid;
begin
  select * into r from public.bank_reconciliations where id=p_reconciliation_id;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','manager','accountant']::public.member_role[]) then
    raise exception 'You cannot view this bank reconciliation.' using errcode='42501'; end if;
  select clearing_account_code into account_code from public.payment_methods where id=r.payment_method_id and organization_id=r.organization_id and property_id=r.property_id;
  select id into account from public.accounts where organization_id=r.organization_id and code=account_code;
  return query select j.id,j.journal_date,j.memo,j.source_type,sum(l.debit_kobo-l.credit_kobo)::bigint,
    case when m.id is null then 'unmatched' else 'matched' end,m.statement_line_id
    from public.journals j join public.journal_lines l on (l.organization_id,l.journal_id)=(j.organization_id,j.id) and l.account_id=account
      left join public.bank_statement_matches m on m.reconciliation_id=r.id and m.journal_id=j.id and m.status='active'
    where j.organization_id=r.organization_id and j.property_id=r.property_id and j.status='posted' and j.journal_date between r.period_from and r.period_to
    group by j.id,j.journal_date,j.memo,j.source_type,m.id,m.statement_line_id
    having sum(l.debit_kobo-l.credit_kobo)<>0 order by j.journal_date,j.id;
end $$;
revoke all on function public.get_bank_ledger_candidates(uuid) from public,anon;
grant execute on function public.get_bank_ledger_candidates(uuid) to authenticated;

create or replace function public.match_bank_statement_line(p_statement_line_id uuid,p_journal_id uuid,p_reason text,p_idempotency_key text,p_method text default 'manual')
returns uuid language plpgsql security definer set search_path='' as $$
declare l public.bank_statement_lines%rowtype;r public.bank_reconciliations%rowtype;j public.journals%rowtype;prior public.bank_statement_matches%rowtype;account_code text;account uuid;movement bigint;result uuid;
begin
  select * into l from public.bank_statement_lines where id=p_statement_line_id for update;
  if not found then raise exception 'Statement line not found.' using errcode='P0002'; end if;
  select * into r from public.bank_reconciliations where id=l.reconciliation_id for update;
  if not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can match statement lines.' using errcode='42501'; end if;
  if r.status<>'open' then raise exception 'This reconciliation is already complete.' using errcode='23514'; end if;
  if p_method not in ('automatic','manual') or coalesce(length(p_idempotency_key),0) not between 8 and 200 or coalesce(length(p_reason),0)>500 then
    raise exception 'Enter valid matching details.' using errcode='22023'; end if;
  select * into prior from public.bank_statement_matches where organization_id=r.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.statement_line_id<>l.id or prior.journal_id<>p_journal_id then raise exception 'Transaction key was already used for another match.' using errcode='23505'; end if;
    return prior.id;
  end if;
  select * into j from public.journals where id=p_journal_id and organization_id=r.organization_id and property_id=r.property_id and status='posted' and journal_date between r.period_from and r.period_to;
  if not found then raise exception 'Choose a posted ledger movement in this reconciliation period.' using errcode='22023'; end if;
  select clearing_account_code into account_code from public.payment_methods where id=r.payment_method_id;
  select id into account from public.accounts where organization_id=r.organization_id and code=account_code;
  select coalesce(sum(debit_kobo-credit_kobo),0)::bigint into movement from public.journal_lines where organization_id=r.organization_id and journal_id=j.id and account_id=account;
  if movement<>l.amount_kobo then raise exception 'Statement and ledger amounts must match exactly.' using errcode='23514'; end if;
  if exists(select 1 from public.bank_statement_matches where statement_line_id=l.id and status='active') or
    exists(select 1 from public.bank_statement_matches where reconciliation_id=r.id and journal_id=j.id and status='active') then
    raise exception 'The statement line or ledger movement is already matched.' using errcode='23505'; end if;
  insert into public.bank_statement_matches(organization_id,property_id,reconciliation_id,statement_line_id,journal_id,match_method,reason,idempotency_key,created_by)
    values(r.organization_id,r.property_id,r.id,l.id,j.id,p_method,nullif(btrim(p_reason),''),p_idempotency_key,auth.uid()) returning id into result;
  update public.bank_statement_exceptions set status='resolved',resolved_by=auth.uid(),resolved_at=now(),resolution='Matched to ledger movement'
    where statement_line_id=l.id and status='open';
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(r.organization_id,r.property_id,auth.uid(),'bank_statement_line_matched','bank_statement_line',l.id,jsonb_build_object('match_id',result,'journal_id',j.id,'method',p_method));
  return result;
end $$;
revoke all on function public.match_bank_statement_line(uuid,uuid,text,text,text) from public,anon;
grant execute on function public.match_bank_statement_line(uuid,uuid,text,text,text) to authenticated;

create or replace function public.auto_match_bank_statement(p_reconciliation_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare r public.bank_reconciliations%rowtype;pair record;n integer:=0;key text;
begin
  select * into r from public.bank_reconciliations where id=p_reconciliation_id for update;
  if not found or not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can automatically match a statement.' using errcode='42501'; end if;
  if r.status<>'open' then raise exception 'This reconciliation is already complete.' using errcode='23514'; end if;
  for pair in
    with lines as(select * from public.get_bank_statement_lines(r.id) where status<>'matched'),ledger as(select * from public.get_bank_ledger_candidates(r.id) where status='unmatched'),
    possible as(select l.line_id,g.journal_id,count(*) over(partition by l.line_id) as lc,count(*) over(partition by g.journal_id) as gc
      from lines l join ledger g on g.amount_kobo=l.amount_kobo and abs(g.journal_date-l.transaction_date)<=3)
    select line_id,journal_id from possible where lc=1 and gc=1 order by line_id
  loop
    key:='auto-bank-match:'||r.id::text||':'||pair.line_id::text||':'||pair.journal_id::text;
    perform public.match_bank_statement_line(pair.line_id,pair.journal_id,'Unique amount within three days',key,'automatic');n:=n+1;
  end loop;
  return n;
end $$;
revoke all on function public.auto_match_bank_statement(uuid) from public,anon;
grant execute on function public.auto_match_bank_statement(uuid) to authenticated;

create or replace function public.flag_bank_statement_exception(p_statement_line_id uuid,p_reason text,p_idempotency_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare l public.bank_statement_lines%rowtype;r public.bank_reconciliations%rowtype;prior public.bank_statement_exceptions%rowtype;result uuid;
begin
  select * into l from public.bank_statement_lines where id=p_statement_line_id for update;
  if not found then raise exception 'Statement line not found.' using errcode='P0002'; end if;
  select * into r from public.bank_reconciliations where id=l.reconciliation_id for update;
  if not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can review statement exceptions.' using errcode='42501'; end if;
  if r.status<>'open' or exists(select 1 from public.bank_statement_matches where statement_line_id=l.id and status='active') then
    raise exception 'Only an unmatched line in an open reconciliation can be flagged.' using errcode='23514'; end if;
  if coalesce(length(btrim(p_reason)),0) not between 5 and 500 or coalesce(length(p_idempotency_key),0) not between 8 and 200 then
    raise exception 'Enter an exception reason between 5 and 500 characters.' using errcode='22023'; end if;
  select * into prior from public.bank_statement_exceptions where organization_id=r.organization_id and idempotency_key=p_idempotency_key;
  if found then
    if prior.statement_line_id<>l.id or prior.reason<>btrim(p_reason) then raise exception 'Transaction key was already used for another exception.' using errcode='23505'; end if;
    return prior.id;
  end if;
  update public.bank_statement_exceptions set status='resolved',resolved_by=auth.uid(),resolved_at=now(),resolution='Replaced by a revised exception reason'
    where statement_line_id=l.id and status='open';
  insert into public.bank_statement_exceptions(organization_id,property_id,reconciliation_id,statement_line_id,reason,idempotency_key,created_by)
    values(r.organization_id,r.property_id,r.id,l.id,btrim(p_reason),p_idempotency_key,auth.uid()) returning id into result;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(r.organization_id,r.property_id,auth.uid(),'bank_statement_exception_flagged','bank_statement_line',l.id,jsonb_build_object('exception_id',result,'reason',btrim(p_reason)));
  return result;
end $$;
revoke all on function public.flag_bank_statement_exception(uuid,text,text) from public,anon;
grant execute on function public.flag_bank_statement_exception(uuid,text,text) to authenticated;

create or replace function public.void_bank_statement_match(p_match_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare m public.bank_statement_matches%rowtype;r public.bank_reconciliations%rowtype;
begin
  select * into m from public.bank_statement_matches where id=p_match_id for update;
  if not found then raise exception 'Statement match not found.' using errcode='P0002'; end if;
  select * into r from public.bank_reconciliations where id=m.reconciliation_id for update;
  if not public.can_access_property(r.organization_id,r.property_id) or not public.has_org_role(r.organization_id,array['owner','accountant']::public.member_role[]) then
    raise exception 'Only an owner or accountant can correct statement matches.' using errcode='42501'; end if;
  if r.status<>'open' or m.status<>'active' or coalesce(length(btrim(p_reason)),0) not between 5 and 500 then
    raise exception 'Enter a correction reason for an active match in an open reconciliation.' using errcode='23514'; end if;
  update public.bank_statement_matches set status='void',voided_by=auth.uid(),voided_at=now(),void_reason=btrim(p_reason) where id=m.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(r.organization_id,r.property_id,auth.uid(),'bank_statement_match_voided','bank_statement_line',m.statement_line_id,
      jsonb_build_object('match_id',m.id,'journal_id',m.journal_id),jsonb_build_object('reason',btrim(p_reason)));
end $$;
revoke all on function public.void_bank_statement_match(uuid,text) from public,anon;
grant execute on function public.void_bank_statement_match(uuid,text) to authenticated;

create or replace function public.complete_bank_reconciliation(p_reconciliation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v public.bank_reconciliations%rowtype;
begin
  select * into v from public.bank_reconciliations where id=p_reconciliation_id for update;
  if not found then raise exception 'Reconciliation not found.' using errcode='P0002'; end if;
  if not public.has_org_role(v.organization_id,array['owner','accountant']::public.member_role[]) or not public.can_access_property(v.organization_id,v.property_id) then
    raise exception 'Only an owner or accountant can complete a reconciliation.' using errcode='42501'; end if;
  if v.status<>'open' or v.difference_kobo<>0 then raise exception 'Statement and book balances must match before completing.' using errcode='23514'; end if;
  if v.matching_required and (not exists(select 1 from public.bank_statement_imports where reconciliation_id=v.id)
    or exists(select 1 from public.get_bank_statement_lines(v.id) where status<>'matched')
    or exists(select 1 from public.get_bank_ledger_candidates(v.id) where status<>'matched')) then
    raise exception 'Match every statement line and ledger movement before completing.' using errcode='23514'; end if;
  update public.bank_reconciliations set status='reconciled',reconciled_at=now() where id=v.id;
  insert into public.audit_events(organization_id,property_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(v.organization_id,v.property_id,auth.uid(),'bank_reconciliation_completed','bank_reconciliation',v.id,
      jsonb_build_object('period_from',v.period_from,'period_to',v.period_to,'statement_balance_kobo',v.statement_balance_kobo,'matching_required',v.matching_required));
end $$;
revoke all on function public.complete_bank_reconciliation(uuid) from public,anon;
grant execute on function public.complete_bank_reconciliation(uuid) to authenticated;

notify pgrst,'reload schema';
