begin;

-- The student's name now comes from their MITS Google account, not from a form.
--
-- * public.get_my_college_details() gives the app what it needs to show the
--   "your details" card on first sign-in: the Google name plus the enrollment
--   number, branch and year that sync_my_college_profile() already derived from
--   the college email.
-- * save_my_identity() and save_my_faculty_profile() ignore the name typed by
--   the client whenever Google supplied one. The name is read from
--   auth.identities (written by Google at sign-in), NOT from
--   auth.users.raw_user_meta_data, because users can edit their own user
--   metadata with auth.updateUser. If Google gave no name at all, the typed
--   name is still accepted, so nobody is blocked.
--
-- Function signatures are unchanged, so existing grants stay in place.
--
-- This also fixes "Profile save failed (42501): Campus profile sync required".
-- The previous save_my_identity() kept the student's role in a variable named
-- current_role. That is a reserved SQL keyword (the database login role), so
-- the check compared "authenticated" to the allowed roles and always failed.
-- The variable is now called profile_role.

create or replace function public.my_google_name()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select left(
    nullif(btrim(regexp_replace(
      coalesce(
        nullif(btrim(i.identity_data->>'full_name'), ''),
        nullif(btrim(i.identity_data->>'name'), ''),
        ''
      ),
      '\s+', ' ', 'g'
    )), ''),
    120
  )
  from auth.identities as i
  where i.user_id = auth.uid()
    and i.provider = 'google'
  order by i.created_at nulls last
  limit 1;
$$;

revoke all on function public.my_google_name() from public, anon;
grant execute on function public.my_google_name() to authenticated;

create or replace function public.get_my_college_details()
returns table(
  full_name text,
  enrollment_number text,
  branch_code text,
  department text,
  academic_year integer,
  role text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  google_name text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  google_name := public.my_google_name();

  return query
  select google_name, p.enrollment_number, p.branch_code, p.department,
         p.academic_year, p.role
  from public.profiles as p
  where p.id = uid;

  -- No profile row yet: still return the Google name so the form can show it.
  if not found then
    return query
    select google_name, null::text, null::text, null::text, null::integer, null::text;
  end if;
end;
$$;

revoke all on function public.get_my_college_details() from public, anon;
grant execute on function public.get_my_college_details() to authenticated;

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
  google_name text;
  display_name text;
  profile_role text;
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

  select profile.role into profile_role
  from public.profiles as profile
  where profile.id = uid;

  if profile_role is null or profile_role not in ('student', 'faculty', 'super_admin') then
    raise exception 'Campus profile sync required' using errcode = '42501';
  end if;
  if char_length(first_name) > 60 or char_length(last_name) > 60 then
    raise exception 'Names must be 60 characters or fewer';
  end if;

  google_name := public.my_google_name();
  display_name := coalesce(
    google_name,
    nullif(concat_ws(' ', nullif(first_name, ''), nullif(last_name, '')), '')
  );

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
  google_name text;
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

  google_name := public.my_google_name();
  display_name := coalesce(
    google_name,
    nullif(concat_ws(' ', nullif(first_name, ''), nullif(last_name, '')), '')
  );

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

notify pgrst, 'reload schema';
commit;
