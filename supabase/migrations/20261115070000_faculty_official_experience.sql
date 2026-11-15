begin;

-- Faculty capability is tied to a verified Google identity and the exact
-- faculty domain. The single student-domain exception remains temporary so
-- the current test account can exercise the faculty experience.
create or replace function public.is_faculty_account(p_uid uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.id = p_uid
      and p.role = 'faculty'
      and u.email_confirmed_at is not null
      and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email) = '25mc1pr108@mitsgwl.ac.in')
  );
$$;

create or replace function public.is_official_room(p_room_id text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.rooms r
    where r.id = p_room_id
      and (r.id in ('general', 'official-live') or r.id like 'dept-%')
  );
$$;

create or replace function public.sync_my_college_profile()
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  mail text;
  local_part text;
  year_digits integer;
  branch text;
  department_name text;
  academic_start integer;
  study_year integer;
  existing_role text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select lower(u.email) into mail
  from auth.users u
  where u.id = uid and u.email_confirmed_at is not null
    and (u.raw_app_meta_data->'providers') ? 'google';
  if mail is null then
    raise exception 'Verified Google account required' using errcode = '42501';
  end if;

  select p.role into existing_role from public.profiles p where p.id = uid;
  if mail ~ '^[^@]+@mitsgwalior[.]in$'
      or mail = '25mc1pr108@mitsgwl.ac.in' then
    update public.profiles
    set role = case when existing_role = 'super_admin' then existing_role else 'faculty' end,
        academic_year = null,
        enrollment_number = null
    where id = uid;
    return;
  end if;

  if mail !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'Use a verified MITS student or faculty Google account'
      using errcode = '42501';
  end if;

  local_part := split_part(mail, '@', 1);
  if local_part !~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$' then
    update public.profiles
    set role = case when existing_role = 'super_admin' then existing_role else 'student' end,
        branch_code = null, department = null, academic_year = null,
        enrollment_number = null
    where id = uid;
    return;
  end if;

  year_digits := substring(local_part, 1, 2)::integer;
  branch := substring(local_part, 3, 2);
  department_name := case branch
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
    raise exception 'Unknown branch code in MITS student email';
  end if;

  academic_start := extract(year from current_date)::integer
    - case when extract(month from current_date) < 7 then 1 else 0 end;
  study_year := academic_start - (2000 + year_digits) + 1;
  update public.profiles
  set role = case when existing_role = 'super_admin' then existing_role else 'student' end,
      branch_code = upper(branch), department = department_name,
      academic_year = study_year,
      enrollment_number = null
  where id = uid;
end;
$$;

