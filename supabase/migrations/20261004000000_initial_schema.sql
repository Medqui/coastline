-- Coastline PMS: foundational multi-tenant schema for Supabase/Postgres.
-- Monetary amounts are integer kobo. Apply in a migration after reviewing with the app team.
create extension if not exists pgcrypto;

do $$ begin if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'member_role') then create type public.member_role as enum ('owner','manager','front_desk','accountant','housekeeping'); end if; end $$;
do $$ begin if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'reservation_status') then create type public.reservation_status as enum ('inquiry','confirmed','checked_in','checked_out','cancelled','no_show'); end if; end $$;
do $$ begin if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'room_housekeeping_status') then create type public.room_housekeeping_status as enum ('clean','dirty','inspected','out_of_order'); end if; end $$;
do $$ begin if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'folio_status') then create type public.folio_status as enum ('open','closed','void'); end if; end $$;
do $$ begin if not exists (select 1 from pg_type where typnamespace = 'public'::regnamespace and typname = 'journal_status') then create type public.journal_status as enum ('draft','posted','reversed'); end if; end $$;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.organization_memberships (
  organization_id uuid not null references public.organizations on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role public.member_role not null,
  active boolean not null default true,
  all_properties boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);
create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations on delete cascade,
  name text not null,
  address text,
  city text not null default 'Calabar',
  currency char(3) not null default 'NGN' check (currency = 'NGN'),
  timezone text not null default 'Africa/Lagos',
  check_in_time time not null default '14:00',
  check_out_time time not null default '12:00',
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
create table if not exists public.membership_properties (
  organization_id uuid not null,
  user_id uuid not null,
  property_id uuid not null,
  primary key (organization_id,user_id,property_id),
  foreign key (organization_id,user_id) references public.organization_memberships (organization_id,user_id) on delete cascade,
  foreign key (organization_id,property_id) references public.properties (organization_id,id) on delete cascade
);
create table if not exists public.room_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  name text not null,
  base_rate_kobo bigint not null check (base_rate_kobo >= 0),
  max_occupancy smallint not null default 2 check (max_occupancy > 0),
  active boolean not null default true,
  foreign key (organization_id,property_id) references public.properties (organization_id,id) on delete cascade,
  unique (property_id,name), unique (organization_id,id)
);
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  room_type_id uuid not null,
  room_number text not null,
  floor_label text,
  housekeeping_status public.room_housekeeping_status not null default 'dirty',
  active boolean not null default true,
  foreign key (organization_id,property_id) references public.properties (organization_id,id) on delete cascade,
  foreign key (organization_id,room_type_id) references public.room_types (organization_id,id),
  unique (property_id,room_number), unique (organization_id,id)
);
create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations on delete cascade,
  full_name text not null,
  phone text,
  email text,
  notes text,
  created_at timestamptz not null default now(),
  unique (organization_id,id)
);
create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  guest_id uuid not null,
  status public.reservation_status not null default 'confirmed',
  source text not null default 'direct',
  arrival_date date not null,
  departure_date date not null,
  adults smallint not null default 1 check (adults > 0),
  children smallint not null default 0 check (children >= 0),
  notes text,
  created_by uuid references auth.users,
  created_at timestamptz not null default now(),
  check (departure_date > arrival_date),
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,guest_id) references public.guests (organization_id,id),
  unique (organization_id,id)
);
create table if not exists public.reservation_rooms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  reservation_id uuid not null,
  room_id uuid not null,
  nightly_rate_kobo bigint not null check (nightly_rate_kobo >= 0),
  check_in_date date not null,
  check_out_date date not null,
  foreign key (organization_id,reservation_id) references public.reservations (organization_id,id) on delete cascade,
  foreign key (organization_id,room_id) references public.rooms (organization_id,id),
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  check (check_out_date > check_in_date)
);
create table if not exists public.folios (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  reservation_id uuid not null,
  status public.folio_status not null default 'open',
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,reservation_id) references public.reservations (organization_id,id),
  unique (organization_id,id)
);
create table if not exists public.folio_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  folio_id uuid not null,
  item_type text not null check (item_type in ('room_charge','extra','tax','fee','payment','refund','adjustment')),
  description text not null,
  service_date date not null,
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  unit_amount_kobo bigint not null,
  total_amount_kobo bigint not null check (total_amount_kobo <> 0),
  created_by uuid references auth.users,
  created_at timestamptz not null default now(),
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,folio_id) references public.folios (organization_id,id)
);
create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  name text not null,
  clearing_account_code text not null,
  active boolean not null default true,
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  unique (property_id,name), unique (organization_id,id)
);
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  folio_id uuid not null,
  payment_method_id uuid not null,
  amount_kobo bigint not null check (amount_kobo > 0),
  received_at timestamptz not null default now(),
  reference text,
  idempotency_key text not null,
  received_by uuid references auth.users,
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,folio_id) references public.folios (organization_id,id),
  foreign key (organization_id,payment_method_id) references public.payment_methods (organization_id,id),
  unique (organization_id,idempotency_key)
);
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations on delete cascade,
  code text not null,
  name text not null,
  account_type text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  active boolean not null default true,
  unique (organization_id,code), unique (organization_id,id)
);
create table if not exists public.journals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  source_type text not null,
  source_id uuid,
  journal_date date not null,
  memo text not null,
  status public.journal_status not null default 'draft',
  reverses_journal_id uuid references public.journals,
  idempotency_key text not null,
  created_by uuid references auth.users,
  posted_by uuid references auth.users,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  unique (organization_id,idempotency_key), unique (organization_id,id)
);
create table if not exists public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  journal_id uuid not null,
  property_id uuid not null,
  account_id uuid not null,
  description text,
  debit_kobo bigint not null default 0 check (debit_kobo >= 0),
  credit_kobo bigint not null default 0 check (credit_kobo >= 0),
  check ((debit_kobo > 0)::int + (credit_kobo > 0)::int = 1),
  foreign key (organization_id,journal_id) references public.journals (organization_id,id) on delete cascade,
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,account_id) references public.accounts (organization_id,id)
);
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  property_id uuid not null,
  expense_date date not null,
  vendor text,
  description text not null,
  expense_account_id uuid not null,
  payment_account_id uuid,
  amount_kobo bigint not null check (amount_kobo > 0),
  status text not null default 'draft' check (status in ('draft','posted','void')),
  receipt_path text,
  journal_id uuid references public.journals,
  created_by uuid references auth.users,
  created_at timestamptz not null default now(),
  foreign key (organization_id,property_id) references public.properties (organization_id,id),
  foreign key (organization_id,expense_account_id) references public.accounts (organization_id,id),
  foreign key (organization_id,payment_account_id) references public.accounts (organization_id,id)
);
create table if not exists public.audit_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  property_id uuid,
  actor_user_id uuid references auth.users,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now(),
  foreign key (organization_id) references public.organizations,
  foreign key (organization_id,property_id) references public.properties (organization_id,id)
);

