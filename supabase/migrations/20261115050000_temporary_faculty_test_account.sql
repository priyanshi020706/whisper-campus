begin;

-- TEMPORARY TEST ALLOWLIST: grants faculty capabilities to this confirmed Google account.
-- Remove this exception after testing; do not keep it for production.
do $migration$
declare
  fn record;
  definition text;
  old_faculty_pattern text := $faculty$^[^@]+@mitsgwalior[.]in$$faculty$;
  new_faculty_pattern text := $faculty$(^25mc1pr108@mitsgwl[.]ac[.]in$|^[^@]+@mitsgwalior[.]in$)$faculty$;
  old_mits_pattern text := $mits$^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$$mits$;
  new_mits_pattern text := $mits$(^25mc1pr108@mitsgwl[.]ac[.]in$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)$mits$;
  updated_count integer := 0;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and (p.prosrc like '%' || old_faculty_pattern || '%'
        or p.prosrc like '%' || old_mits_pattern || '%')
  loop
    definition := pg_get_functiondef(fn.oid);
    definition := replace(definition, old_faculty_pattern, new_faculty_pattern);
    definition := replace(definition, old_mits_pattern, new_mits_pattern);
    execute definition;
    updated_count := updated_count + 1;
  end loop;

  if updated_count = 0 then
    raise exception 'No MITS domain checks were updated; apply the linked Google identity migration first';
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

notify pgrst, 'reload schema';
commit;
