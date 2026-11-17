-- Fakes the parts of Supabase the migrations rely on, so everything runs on a plain PostgreSQL:
--   * the `anon` and `authenticated` roles
--   * auth.users and auth.uid() (reads the "request.jwt.claim.sub" setting, as Supabase does)
-- Not needed (and must not be applied) on a real Supabase project.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

grant usage on schema public, auth to anon, authenticated;
-- Supabase grants new tables and functions to its API roles by default. Mirror that, so the
-- tests prove the migrations' own REVOKEs and RLS policies are what protect the data.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
