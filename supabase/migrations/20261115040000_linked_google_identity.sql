begin;

-- A linked Google identity may coexist with email as the account's primary provider.
-- Keep requiring a confirmed email, but check the trusted linked-provider list.
do $migration$
declare
  fn record;
  definition text;
  old_expression text := $old$u.raw_app_meta_data->>'provider'='google'$old$;
  new_expression text := $new$(u.raw_app_meta_data->'providers') ? 'google'$new$;
  updated_count integer := 0;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosrc like '%' || old_expression || '%'
  loop
    definition := pg_get_functiondef(fn.oid);
    definition := replace(definition, old_expression, new_expression);
    execute definition;
    updated_count := updated_count + 1;
  end loop;

  if updated_count = 0 then
    raise exception 'No Google-provider checks were updated; inspect deployed function definitions before continuing';
  end if;
end
$migration$;

-- Keep the row-level policies consistent with the corrected function checks.
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
        and lower(u.email) ~ '(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)'
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
        and lower(u.email) ~ '(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)'
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
        and lower(u.email) ~ '(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)'
        and p.role in ('student', 'faculty', 'super_admin')
    )
  );

notify pgrst, 'reload schema';
commit;