begin;

-- A student email whose local part does not match the enrollment pattern
-- should still be able to finish their name setup. Branch/year/enrollment
-- remain unset by sync_my_college_profile in that case.
create or replace function public.save_my_identity(
  p_first_name text,
  p_last_name text,
  p_bio text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  mail text;
  first_name text := btrim(coalesce(p_first_name, ''));
  last_name text := btrim(coalesce(p_last_name, ''));
  current_role text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select lower(user_row.email) into mail
  from auth.users as user_row
  where user_row.id = uid
    and user_row.email_confirmed_at is not null
    and (user_row.raw_app_meta_data->'providers') ? 'google';
  if mail is null or not (
    mail ~ '^[^@]+@mitsgwl[.]ac[.]in$'
    or mail ~ '^[^@]+@mitsgwalior[.]in$'
    or mail = '25mc1pr108@mitsgwl.ac.in'
  ) then
    raise exception 'Verified MITS Google account required' using errcode = '42501';
  end if;
  select profile.role into current_role
  from public.profiles as profile
  where profile.id = uid;
  if current_role is null or current_role not in ('student', 'faculty', 'super_admin') then
    raise exception 'Campus profile sync required' using errcode = '42501';
  end if;
  if char_length(first_name) not between 1 and 60
      or char_length(last_name) not between 1 and 60 then
    raise exception 'Enter first and last name';
  end if;

  insert into public.identity_records(user_id, real_name)
  values (uid, first_name || ' ' || last_name)
  on conflict (user_id) do update set real_name = excluded.real_name;

  update public.profiles
  set profile_completed = true,
      bio = nullif(btrim(coalesce(p_bio, '')), '')
  where id = uid;
end;
$$;

revoke all on function public.save_my_identity(text, text, text)
  from public, anon, authenticated;
grant execute on function public.save_my_identity(text, text, text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
