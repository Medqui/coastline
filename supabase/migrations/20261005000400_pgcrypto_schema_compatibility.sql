-- Existing invite and statement RPCs qualify pgcrypto as public. Supabase commonly
-- installs it in extensions; add narrowly scoped aliases without moving the extension.
do $compat$
declare crypto_schema text;
begin
 select n.nspname into crypto_schema from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto';
 if crypto_schema is null then raise exception 'pgcrypto must be installed before this migration.'; end if;
 if to_regprocedure('public.gen_random_bytes(integer)') is null then
  execute format('create function public.gen_random_bytes(integer) returns bytea language sql volatile set search_path='''' as %L','select '||quote_ident(crypto_schema)||'.gen_random_bytes($1)');
  revoke all on function public.gen_random_bytes(integer) from public,anon;
  grant execute on function public.gen_random_bytes(integer) to authenticated;
 end if;
 if to_regprocedure('public.digest(text,text)') is null then
  execute format('create function public.digest(text,text) returns bytea language sql immutable strict set search_path='''' as %L','select '||quote_ident(crypto_schema)||'.digest($1,$2)');
  revoke all on function public.digest(text,text) from public,anon;
  grant execute on function public.digest(text,text) to authenticated;
 end if;
end $compat$;
