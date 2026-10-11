-- Reserve the explicitly requested platform owner's access until their email is verified.
-- Enrollment records are database-administrator-only and never exposed to hotel clients.
create table if not exists saas_private.platform_admin_enrollments (
 email text primary key check(email=lower(email)),
 created_at timestamptz not null default now()
);
alter table saas_private.platform_admin_enrollments enable row level security;
revoke all on saas_private.platform_admin_enrollments from public,anon,authenticated;

create or replace function saas_private.enroll_platform_admin() returns trigger
language plpgsql security definer set search_path='' as $$
declare enrolled_email text;
begin
 if new.email_confirmed_at is null or new.email is null then return new; end if;
 delete from saas_private.platform_admin_enrollments where email=lower(new.email) returning email into enrolled_email;
 if enrolled_email is not null then
  insert into public.saas_platform_admins(user_id) values(new.id) on conflict(user_id) do nothing;
 end if;
 return new;
end $$;
revoke all on function saas_private.enroll_platform_admin() from public,anon,authenticated;
drop trigger if exists saas_platform_owner_enrollment on auth.users;
create trigger saas_platform_owner_enrollment after insert or update of email,email_confirmed_at on auth.users
for each row execute function saas_private.enroll_platform_admin();

-- An unverified account from the preceding bootstrap must wait for verification.
delete from public.saas_platform_admins a using auth.users u
where a.user_id=u.id and lower(u.email)='aletomiwa@gmail.com' and u.email_confirmed_at is null;

insert into saas_private.platform_admin_enrollments(email) values('aletomiwa@gmail.com') on conflict(email) do nothing;
-- Also support an account that became verified between the previous release and this one.
insert into public.saas_platform_admins(user_id)
select u.id from auth.users u join saas_private.platform_admin_enrollments e on e.email=lower(u.email)
where u.email_confirmed_at is not null on conflict(user_id) do nothing;
delete from saas_private.platform_admin_enrollments e where exists(
 select 1 from auth.users u join public.saas_platform_admins a on a.user_id=u.id
 where lower(u.email)=e.email and u.email_confirmed_at is not null
);