create or replace function public.save_my_faculty_profile(
  p_first_name text,
  p_last_name text,
  p_department_code text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  mail text;
  first_name text := btrim(coalesce(p_first_name, ''));
  last_name text := btrim(coalesce(p_last_name, ''));
  department_code text := nullif(lower(btrim(coalesce(p_department_code, ''))), '');
  department_name text;
begin
  if uid is null or not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  select lower(u.email) into mail
  from auth.users u
  where u.id = uid and u.email_confirmed_at is not null
    and (u.raw_app_meta_data->'providers') ? 'google';
  if mail is null or not (mail ~ '^[^@]+@mitsgwalior[.]in$'
      or mail = '25mc1pr108@mitsgwl.ac.in') then
    raise exception 'Verified faculty Google account required' using errcode = '42501';
  end if;
  if char_length(first_name) not between 1 and 60
      or char_length(last_name) not between 1 and 60 then
    raise exception 'Enter first and last name';
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
    if department_name is null then raise exception 'Unknown department'; end if;
  end if;

  insert into public.identity_records(user_id, real_name)
  values(uid, first_name || ' ' || last_name)
  on conflict(user_id) do update set real_name = excluded.real_name;
  update public.profiles
  set branch_code = case when department_code is null then null else upper(department_code) end,
      department = department_name,
      academic_year = null,
      enrollment_number = null,
      profile_completed = true
  where id = uid;
end;
$$;

create or replace function public.list_faculty_rooms()
returns table(room_id text, room_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  return query
  select r.id, r.name
  from public.rooms r
  where public.is_official_room(r.id)
  order by r.name;
end;
$$;

-- Keep the search RPC shape compatible while returning a roll number from the
-- verified student email. Enrollment numbers remain unused for now.
drop function if exists public.search_students(text, text);
create function public.search_students(p_query text, p_branch_code text default null)
returns table(
  student_id uuid,
  student_name text,
  branch_code text,
  branch_name text,
  study_year int,
  roll_number text
)
language plpgsql stable security definer set search_path = '' as $$
declare q text := btrim(coalesce(p_query, ''));
begin
  if not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  if char_length(q) < 3 then raise exception 'Enter at least 3 characters'; end if;
  return query
  select p.id,
    coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    p.branch_code, p.department, p.academic_year,
    right(split_part(lower(u.email), '@', 1), 3)::text
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.identity_records i on i.user_id = p.id
  where p.role = 'student'
    and lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
    and (p_branch_code is null or upper(p.branch_code) = upper(p_branch_code))
    and (i.real_name ilike '%' || q || '%'
      or right(split_part(lower(u.email), '@', 1), 3) ilike '%' || q || '%')
  order by i.real_name
  limit 20;
end;
$$;

create or replace function public.assign_room_moderator(
  p_room_id text, p_student_id uuid, p_ends_at timestamptz default null
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  if not public.is_official_room(p_room_id) then
    raise exception 'Moderators can only be assigned to Official rooms';
  end if;
  if not exists(select 1 from public.profiles where id = p_student_id and role = 'student') then
    raise exception 'Only students can moderate';
  end if;
  if p_ends_at is not null and p_ends_at <= now() then
    raise exception 'End date must be in the future';
  end if;
  insert into public.room_moderators(room_id, student_id, assigned_by, ends_at)
  values(p_room_id, p_student_id, auth.uid(), p_ends_at)
  on conflict(room_id, student_id) do update
    set assigned_by = excluded.assigned_by, starts_at = now(),
        ends_at = excluded.ends_at, active = true;
  insert into public.room_moderator_audit(room_id, student_id, changed_by, action, ends_at)
  values(p_room_id, p_student_id, auth.uid(), 'assigned', p_ends_at);
end;
$$;

create or replace function public.remove_room_moderator(p_room_id text, p_student_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  if not public.is_official_room(p_room_id) then
    raise exception 'Only Official room moderators can be removed here';
  end if;
  update public.room_moderators set active = false
  where room_id = p_room_id and student_id = p_student_id;
  insert into public.room_moderator_audit(room_id, student_id, changed_by, action)
  values(p_room_id, p_student_id, auth.uid(), 'removed');
end;
$$;

create or replace function public.block_room_user(
  p_room_id text, p_user_id uuid, p_reason text
)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  ends timestamptz := now() + interval '3 days';
  actor_is_faculty boolean := public.is_faculty(auth.uid());
begin
  if p_room_id <> 'official-live' then
    raise exception 'Live chat moderation is available only in Official Campus Live';
  end if;
  if not (actor_is_faculty or public.is_active_room_moderator(p_room_id, auth.uid())) then
    raise exception 'Room moderator access required' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A warning reason is required';
  end if;
  if p_user_id = auth.uid() then raise exception 'You cannot remove yourself'; end if;
  if not actor_is_faculty and
      (public.is_faculty(p_user_id) or public.is_active_room_moderator(p_room_id, p_user_id)) then
    raise exception 'Moderators cannot block faculty or another moderator';
  end if;
  if not exists(select 1 from public.profiles
      where id = p_user_id and role in ('student', 'faculty', 'super_admin')) then
    raise exception 'Official account required';
  end if;
  insert into public.room_blocks(room_id, user_id, blocked_by, reason, ends_at)
  values(p_room_id, p_user_id, auth.uid(), left(btrim(p_reason), 500), ends)
  on conflict(room_id, user_id) do update
    set blocked_by = excluded.blocked_by, reason = excluded.reason,
        ends_at = excluded.ends_at, created_at = now();
  update public.room_sessions set left_at = now()
  where room_id = p_room_id and user_id = p_user_id and left_at is null;
  return ends;
end;
$$;

drop function if exists public.list_room_moderators(text);
create function public.list_room_moderators(p_room_id text)
returns table(
  student_id uuid,
  student_name text,
  branch_code text,
  branch_name text,
  study_year int,
  roll_number text,
  ends_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_faculty(auth.uid()) then
    raise exception 'Faculty access required' using errcode = '42501';
  end if;
  if not public.is_official_room(p_room_id) then
    raise exception 'Only Official room moderators can be listed here';
  end if;
  return query
  select p.id, coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    p.branch_code, p.department, p.academic_year,
    right(split_part(lower(u.email), '@', 1), 3)::text, m.ends_at
  from public.room_moderators m
  join public.profiles p on p.id = m.student_id
  join auth.users u on u.id = p.id
  left join public.identity_records i on i.user_id = p.id
  where m.room_id = p_room_id and m.active and m.starts_at <= now()
    and (m.ends_at is null or m.ends_at > now())
  order by i.real_name;
end;
$$;

-- Faculty may use the official live room, but cannot read or post to the
-- anonymous Unofficial feed or its rooms.
create policy "Faculty cannot use anonymous posts"
  on public.posts as restrictive for all to authenticated
  using (not public.is_faculty_account(auth.uid()))
  with check (not public.is_faculty_account(auth.uid()));
create policy "Faculty cannot use anonymous likes"
  on public.post_likes as restrictive for all to authenticated
  using (not public.is_faculty_account(auth.uid()))
  with check (not public.is_faculty_account(auth.uid()));
create policy "Faculty cannot use anonymous replies"
  on public.post_replies as restrictive for all to authenticated
  using (not public.is_faculty_account(auth.uid()))
  with check (not public.is_faculty_account(auth.uid()));

create policy "Faculty can use only Official live messages"
  on public.room_messages as restrictive for all to authenticated
  using (not public.is_faculty_account(auth.uid()) or room_id = 'official-live')
  with check (not public.is_faculty_account(auth.uid()) or room_id = 'official-live');
create policy "Faculty can receive only Official live broadcasts"
  on realtime.messages as restrictive for select to authenticated
  using (not public.is_faculty_account(auth.uid()) or realtime.topic() = 'room:official-live');

create policy "Faculty cannot access anonymous post images"
  on storage.objects as restrictive for select to authenticated
  using (bucket_id <> 'campus-post-images' or not public.is_faculty_account(auth.uid()));
create policy "Faculty cannot upload anonymous post images"
  on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'campus-post-images' or not public.is_faculty_account(auth.uid()));
create policy "Faculty cannot delete anonymous post images"
  on storage.objects as restrictive for delete to authenticated
  using (bucket_id <> 'campus-post-images' or not public.is_faculty_account(auth.uid()));

-- The anonymous feed and profile-history RPCs are SECURITY DEFINER, so guard
-- them explicitly as well as the underlying tables.
create or replace function public.get_anonymous_feed()
returns table(author_username text, content text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_faculty_account(auth.uid()) then
    raise exception 'Unofficial access is unavailable to faculty' using errcode = '42501';
  end if;
  return query
  select coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    post.content, post.created_at
  from public.posts post left join public.profiles profile on profile.id = post.author_id
  order by post.created_at desc;
end;
$$;

create or replace function public.get_anonymous_feed_with_likes()
returns table(post_id uuid, author_username text, content text, created_at timestamptz,
  like_count bigint, liked_by_me boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_faculty_account(auth.uid()) then
    raise exception 'Unofficial access is unavailable to faculty' using errcode = '42501';
  end if;
  return query
  select post.id,
    coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    post.content, post.created_at, count(liked.user_id)::bigint,
    coalesce(bool_or(liked.user_id = auth.uid()), false)
  from public.posts post
  left join public.profiles profile on profile.id = post.author_id
  left join public.post_likes liked on liked.post_id = post.id
  group by post.id, post.content, post.created_at, profile.anon_username
  order by post.created_at desc;
end;
$$;

do $guard_unofficial_profile$
declare fn record; definition text;
begin
  for fn in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'get_my_unofficial_profile_stats', 'get_my_unofficial_profile_activity',
        'get_room_feed_with_media', 'get_room_feed_with_media_v2',
        'get_room_feed_with_media_v3', 'get_post_replies',
        'get_post_replies_with_avatars', 'delete_my_post'
      )
  loop
    definition := pg_get_functiondef(fn.oid);
    definition := replace(definition,
      'if caller_id is null then',
      'if caller_id is null or public.is_faculty_account(caller_id) then');
    definition := replace(definition,
      'where auth.uid() is not null',
      'where auth.uid() is not null and not public.is_faculty_account(auth.uid())');
    definition := replace(definition,
      'if auth.uid() is null then',
      'if auth.uid() is null or public.is_faculty_account(auth.uid()) then');
    if definition like '%is_faculty_account(%' then execute definition; end if;
  end loop;
end;
$guard_unofficial_profile$;

-- Protect official profile views without exposing enrollment numbers during
-- this phase. The Flutter profile card uses role to label faculty accurately.
drop function if exists public.get_official_profile_card(uuid);
create function public.get_official_profile_card(p_user_id uuid)
returns table(real_name text, branch_code text, branch_name text, study_year int, role text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = auth.uid() and u.email_confirmed_at is not null
      and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
        or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email) = '25mc1pr108@mitsgwl.ac.in')
      and p.role in ('student', 'faculty', 'super_admin')
  ) then
    raise exception 'Official MITS profile access required' using errcode = '42501';
  end if;
  return query
  select i.real_name, p.branch_code, p.department, p.academic_year, p.role
  from public.profiles p join public.identity_records i on i.user_id = p.id
  where p.id = p_user_id;
end;
$$;

-- Let the signed-in user read their department code for their faculty profile.
grant select(branch_code) on public.profiles to authenticated;

-- Official post bylines show a faculty member's chosen department and omit
-- the student year label.
create or replace function public.get_official_posts_with_activity(
  p_department_code text, p_limit integer, p_room_id text
)
returns table(post_id uuid, department_code text, author_name text, author_branch text,
  author_year integer, content text, created_at timestamptz, image_path text,
  is_mine boolean, like_count bigint, liked_by_me boolean, comment_count bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = auth.uid() and u.email_confirmed_at is not null
      and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
        or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email) = '25mc1pr108@mitsgwl.ac.in')
      and p.role in ('student', 'faculty', 'super_admin')
  ) then
    raise exception 'Official MITS account required' using errcode = '42501';
  end if;
  if p_room_id = 'official-live'
      or not public.is_official_room(p_room_id) then
    raise exception 'Choose an Official posting room';
  end if;
  if p_room_id like 'dept-%'
      and lower(coalesce(p_department_code, '')) <> substring(p_room_id from 6) then
    raise exception 'Department and room do not match';
  end if;
  return query
  select post.id, post.department_code,
    coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    case when p.role = 'faculty'
      then 'Faculty' || case when p.branch_code is null then '' else ' · ' || p.branch_code end
      else coalesce(p.branch_code, '') end::text,
    case when p.role = 'faculty' then null else p.academic_year end,
    post.content, post.created_at, post.image_path, post.author_id = auth.uid(),
    (select count(*)::bigint from public.official_post_likes l where l.post_id = post.id),
    exists(select 1 from public.official_post_likes l where l.post_id = post.id and l.user_id = auth.uid()),
    (select count(*)::bigint from public.official_post_replies r where r.post_id = post.id)
  from public.official_posts post
  join public.identity_records i on i.user_id = post.author_id
  join public.profiles p on p.id = post.author_id
  where post.room_id = p_room_id
    and post.department_code is not distinct from p_department_code
  order by post.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

create or replace function public.get_official_post_replies(p_post_id uuid)
returns table(author_name text, content text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = auth.uid() and u.email_confirmed_at is not null
      and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
        or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email) = '25mc1pr108@mitsgwl.ac.in')
      and p.role in ('student', 'faculty', 'super_admin')
  ) then
    raise exception 'Official MITS account required' using errcode = '42501';
  end if;
  return query
  select (coalesce(nullif(btrim(i.real_name), ''), 'Student')
      || case when p.role = 'faculty' then ' · Faculty'
        || case when p.branch_code is null then '' else ' · ' || p.branch_code end
        else '' end)::text,
    r.content, r.created_at
  from public.official_post_replies r
  join public.profiles p on p.id = r.author_id
  join public.identity_records i on i.user_id = r.author_id
  where r.post_id = p_post_id
  order by r.created_at asc;
