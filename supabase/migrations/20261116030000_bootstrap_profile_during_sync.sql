begin;

-- The identity sync used to UPDATE profiles only. If the project's Auth
-- profile-creation trigger was missing or had been removed, first-time users
-- could authenticate but never get the row required by profile setup.
do $$
begin
  if to_regprocedure('public.sync_my_college_profile_existing()') is null then
    execute 'alter function public.sync_my_college_profile() rename to sync_my_college_profile_existing';
  end if;
end;
$$;

create or replace function public.sync_my_college_profile()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  mail text;
  initial_role text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select lower(u.email)
  into mail
  from auth.users as u
  where u.id = uid
    and u.email_confirmed_at is not null
    and (u.raw_app_meta_data->'providers') ? 'google';

  if mail is null then
    raise exception 'Verified Google account required' using errcode = '42501';
  elsif mail = '25mc1pr108@mitsgwl.ac.in' then
    -- Temporary, explicitly requested test Super Admin account.
    initial_role := 'super_admin';
  elsif mail ~ '^[^@]+@mitsgwalior[.]in$' then
    initial_role := 'faculty';
  elsif mail ~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    initial_role := 'student';
  else
    raise exception 'Use a verified MITS student or faculty Google account'
      using errcode = '42501';
  end if;

  insert into public.profiles(id, anon_username, role)
  values (
    uid,
    'Anon' || left(replace(uid::text, '-', ''), 10),
    initial_role
  )
  on conflict (id) do nothing;

  -- Preserve the existing verified-email branch/year/enrollment logic and
  -- historical identity repair after ensuring that the profile row exists.
  perform public.sync_my_college_profile_existing();

  -- The explicitly designated test account remains Super Admin even when its
  -- profile row existed before this bootstrap migration was installed.
  if mail = '25mc1pr108@mitsgwl.ac.in' then
    update public.profiles set role = 'super_admin' where id = uid;
  end if;
end;
$$;

revoke all on function public.sync_my_college_profile_existing()
  from public, anon, authenticated;
revoke all on function public.sync_my_college_profile()
  from public, anon, authenticated;
grant execute on function public.sync_my_college_profile()
  to authenticated;

notify pgrst, 'reload schema';
commit;
