begin;

-- Names are optional during initial setup. Keep an existing name if the user
-- leaves both fields empty, while allowing a new user to finish setup nameless.
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
  display_name text;
  current_role text;
  updated_rows integer;
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
  if char_length(first_name) > 60 or char_length(last_name) > 60 then
    raise exception 'Names must be 60 characters or fewer';
  end if;

  display_name := nullif(concat_ws(' ', nullif(first_name, ''), nullif(last_name, '')), '');

  insert into public.identity_records as existing_identity(user_id, real_name)
  values (uid, display_name)
  on conflict (user_id) do update
    set real_name = coalesce(excluded.real_name, existing_identity.real_name);

  update public.profiles
  set profile_completed = true,
      bio = nullif(btrim(coalesce(p_bio, '')), '')
  where id = uid;
  get diagnostics updated_rows = row_count;
  if updated_rows <> 1 then
    raise exception 'Campus profile row missing; sign out and sign in again' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.save_my_faculty_profile(
  p_first_name text,
  p_last_name text,
  p_department_code text default null
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
  department_code text := nullif(lower(btrim(coalesce(p_department_code, ''))), '');
  department_name text;
  display_name text;
  updated_rows integer;
begin
  if uid is null or not public.is_faculty(uid) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;

  select lower(user_row.email) into mail
  from auth.users as user_row
  where user_row.id = uid
    and user_row.email_confirmed_at is not null
    and (user_row.raw_app_meta_data->'providers') ? 'google';
  if mail is null or not (
    mail ~ '^[^@]+@mitsgwalior[.]in$'
    or mail = '25mc1pr108@mitsgwl.ac.in'
  ) then
    raise exception 'Verified faculty Google account required' using errcode = '42501';
  end if;
  if char_length(first_name) > 60 or char_length(last_name) > 60 then
    raise exception 'Names must be 60 characters or fewer';
  end if;

  if department_code is not null then
    department_name := case department_code
      when 'ad' then 'AI & Data Science' when 'ai' then 'Artificial Intelligence'
      when 'am' then 'AI & Machine Learning' when 'cb' then 'CS & Business Systems'
      when 'cd' then 'CS & Design' when 'ce' then 'Civil Engineering'
      when 'cm' then 'Chemical Engineering' when 'cs' then 'Computer Science & Engg'
      when 'ec' then 'Electronics & Communication' when 'ee' then 'Electrical Engineering'
      when 'el' then 'Electronics Engineering' when 'et' then 'Electronics & Telecommunication'
      when 'io' then 'Internet of Things (IoT)' when 'ir' then 'IT (AI & Robotics)'
      when 'it' then 'Information Technology' when 'mc' then 'Mathematics & Computing'
      when 'me' then 'Mechanical Engineering' when 'tc' then 'CS & Technology'
      when 'ar' then 'Architecture (B.Arch)' end;
    if department_name is null then
      raise exception 'Unknown department';
    end if;
  end if;

  display_name := nullif(concat_ws(' ', nullif(first_name, ''), nullif(last_name, '')), '');
  insert into public.identity_records as existing_identity(user_id, real_name)
  values (uid, display_name)
  on conflict (user_id) do update
    set real_name = coalesce(excluded.real_name, existing_identity.real_name);

  update public.profiles
  set branch_code = case when department_code is null then branch_code else upper(department_code) end,
      department = case when department_code is null then department else department_name end,
      academic_year = null,
      enrollment_number = null,
      profile_completed = true
  where id = uid;
  get diagnostics updated_rows = row_count;
  if updated_rows <> 1 then
    raise exception 'Campus profile row missing; sign out and sign in again' using errcode = 'P0002';
  end if;
end;
$$;

-- Repair accounts that already have a verified identity row but were left in
-- the incomplete state. Their next app load can pass the profile setup gate.
update public.profiles as profile
set profile_completed = true
where profile.profile_completed = false
  and profile.role in ('student', 'faculty', 'super_admin')
  and exists (
    select 1
    from auth.users as user_row
    join public.identity_records as identity on identity.user_id = user_row.id
    where user_row.id = profile.id
      and user_row.email_confirmed_at is not null
      and (user_row.raw_app_meta_data->'providers') ? 'google'
      and (
        lower(user_row.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
        or lower(user_row.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(user_row.email) = '25mc1pr108@mitsgwl.ac.in'
      )
  );

notify pgrst, 'reload schema';
commit;