end;
$$;

create or replace function public.create_official_post(
  p_post_id uuid, p_content text, p_image_path text,
  p_department_code text, p_room_id text
)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); clean text := btrim(coalesce(p_content, ''));
begin
  if uid is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_room_id = 'official-live' or not public.is_official_room(p_room_id) then
    raise exception 'Choose an Official posting room';
  end if;
  if p_room_id like 'dept-%'
      and lower(coalesce(p_department_code, '')) <> substring(p_room_id from 6) then
    raise exception 'Department and room do not match';
  end if;
  if p_room_id = 'general' and p_department_code is not null then
    raise exception 'Campus-wide posts cannot select a department';
  end if;
  if not (public.is_faculty(uid) or public.is_active_room_moderator(p_room_id, uid)) then
    raise exception 'Only faculty or this room moderator can publish' using errcode = '42501';
  end if;
  if char_length(clean) > 2000 or (clean = '' and p_image_path is null) then
    raise exception 'Add a caption or image';
  end if;
  if p_image_path is not null and p_image_path !~
      ('^' || uid::text || '/' || p_room_id || '/posts/' || p_post_id::text
       || '/' || p_post_id::text || '[.](jpg|jpeg|png|webp)$') then
    raise exception 'Invalid official image path';
  end if;
  insert into public.official_posts(id, author_id, department_code, content, image_path, room_id)
  values(p_post_id, uid, p_department_code, clean, p_image_path, p_room_id);
