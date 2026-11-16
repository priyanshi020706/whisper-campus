-- Moves the hardcoded Super Admin email out of function and policy bodies and
-- into one table, so admins are added with an INSERT instead of a new migration.
--
-- Behaviour does not change: the same account stays Super Admin. Review on a
-- Supabase branch first, because the DO block rewrites deployed function
-- bodies and policy expressions in place.
begin;

create table if not exists public.platform_admins (
  email text primary key check (email = lower(btrim(email))),
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;
revoke all on table public.platform_admins from public, anon, authenticated;

insert into public.platform_admins (email)
values ('25mc1pr108@mitsgwl.ac.in')
on conflict (email) do nothing;

create or replace function public.is_platform_admin_email(p_email text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_admins as admin_row
    where admin_row.email = lower(btrim(coalesce(p_email, '')))
  );
$$;

revoke all on function public.is_platform_admin_email(text) from public, anon;
grant execute on function public.is_platform_admin_email(text) to authenticated;

do $migration$
declare
  fn record;
  pol record;
  old_def text;
  new_def text;
  expr_using text;
  expr_check text;
  patched_functions integer := 0;
  patched_policies integer := 0;
  email_literal constant text := '25mc1pr108@mitsgwl\.ac\.in';
  -- lower(u.email) = '<email>'  (as written in function source)
  src_lower constant text :=
    'lower\(\s*([a-z_]+\.email)\s*\)\s*=\s*''' || email_literal || '''';
  -- mail = '<email>'
  src_mail constant text := '\mmail\s*=\s*''' || email_literal || '''';
  -- lower((u.email)::text) = '<email>'::text  (as Postgres prints policies)
  pol_lower constant text :=
    'lower\(\(([a-z_]+\.email)\)::text\)\s*=\s*''' || email_literal || '''::text';
begin
  for fn in
    select p.oid, p.proname
    from pg_proc as p
    join pg_namespace as n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosrc like '%25mc1pr108@mitsgwl.ac.in%'
      and p.proname <> 'is_platform_admin_email'
  loop
    old_def := pg_get_functiondef(fn.oid);
    new_def := regexp_replace(old_def, src_lower,
      'public.is_platform_admin_email(\1)', 'g');
    new_def := regexp_replace(new_def, src_mail,
      'public.is_platform_admin_email(mail)', 'g');
    if new_def is distinct from old_def then
      execute new_def;
      patched_functions := patched_functions + 1;
    end if;
  end loop;

  for pol in
    select schemaname, tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
      and (coalesce(qual, '') like '%25mc1pr108@mitsgwl.ac.in%'
        or coalesce(with_check, '') like '%25mc1pr108@mitsgwl.ac.in%')
  loop
    expr_using := case when pol.qual is null then null
      else regexp_replace(pol.qual, pol_lower,
        'public.is_platform_admin_email((\1)::text)', 'g') end;
    expr_check := case when pol.with_check is null then null
      else regexp_replace(pol.with_check, pol_lower,
        'public.is_platform_admin_email((\1)::text)', 'g') end;
    if expr_using is distinct from pol.qual
        or expr_check is distinct from pol.with_check then
      execute format('alter policy %I on %I.%I%s%s',
        pol.policyname, pol.schemaname, pol.tablename,
        case when expr_using is null then '' else ' using (' || expr_using || ')' end,
        case when expr_check is null then '' else ' with check (' || expr_check || ')' end);
      patched_policies := patched_policies + 1;
    end if;
  end loop;

  raise notice 'platform_admin_allowlist: % functions and % policies rewritten',
    patched_functions, patched_policies;

  -- Anything the patterns above could not safely rewrite is listed so it can
  -- be fixed by hand instead of silently keeping the hardcoded email.
  for fn in
    select p.proname
    from pg_proc as p
    join pg_namespace as n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosrc like '%25mc1pr108@mitsgwl.ac.in%'
      and p.proname <> 'is_platform_admin_email'
  loop
    raise warning 'Still hardcodes the admin email: function public.%', fn.proname;
  end loop;
  for pol in
    select tablename, policyname from pg_policies
    where schemaname = 'public'
      and (coalesce(qual, '') like '%25mc1pr108@mitsgwl.ac.in%'
        or coalesce(with_check, '') like '%25mc1pr108@mitsgwl.ac.in%')
  loop
    raise warning 'Still hardcodes the admin email: policy % on public.%',
      pol.policyname, pol.tablename;
  end loop;
end
$migration$;

notify pgrst, 'reload schema';
commit;
