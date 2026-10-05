"""Generate the SQL Editor installer from preserved versioned migrations.

Historical files remain the CLI migration source. The installer normalizes only
known DDL and always installs the latest function definitions in one transaction.
"""
from pathlib import Path
import hashlib
import re

ROOT = Path(__file__).resolve().parents[1]


def split_statements(sql):
    """Split top-level SQL, keeping quoted function bodies and comments intact."""
    start = i = 0
    state = None
    tag = ''
    depth = 0
    result = []
    while i < len(sql):
        if state == 'line':
            if sql[i] == '\n': state = None
        elif state == 'block':
            if sql[i:i+2] == '/*': depth += 1; i += 1
            elif sql[i:i+2] == '*/':
                depth -= 1; i += 1
                if depth == 0: state = None
        elif state in ('single', 'double'):
            quote = "'" if state == 'single' else '"'
            if sql[i] == quote:
                if sql[i:i+2] == quote * 2: i += 1
                else: state = None
        elif state == 'dollar':
            if sql.startswith(tag, i): i += len(tag)-1; state = None
        elif sql[i:i+2] == '--': state = 'line'; i += 1
        elif sql[i:i+2] == '/*': state = 'block'; depth = 1; i += 1
        elif sql[i] == "'": state = 'single'
        elif sql[i] == '"': state = 'double'
        elif sql[i] == '$' and (m := re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$', sql[i:])):
            tag = m.group(); state = 'dollar'; i += len(tag)-1
        elif sql[i] == ';': result.append(sql[start:i+1]); start = i+1
        i += 1
    if state not in (None, 'line'): raise ValueError('Unterminated SQL quote/comment')
    if sql[start:].strip(): result.append(sql[start:])
    return result


def leading_comments(statement):
    prefix = ''
    rest = statement
    while (m := re.match(r'\s*(?:--[^\n]*(?:\n|$)|/\*.*?\*/)', rest, re.S)):
        prefix += m.group(); rest = rest[m.end():]
    return prefix, rest.lstrip()


def guarded_constraint(table, name, definition):
    escaped = (f'alter table {table} add constraint {name} {definition}').replace("'", "''")
    return f"""do $pms_constraint$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conrelid='{table}'::regclass and conname='{name}') then
    execute '{escaped}';
  end if;
end $pms_constraint$;"""


def normalize(path):
    sql = path.read_text()
    number = int(path.name.split('_')[0][-6:]) // 100
    if number == 6 and sql.count('drop function if exists public.get_team_members(uuid);') >= 2:
        # The earlier copy lacks all_properties. Keep only the final return type.
        marker = 'drop function if exists public.get_team_members(uuid);'
        first = sql.index(marker); second = sql.index(marker, first + len(marker))
        sql = sql[:first] + sql[second+len(marker):]
    if number == 8:
        if 'execute $pms_pricing_ddl$' in sql:
            prefix, wrapped = sql.split('-- Keep the current quoted-booking RPC when older SQL is replayed.', 1)
            ddl = wrapped.split('execute $pms_pricing_ddl$', 1)[1].split('$pms_pricing_ddl$;', 1)[0]
            sql = prefix + ddl
        # Create the private 12-argument legacy function directly. This avoids
        # recreating the old public overload beside the current quoted booking RPC.
        sql = sql.replace('public.create_priced_reservation(', 'public.create_priced_reservation_legacy(')
    if number == 10:
        sql = re.sub(r'do \$pms_legacy_pricing\$.*?end \$pms_legacy_pricing\$;',
                     'drop function if exists public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text);', sql, flags=re.S)
        sql = sql.replace('alter function public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text) rename to create_priced_reservation_legacy;',
                          'drop function if exists public.create_priced_reservation(uuid,uuid,uuid,text,text,text,date,date,smallint,bigint,text,text);')
    if number == 11:
        sql = sql.replace('(new.organization_id,new.id,\'services\',\'Guest services\'),(new.organization_id,new.id,\'administration\',\'Administration\');',
                          '(new.organization_id,new.id,\'services\',\'Guest services\'),(new.organization_id,new.id,\'administration\',\'Administration\') on conflict(property_id,code) do nothing;')
        sql = sql.replace("('services','Guest services'),('administration','Administration')) v(code,name);",
                          "('services','Guest services'),('administration','Administration')) v(code,name) on conflict(property_id,code) do nothing;")
        sql = sql.replace('alter table public.journals add column department_id uuid,\n  add constraint journals_department_property_fk foreign key(organization_id,property_id,department_id) references public.departments(organization_id,property_id,id);',
                          'alter table public.journals add column if not exists department_id uuid;\n' + guarded_constraint('public.journals','journals_department_property_fk','foreign key(organization_id,property_id,department_id) references public.departments(organization_id,property_id,id)'))
        sql = sql.replace('alter table public.expenses add column payment_method_id uuid,\n  add constraint expenses_payment_method_fk foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id);',
                          'alter table public.expenses add column if not exists payment_method_id uuid;\n' + guarded_constraint('public.expenses','expenses_payment_method_fk','foreign key(organization_id,property_id,payment_method_id) references public.payment_methods(organization_id,property_id,id)'))
    if number == 12:
        sql = sql.replace("values(new.id,'2000','Supplier payables','liability');", "values(new.id,'2000','Supplier payables','liability') on conflict(organization_id,code) do nothing;")
        sql = sql.replace("    execute format('create policy finance_read", "    execute format('drop policy if exists finance_read on public.%I',t);\n    execute format('create policy finance_read")
    result = []
    for statement in split_statements(sql):
        prefix, body = leading_comments(statement)
        body = re.sub(r'^create table (?!if not exists)', 'create table if not exists ', body, flags=re.I)
        body = re.sub(r'^create (unique )?index (?!if not exists)', r'create \1index if not exists ', body, flags=re.I)
        body = re.sub(r'^create function ', 'create or replace function ', body, flags=re.I)
        if m := re.match(r'create policy (\w+) on (public\.\w+)', body, re.I):
            body = f'drop policy if exists {m[1]} on {m[2]};\n' + body
        if m := re.match(r'create trigger (\w+).*? on (public\.\w+) ', body, re.I | re.S):
            body = f'drop trigger if exists {m[1]} on {m[2]};\n' + body
        if m := re.fullmatch(r'alter table (public\.\w+) add constraint (\w+) (unique\(.*\));', body, re.I | re.S):
            body = guarded_constraint(*m.groups())
        result.append(prefix + body)
    return '\n\n'.join(result)


def generate(root):
    paths = sorted((root/'supabase/migrations').glob('*.sql'))
    assert len(paths) == 19, 'Review generator when adding a new release/migration.'
    payload = '\n\n'.join('-- Source: '+p.name+'\n'+normalize(p) for p in paths)
    checksum = hashlib.sha256(payload.encode()).hexdigest()
    version = paths[-1].name.split('_')[0]
    assert '$pms_payload$' not in payload and '$pms_install$' not in payload
    header = """-- Coastline PMS repeatable SQL Editor installer — migrations 000–018.
-- GENERATED by scripts/build-repeatable-installer.py. Do not edit this file.
-- Run this WHOLE file in Supabase SQL Editor as the database administrator.
-- Supports an empty project, earlier complete migrations, and interrupted
-- installs of these known migrations. Existing hotel records are preserved.
-- Reapplying this exact release is a no-op. Competing installs serialize.
-- CLI users: keep using versioned migrations with supabase db push.
-- A newer/different recorded release causes a safe rollback, not a downgrade.

begin;
select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('coastline:pms-schema-installer',0));
create table if not exists public.pms_schema_releases (
  version text primary key,
  checksum text not null,
  installed_at timestamptz not null default now()
);
alter table public.pms_schema_releases enable row level security;
revoke all on public.pms_schema_releases from public,anon,authenticated;

do $pms_install$
declare v_checksum text; v_newer boolean;
begin
"""
    body = f"""  if pg_catalog.to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select exists(select 1 from supabase_migrations.schema_migrations where version>$1)' into v_newer using '{version}';
    if v_newer then
      raise exception 'Supabase migration history contains a newer release. This installer will not downgrade it.' using errcode='55000';
    end if;
  end if;
  if exists(select 1 from public.pms_schema_releases where version>'{version}') then
    raise exception 'A newer PMS release is installed. Use its installer; this copy will not downgrade the database.' using errcode='55000';
  end if;
  select checksum into v_checksum from public.pms_schema_releases where version='{version}';
  if found then
    if v_checksum<>'{checksum}' then
      raise exception 'A different copy of this PMS release is installed. Use the matching installer or a forward update.' using errcode='55000';
    end if;
    raise notice 'PMS release {version} is already installed; no migration changes applied.';
    return;
  end if;
  execute $pms_payload$
{payload}
$pms_payload$;
  insert into public.pms_schema_releases(version,checksum) values('{version}','{checksum}');
end $pms_install$;

notify pgrst,'reload schema';
commit;
select version,installed_at,'PMS database is up to date' as status from public.pms_schema_releases where version='{version}';
"""
    return header + body


if __name__ == '__main__':
    target = ROOT/'supabase/repeatable-install.sql'
    target.write_text(generate(ROOT))
    print(f'Generated {target.name}')