end;
$$;

-- Keep history and realtime chat labels consistent with official profiles.
create or replace function public.get_room_messages(p_room_id text, p_limit integer default 50)
returns table(message_id uuid, room_id text, author_id uuid, author_username text,
  content text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare joined timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if public.is_faculty_account(auth.uid()) and p_room_id <> 'official-live' then
    raise exception 'Faculty can only access Official live chat' using errcode = '42501';
  end if;
  if p_room_id = 'official-live' then
    select s.joined_at into joined from public.room_sessions s
    where s.room_id = p_room_id and s.user_id = auth.uid() and s.left_at is null
    order by s.joined_at desc limit 1;
    if joined is null or exists(select 1 from public.room_blocks b
      where b.room_id = p_room_id and b.user_id = auth.uid() and b.ends_at > now()) then
      raise exception 'Join room to read messages' using errcode = '42501';
    end if;
  end if;
  return query
  select m.id, m.room_id, m.sender_id,
    case when m.room_id = 'official-live' then
      case when p.role = 'faculty' then
        coalesce(nullif(btrim(i.real_name), ''), 'Faculty') || ' · Faculty'
          || case when p.branch_code is null then '' else ' · ' || p.branch_code end
      else coalesce(nullif(btrim(i.real_name), ''), 'Student') || ' · '
        || coalesce(p.branch_code, '') || ' · ' || case
          when p.academic_year > 4 then 'Alumni'
          when p.academic_year = 1 then '1st'
          when p.academic_year = 2 then '2nd'
          when p.academic_year = 3 then '3rd'
          when p.academic_year = 4 then '4th'
          else 'Year unavailable' end
      end
    else coalesce(nullif(btrim(p.anon_username), ''), 'Anonymous') end::text,
    m.content, m.created_at
  from (
    select x.id, x.room_id, x.sender_id, x.content, x.created_at
    from public.room_messages x
    where x.room_id = p_room_id
      and (p_room_id <> 'official-live' or exists(
        select 1 from public.room_sessions s where s.room_id = p_room_id
          and s.user_id = auth.uid() and x.created_at >= s.joined_at
          and x.created_at <= coalesce(s.left_at, now())))
    order by x.created_at desc limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) m
  left join public.profiles p on p.id = m.sender_id
  left join public.identity_records i on i.user_id = m.sender_id
  order by m.created_at asc;
end;
$$;

create or replace function public.broadcast_room_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare display_name text; branch text; year_no int; member_role text;
begin
  if new.room_id = 'official-live' then
    select coalesce(nullif(btrim(i.real_name), ''), 'Student'), p.branch_code,
      p.academic_year, p.role
    into display_name, branch, year_no, member_role
    from public.profiles p left join public.identity_records i on i.user_id = p.id
    where p.id = new.sender_id;
    if member_role = 'faculty' then
      display_name := display_name || ' · Faculty'
        || case when branch is null then '' else ' · ' || branch end;
    else
      display_name := display_name || ' · ' || coalesce(branch, '') || ' · ' || case
        when year_no > 4 then 'Alumni' when year_no = 1 then '1st'
        when year_no = 2 then '2nd' when year_no = 3 then '3rd'
        when year_no = 4 then '4th' else 'Year unavailable' end;
    end if;
  else
    select coalesce(nullif(btrim(p.anon_username), ''), 'Anonymous')
    into display_name from public.profiles p where p.id = new.sender_id;
  end if;
  perform realtime.send(
    jsonb_build_object('message_id', new.id, 'room_id', new.room_id,
      'author_id', new.sender_id, 'author_username', coalesce(display_name, 'Anonymous'),
      'content', new.content, 'created_at', new.created_at),
    'new_message', 'room:' || new.room_id, true);
  return new;
end;
$$;

create or replace function public.join_room(p_room_id text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); joined timestamptz;
begin
  if uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if public.is_faculty_account(uid) and p_room_id <> 'official-live' then
    raise exception 'Faculty can only join Official live chat' using errcode = '42501';
  end if;
  if p_room_id = 'official-live' and not exists(
    select 1 from public.profiles where id = uid and role in ('student','faculty','super_admin')) then
    raise exception 'Official MITS account required' using errcode = '42501';
  end if;
  if exists(select 1 from public.room_blocks b where b.room_id = p_room_id
      and b.user_id = uid and b.ends_at > now()) then
    raise exception 'Blocked from room' using errcode = '42501';
  end if;
  update public.room_sessions set left_at = now()
    where room_id = p_room_id and user_id = uid and left_at is null;
  insert into public.room_sessions(room_id, user_id) values(p_room_id, uid)
    returning room_sessions.joined_at into joined;
  return joined;
end;
$$;

revoke all on function public.is_faculty_account(uuid),
  public.is_official_room(text),
  public.save_my_faculty_profile(text,text,text),
  public.list_faculty_rooms(),
  public.search_students(text,text), public.list_room_moderators(text),
  public.assign_room_moderator(text,uuid,timestamptz),
  public.remove_room_moderator(text,uuid), public.block_room_user(text,uuid,text),
  public.create_official_post(uuid,text,text,text,text),
  public.get_official_profile_card(uuid), public.get_official_posts_with_activity(text,integer,text),
  public.get_room_messages(text,integer), public.join_room(text)
  from public, anon;
grant execute on function public.is_faculty_account(uuid),
  public.is_official_room(text),
  public.save_my_faculty_profile(text,text,text),
  public.list_faculty_rooms(),
  public.search_students(text,text), public.list_room_moderators(text),
  public.assign_room_moderator(text,uuid,timestamptz),
  public.remove_room_moderator(text,uuid), public.block_room_user(text,uuid,text),
  public.create_official_post(uuid,text,text,text,text),
  public.get_official_profile_card(uuid), public.get_official_posts_with_activity(text,integer,text),
  public.get_room_messages(text,integer), public.join_room(text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
