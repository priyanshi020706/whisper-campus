begin;

-- Google identity names can be stored as "BTMC25O1108 Priyanshi Soni".
-- Keep the enrollment as a separate field and expose only the person's name.
create or replace function public.my_google_name()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  with source_name as (
    select nullif(btrim(regexp_replace(
      coalesce(
        nullif(btrim(i.identity_data->>'full_name'), ''),
        nullif(btrim(i.identity_data->>'name'), ''),
        ''
      ),
      '[[:space:]]+', ' ', 'g'
    )), '') as value
    from auth.identities as i
    where i.user_id = auth.uid()
      and i.provider = 'google'
    order by i.created_at nulls last
    limit 1
  ), cleaned as (
    select case
      when value ~* '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}[[:space:]]+.+$'
        then btrim(regexp_replace(
          value,
          '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}[[:space:]]+',
          '', 'i'
        ))
      when value ~* '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}$'
        then null
      else value
    end as value
    from source_name
  )
  select left(nullif(value, ''), 120) from cleaned;
$$;

revoke all on function public.my_google_name() from public, anon;
grant execute on function public.my_google_name() to authenticated;

create or replace function public.my_google_enrollment()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select (regexp_match(
    regexp_replace(
      coalesce(
        nullif(btrim(i.identity_data->>'full_name'), ''),
        nullif(btrim(i.identity_data->>'name'), ''),
        ''
      ),
      '[[:space:]]+', ' ', 'g'
    ),
    '^(BT[A-Z]{2}[0-9]{2}O1[0-9]{3})([[:space:]]|$)',
    'i'
  ))[1]
  from auth.identities as i
  where i.user_id = auth.uid()
    and i.provider = 'google'
  order by i.created_at nulls last
  limit 1;
$$;

revoke all on function public.my_google_enrollment() from public, anon;
grant execute on function public.my_google_enrollment() to authenticated;

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
  google_enrollment text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  google_name := public.my_google_name();
  google_enrollment := public.my_google_enrollment();

  return query
  select google_name, coalesce(google_enrollment, p.enrollment_number),
         p.branch_code, p.department, p.academic_year, p.role
  from public.profiles as p
  where p.id = uid;

  if not found then
    return query
    select google_name, google_enrollment, null::text, null::text,
           null::integer, null::text;
  end if;
end;
$$;

revoke all on function public.get_my_college_details() from public, anon;
grant execute on function public.get_my_college_details() to authenticated;

-- Keep the existing RPC contract and server-side identity checks. Null bio
-- means "leave it unchanged" so sign-in sync never erases a saved bio.
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
  google_enrollment text;
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
  google_enrollment := public.my_google_enrollment();
  display_name := coalesce(
    google_name,
    nullif(concat_ws(' ', nullif(first_name, ''), nullif(last_name, '')), '')
  );

  insert into public.identity_records as existing_identity(user_id, real_name)
  values (uid, display_name)
  on conflict (user_id) do update
    set real_name = coalesce(excluded.real_name, existing_identity.real_name);

  update public.profiles as profile
  set profile_completed = true,
      enrollment_number = case
        when google_enrollment is not null and not exists (
          select 1 from public.profiles as other_profile
          where other_profile.enrollment_number = google_enrollment
            and other_profile.id <> uid
        ) then google_enrollment
        else profile.enrollment_number
      end,
      bio = case
        when p_bio is null then profile.bio
        else nullif(btrim(p_bio), '')
      end
  where profile.id = uid;
  get diagnostics updated_rows = row_count;
  if updated_rows <> 1 then
    raise exception 'Campus profile row missing; sign out and sign in again' using errcode = 'P0002';
  end if;
end;
$$;

-- Backfill current verified Google accounts. Enrollment is updated only when
-- the Google display name contains a valid, unique enrollment number.
with google_rows as (
  select distinct on (user_row.id)
    user_row.id,
    lower(user_row.email) as email,
    nullif(btrim(regexp_replace(
      coalesce(
        nullif(btrim(identity.identity_data->>'full_name'), ''),
        nullif(btrim(identity.identity_data->>'name'), ''),
        ''
      ),
      '[[:space:]]+', ' ', 'g'
    )), '') as raw_name
  from auth.users as user_row
  join auth.identities as identity
    on identity.user_id = user_row.id and identity.provider = 'google'
  where user_row.email_confirmed_at is not null
    and (user_row.raw_app_meta_data->'providers') ? 'google'
    and (
      lower(user_row.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
      or lower(user_row.email) ~ '^[^@]+@mitsgwalior[.]in$'
      or lower(user_row.email) = '25mc1pr108@mitsgwl.ac.in'
    )
  order by user_row.id, identity.created_at nulls last
), parsed as (
  select id, email, raw_name,
    case
      when raw_name ~* '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}[[:space:]]+.+$'
        then btrim(regexp_replace(
          raw_name,
          '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}[[:space:]]+',
          '', 'i'
        ))
      when raw_name ~* '^BT[A-Z]{2}[0-9]{2}O1[0-9]{3}$'
        then null
      else raw_name
    end as real_name,
    (regexp_match(raw_name,
      '^(BT[A-Z]{2}[0-9]{2}O1[0-9]{3})([[:space:]]|$)', 'i'))[1]
      as google_enrollment
  from google_rows
), named as (
  insert into public.identity_records(user_id, real_name)
  select id, left(real_name, 120)
  from parsed
  where real_name is not null and real_name <> ''
  on conflict (user_id) do update
    set real_name = excluded.real_name
  returning user_id
), unique_enrollments as (
  select google_enrollment
  from parsed
  where google_enrollment is not null
  group by google_enrollment
  having count(*) = 1
)
update public.profiles as profile
set enrollment_number = parsed.google_enrollment,
    profile_completed = true
from parsed
join unique_enrollments
  on unique_enrollments.google_enrollment = parsed.google_enrollment
where profile.id = parsed.id
  and profile.role in ('student', 'faculty', 'super_admin')
  and not exists (
    select 1 from public.profiles as other_profile
    where other_profile.enrollment_number = parsed.google_enrollment
      and other_profile.id <> profile.id
  );

-- Complete the setup state for all other verified accounts as well; no form
-- fields are required to enter the app anymore.
update public.profiles as profile
set profile_completed = true
from auth.users as user_row
where user_row.id = profile.id
  and profile.role in ('student', 'faculty', 'super_admin')
  and user_row.email_confirmed_at is not null
  and (user_row.raw_app_meta_data->'providers') ? 'google'
  and (
    lower(user_row.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
    or lower(user_row.email) ~ '^[^@]+@mitsgwalior[.]in$'
    or lower(user_row.email) = '25mc1pr108@mitsgwl.ac.in'
  );

notify pgrst, 'reload schema';
commit;