-- Helper: active organization membership. Keep SECURITY DEFINER narrowly scoped and pin search_path.
create or replace function public.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organization_memberships m
    where m.organization_id = target_org and m.user_id = auth.uid() and m.active)
$$;
create or replace function public.has_org_role(target_org uuid, allowed public.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organization_memberships m
    where m.organization_id = target_org and m.user_id = auth.uid() and m.active and m.role = any(allowed))
$$;
create or replace function public.can_access_property(target_org uuid, target_property uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_org_member(target_org) and exists (
    select 1 from public.properties p where p.id = target_property and p.organization_id = target_org
  ) and (
    exists (select 1 from public.organization_memberships m where m.organization_id=target_org and m.user_id=auth.uid() and m.active and m.all_properties)
    or exists (select 1 from public.membership_properties mp where mp.organization_id=target_org and mp.user_id=auth.uid() and mp.property_id=target_property)
  )
$$;

-- Enable RLS everywhere. Policies below are a conservative starting point; add role-specific write policies.
do $$ declare t text; begin
  foreach t in array array['organizations','organization_memberships','properties','membership_properties','room_types','rooms','guests','reservations','reservation_rooms','folios','folio_items','payment_methods','payments','accounts','journals','journal_lines','expenses','audit_events'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
drop policy if exists org_read on public.organizations;
create policy org_read on public.organizations for select to authenticated using (public.is_org_member(id));
drop policy if exists membership_read on public.organization_memberships;
create policy membership_read on public.organization_memberships for select to authenticated using (public.is_org_member(organization_id));
drop policy if exists property_read on public.properties;
create policy property_read on public.properties for select to authenticated using (public.can_access_property(organization_id,id));
drop policy if exists membership_property_read on public.membership_properties;
create policy membership_property_read on public.membership_properties for select to authenticated using (public.is_org_member(organization_id));
drop policy if exists room_type_read on public.room_types;
create policy room_type_read on public.room_types for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists rooms_read on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists guests_read on public.guests;
create policy guests_read on public.guests for select to authenticated using (public.is_org_member(organization_id));
drop policy if exists reservations_read on public.reservations;
create policy reservations_read on public.reservations for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists reservation_rooms_read on public.reservation_rooms;
create policy reservation_rooms_read on public.reservation_rooms for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists folios_read on public.folios;
create policy folios_read on public.folios for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists folio_items_read on public.folio_items;
create policy folio_items_read on public.folio_items for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists payment_methods_read on public.payment_methods;
create policy payment_methods_read on public.payment_methods for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists accounts_read on public.accounts;
create policy accounts_read on public.accounts for select to authenticated using (public.is_org_member(organization_id));
drop policy if exists journals_read on public.journals;
create policy journals_read on public.journals for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists journal_lines_read on public.journal_lines;
create policy journal_lines_read on public.journal_lines for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists expenses_read on public.expenses;
create policy expenses_read on public.expenses for select to authenticated using (public.can_access_property(organization_id,property_id));
drop policy if exists audit_read on public.audit_events;
create policy audit_read on public.audit_events for select to authenticated using (public.has_org_role(organization_id,array['owner','manager','accountant']::public.member_role[]));

-- No broad client write policies are granted here. Add narrow policies or expose validated RPCs.
-- Posted journals should be write-protected by trigger/RPC; all posting must be transactional:
-- 1) authenticate + check role/property scope; 2) claim idempotency key; 3) insert source and journal;
-- 4) assert >=2 lines and SUM(debit_kobo)=SUM(credit_kobo); 5) set posted_at/status; 6) append audit event.
-- Never expose the service-role key to the browser. Upload receipts into a private Storage bucket
-- whose policies use the same organization/property authorization boundary.
