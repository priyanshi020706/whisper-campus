begin;

-- Email local-part structure:
-- YY + branch(2) + digit + suffix(2) + roll(1..3 digits).
-- Enrollment numbers always store the roll as exactly three digits.
do $$
declare
  fn oid;
  definition text;
  changed text;
begin
  select p.oid into fn
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'sync_my_college_profile_existing'
    and p.pronargs = 0;

  if fn is null then
    raise exception 'Existing profile sync function was not found';
  end if;

  definition := pg_get_functiondef(fn);
  changed := replace(
    definition,
    '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$',
    '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{1,3}$'
  );
  changed := replace(
    changed,
    'right(lp,3)',
    'lpad(substring(lp from 8),3,''0'')'
  );
  changed := replace(
    changed,
    'right(split_part(mail,''@'',1),3)',
    'lpad(substring(split_part(mail,''@'',1) from 8),3,''0'')'
  );

  if changed = definition
      or changed like '%[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$%'
      or changed like '%right(lp,3)%' then
    raise exception 'Could not update enrollment parsing in the profile sync function';
  end if;
  execute changed;
end;
$$;

-- Keep the moderator search roll field raw (89 stays 89), while enrollment
-- prefix searches use the padded value (089). One-to-three digit roll prefixes
-- can be searched as the user types; names still require at least 3 characters.
create or replace function public.search_students(
  p_query text,
  p_branch_code text default null,
  p_mode text default 'official'
)
returns table(
  student_id uuid,
  student_name text,
  branch_code text,
  branch_name text,
  study_year int,
  enrollment_number text,
  roll_number text
)
language plpgsql stable security definer set search_path = '' as $$
declare
  q text := btrim(coalesce(p_query, ''));
begin
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown campus mode';
  end if;
  if not (public.is_super_admin(auth.uid())
      or (p_mode = 'official' and public.is_faculty(auth.uid()))) then
    raise exception 'You cannot search students for this campus mode' using errcode = '42501';
  end if;
  if q = '' then return; end if;

  return query
  select p.id,
    coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    p.branch_code,
    p.department,
    p.academic_year,
    p.enrollment_number,
    substring(split_part(lower(u.email), '@', 1) from 8)::text
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.identity_records i on i.user_id = p.id
  where p.role = 'student'
    and p.enrollment_number is not null
    and (p_branch_code is null or upper(p.branch_code) = upper(p_branch_code))
    and (
      p.enrollment_number like upper(q) || '%'
      or (char_length(q) >= 3 and i.real_name ilike '%' || q || '%')
      or (q ~ '^[0-9]{1,3}$'
        and substring(split_part(lower(u.email), '@', 1) from 8) like q || '%')
    )
  order by case when p.enrollment_number like upper(q) || '%' then 0 else 1 end,
    i.real_name
  limit 20;
end;
$$;

-- Show the same raw roll number in the current-moderators list.
create or replace function public.list_room_moderators(
  p_room_id text,
  p_mode text default 'official'
)
returns table(
  student_id uuid,
  student_name text,
  branch_code text,
  branch_name text,
  study_year int,
  enrollment_number text,
  roll_number text,
  ends_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_super_admin(auth.uid())
      or (p_mode = 'official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator list access required' using errcode = '42501';
  end if;
  return query
  select p.id,
    coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    p.branch_code,
    p.department,
    p.academic_year,
    p.enrollment_number,
    substring(split_part(lower(u.email), '@', 1) from 8)::text,
    m.ends_at
  from public.room_moderators m
  join public.profiles p on p.id = m.student_id
  join auth.users u on u.id = p.id
  left join public.identity_records i on i.user_id = p.id
  where m.room_id = p_room_id
    and m.room_mode = p_mode
    and m.active
    and m.starts_at <= now()
    and (m.ends_at is null or m.ends_at > now())
  order by i.real_name;
end;
$$;

-- Populate branch/year/enrollment for existing student profiles with the
-- corrected variable-length roll format. Abort clearly if uniqueness would be
-- violated instead of silently assigning the same enrollment to two users.
do $$
begin
  if exists (
    with parsed as (
      select p.id,
        'BT' || upper(substring(local_part from 3 for 2)) ||
          substring(local_part from 1 for 2) || 'O1' ||
          lpad(substring(local_part from 8), 3, '0') as enrollment_number
      from public.profiles p
      join auth.users u on u.id = p.id
      cross join lateral (select split_part(lower(u.email), '@', 1) as local_part) email_parts
      where lower(u.email) ~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{1,3}@mitsgwl[.]ac[.]in$'
        and u.email_confirmed_at is not null
        and (u.raw_app_meta_data->'providers') ? 'google'
        and p.role in ('student', 'super_admin')
    )
    select 1
    from parsed a
    join public.profiles existing
      on existing.enrollment_number = a.enrollment_number
      and existing.id <> a.id
  ) then
    raise exception 'An enrollment number is already assigned to another account; resolve the duplicate before syncing';
  end if;
end;
$$;

with parsed as (
  select p.id,
    substring(local_part from 1 for 2)::integer as yy,
    lower(substring(local_part from 3 for 2)) as branch,
    'BT' || upper(substring(local_part from 3 for 2)) ||
      substring(local_part from 1 for 2) || 'O1' ||
      lpad(substring(local_part from 8), 3, '0') as enrollment_number
  from public.profiles p
  join auth.users u on u.id = p.id
  cross join lateral (select split_part(lower(u.email), '@', 1) as local_part) email_parts
  where lower(u.email) ~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{1,3}@mitsgwl[.]ac[.]in$'
    and u.email_confirmed_at is not null
    and (u.raw_app_meta_data->'providers') ? 'google'
    and p.role in ('student', 'super_admin')
), mapped as (
  select parsed.*,
    case branch
      when 'ad' then 'AI & Data Science' when 'ai' then 'Artificial Intelligence'
      when 'am' then 'AI & Machine Learning' when 'cb' then 'CS & Business Systems'
      when 'cd' then 'CS & Design' when 'ce' then 'Civil Engineering'
      when 'cm' then 'Chemical Engineering' when 'cs' then 'Computer Science & Engg'
      when 'ec' then 'Electronics & Communication' when 'ee' then 'Electrical Engineering'
      when 'el' then 'Electronics Engineering' when 'et' then 'Electronics & Telecommunication'
      when 'io' then 'Internet of Things (IoT)' when 'ir' then 'IT (AI & Robotics)'
      when 'it' then 'Information Technology' when 'mc' then 'Mathematics & Computing'
      when 'me' then 'Mechanical Engineering' when 'tc' then 'CS & Technology'
      when 'ar' then 'Architecture (B.Arch)'
    end as department
  from parsed
), academic as (
  select mapped.*,
    extract(year from (now() at time zone 'Asia/Kolkata'))::integer
      - case when extract(month from (now() at time zone 'Asia/Kolkata')) < 7 then 1 else 0 end
      - (2000 + yy) + 1 as study_year
  from mapped
)
update public.profiles p
set branch_code = upper(academic.branch),
    department = academic.department,
    academic_year = academic.study_year,
    enrollment_number = academic.enrollment_number
from academic
where p.id = academic.id
  and academic.department is not null;

notify pgrst, 'reload schema';
commit;
