begin;

-- TEMPORARY TEST OVERRIDE: this verified MITS Google account gets faculty role.
-- Remove this exception after testing. The role remains server-assigned.
do $migration$
declare
  fn record;
  definition text;
  updated_count integer := 0;
  already_current boolean := false;
  faculty_regex text := '(^25mc1pr108@mitsgwl[.]ac[.]in$|^[^@]+@mitsgwalior[.]in$)';
  accepted_regex text := '(^25mc1pr108@mitsgwl[.]ac[.]in$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)';
begin
  -- Update both the original domain rules and any Gmail test exception that
  -- may already have been applied. Exact-match the requested MITS account.
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and (p.prosrc like '%@mitsgwalior[.]in%'
        or p.prosrc like '%@mitsgwl[.]ac[.]in%'
        or p.prosrc like '%priyanshisoni2706@gmail%'
        or p.prosrc like '%25mc1pr108@mitsgwl[.]ac[.]in%')
  loop
    definition := pg_get_functiondef(fn.oid);
    definition := replace(definition,
      '(^priyanshisoni2706@gmail[.]com$|^[^@]+@mitsgwalior[.]in$)', faculty_regex);
    definition := replace(definition,
      '^[^@]+@mitsgwalior[.]in$', faculty_regex);
    definition := replace(definition,
      '(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)', accepted_regex);
    definition := replace(definition,
      '^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$', accepted_regex);
    definition := replace(definition,
      'priyanshisoni2706@gmail.com', '25mc1pr108@mitsgwl.ac.in');
    if definition is distinct from pg_get_functiondef(fn.oid) then
      execute definition;
      updated_count := updated_count + 1;
    elsif definition like '%25mc1pr108@mitsgwl[.]ac[.]in%' then
      already_current := true;
    end if;
  end loop;

  if updated_count = 0 and not already_current then
    raise exception 'No official identity functions were updated; inspect deployed definitions before continuing';
  end if;
end
$migration$;

drop policy if exists "Official users can like posts as themselves" on public.official_post_likes;
create policy "Official users can like posts as themselves"
  on public.official_post_likes for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from auth.users u join public.profiles p on p.id = u.id
      where u.id = auth.uid()
        and u.email_confirmed_at is not null
        and (u.raw_app_meta_data->'providers') ? 'google'
        and (lower(u.email) = '25mc1pr108@mitsgwl.ac.in'
          or lower(u.email) ~ '^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$')
        and p.role in ('student', 'faculty', 'super_admin')
    )
  );

drop policy if exists "Official users can remove their likes" on public.official_post_likes;
create policy "Official users can remove their likes"
  on public.official_post_likes for delete to authenticated
  using (
    user_id = auth.uid()
    and exists (
      select 1 from auth.users u join public.profiles p on p.id = u.id
      where u.id = auth.uid()
        and u.email_confirmed_at is not null
        and (u.raw_app_meta_data->'providers') ? 'google'
        and (lower(u.email) = '25mc1pr108@mitsgwl.ac.in'
          or lower(u.email) ~ '^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$')
        and p.role in ('student', 'faculty', 'super_admin')
    )
  );

drop policy if exists "Official users can reply as themselves" on public.official_post_replies;
create policy "Official users can reply as themselves"
  on public.official_post_replies for insert to authenticated
  with check (
    author_id = auth.uid()
    and exists (
      select 1 from auth.users u join public.profiles p on p.id = u.id
      where u.id = auth.uid()
        and u.email_confirmed_at is not null
        and (u.raw_app_meta_data->'providers') ? 'google'
        and (lower(u.email) = '25mc1pr108@mitsgwl.ac.in'
          or lower(u.email) ~ '^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$')
        and p.role in ('student', 'faculty', 'super_admin')
    )
  );

-- Promote only the matching, verified Google identity. Client role updates remain revoked.
update public.profiles p
set role = 'faculty', branch_code = null, department = null,
    academic_year = null, enrollment_number = null
from auth.users u
where p.id = u.id
  and lower(u.email) = '25mc1pr108@mitsgwl.ac.in'
  and u.email_confirmed_at is not null
  and (u.raw_app_meta_data->'providers') ? 'google';

notify pgrst, 'reload schema';
commit;
