-- Official Campus uses a separate private post stream and storage bucket.
-- Existing anonymous posts and their policies remain unchanged.

create table public.official_posts (
  id uuid primary key,
  author_id uuid not null references auth.users(id) on delete cascade,
  department_code text,
  content text not null default '',
  image_path text,
  created_at timestamptz not null default now(),
  constraint official_posts_department_code_check check (
    department_code is null or department_code in (
      'ad', 'ai', 'am', 'cb', 'cd', 'ce', 'cm', 'cs', 'ec', 'ee',
      'el', 'et', 'io', 'ir', 'it', 'mc', 'me', 'tc', 'ar'
    )
  ),
  constraint official_posts_content_check check (
    (char_length(btrim(content)) between 1 and 2000) or image_path is not null
  )
);

create index official_posts_home_created_at_idx
  on public.official_posts (created_at desc)
  where department_code is null;
create index official_posts_department_created_at_idx
  on public.official_posts (department_code, created_at desc)
  where department_code is not null;

alter table public.official_posts enable row level security;
revoke all on table public.official_posts from public, anon, authenticated;

alter table public.identity_records enable row level security;
revoke all on table public.identity_records from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'official-post-images',
  'official-post-images',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "MITS users can upload their official post images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'official-post-images'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and lower(coalesce(auth.jwt() ->> 'email', '')) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
);

create policy "MITS users can read official post images"
on storage.objects for select to authenticated
using (
  bucket_id = 'official-post-images'
  and lower(coalesce(auth.jwt() ->> 'email', '')) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
);

create policy "Users can remove their official post images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'official-post-images'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and lower(coalesce(auth.jwt() ->> 'email', '')) ~ '^[^@]+@mitsgwl[.]ac[.]in$'
);

-- Resolve branch/year from the authenticated college email, not user-editable
-- profile values. The helper is callable only by the migration owner/functions.
create or replace function public.college_details_for_user(p_user_id uuid)
returns table(branch text, academic_year integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  user_email text;
  local_part text;
  branch_code text;
  enrollment_year integer;
  branch_name text;
begin
  select lower(account.email)
    into user_email
  from auth.users as account
  where account.id = p_user_id;

  if user_email !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    return;
  end if;

  local_part := split_part(user_email, '@', 1);
  if local_part !~ '^[0-9]{2}[a-z]{2}' then
    return;
  end if;

  enrollment_year := 2000 + substring(local_part from 1 for 2)::integer;
  branch_code := substring(local_part from 3 for 2);
  branch_name := case branch_code
    when 'ad' then 'AI & Data Science'
    when 'ai' then 'Artificial Intelligence'
    when 'am' then 'AI & Machine Learning'
    when 'cb' then 'CS & Business Systems'
    when 'cd' then 'CS & Design'
    when 'ce' then 'Civil Engineering'
    when 'cm' then 'Chemical Engineering'
    when 'cs' then 'Computer Science & Engg'
    when 'ec' then 'Electronics & Communication'
    when 'ee' then 'Electrical Engineering'
    when 'el' then 'Electronics Engineering'
    when 'et' then 'Electronics & Telecommunication'
    when 'io' then 'Internet of Things (IoT)'
    when 'ir' then 'IT (AI & Robotics)'
    when 'it' then 'Information Technology'
    when 'mc' then 'Mathematics & Computing'
    when 'me' then 'Mechanical Engineering'
    when 'tc' then 'CS & Technology'
    when 'ar' then 'Architecture (B.Arch)'
    else null
  end;

  if branch_name is null then
    return;
  end if;

  academic_year := extract(year from current_date)::integer - enrollment_year + 1;
  if academic_year < 1 then
    return;
  end if;

  branch := branch_name;
  return next;
end;
$$;
revoke all on function public.college_details_for_user(uuid)
  from public, anon, authenticated;

-- Keep ordinary profile edits available while preventing clients from
-- overwriting the email-derived branch/year columns.
revoke update on table public.profiles from authenticated;
revoke update (department, academic_year)
  on table public.profiles from authenticated;
grant update (bio, avatar_seed, profile_completed)
  on table public.profiles to authenticated;

create or replace function public.sync_my_college_profile()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  details record;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;

  select * into details
  from public.college_details_for_user(caller_id);

  if details.branch is null then
    return;
  end if;

  update public.profiles
  set department = details.branch,
      academic_year = details.academic_year
  where id = caller_id;
end;
$$;

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
  caller_id uuid := auth.uid();
  first_name text := btrim(coalesce(p_first_name, ''));
  last_name text := btrim(coalesce(p_last_name, ''));
  full_name text;
  details record;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An MITS college email is required';
  end if;
  if char_length(first_name) not between 1 and 60
      or char_length(last_name) not between 1 and 60 then
    raise exception 'Enter a first name and last name';
  end if;

  full_name := first_name || ' ' || last_name;
  insert into public.identity_records (user_id, real_name)
  values (caller_id, full_name)
  on conflict (user_id) do update
    set real_name = excluded.real_name;

  select * into details
  from public.college_details_for_user(caller_id);

  if details.branch is null then
    raise exception 'Could not detect your branch from the MITS email';
  end if;

  update public.profiles
  set profile_completed = true,
      bio = nullif(btrim(coalesce(p_bio, '')), ''),
      department = details.branch,
      academic_year = details.academic_year
  where id = caller_id;
end;
$$;

create or replace function public.get_my_identity()
returns table(real_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select identity.real_name
  from public.identity_records as identity
  where identity.user_id = auth.uid()
    and lower(coalesce(auth.jwt() ->> 'email', ''))
      ~ '^[^@]+@mitsgwl[.]ac[.]in$';
$$;

create or replace function public.create_official_post(
  p_post_id uuid,
  p_content text,
  p_image_path text,
  p_department_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  clean_content text := btrim(coalesce(p_content, ''));
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An MITS college email is required';
  end if;
  if char_length(clean_content) > 2000
      or (char_length(clean_content) = 0 and p_image_path is null) then
    raise exception 'Add a caption or image';
  end if;
  if p_department_code is not null and p_department_code not in (
    'ad', 'ai', 'am', 'cb', 'cd', 'ce', 'cm', 'cs', 'ec', 'ee',
    'el', 'et', 'io', 'ir', 'it', 'mc', 'me', 'tc', 'ar'
  ) then
    raise exception 'Unknown department';
  end if;
  if p_image_path is not null and
      p_image_path !~ ('^' || caller_id::text || '/posts/' || p_post_id::text ||
        '/' || p_post_id::text || '[.](jpg|jpeg|png|webp)$') then
    raise exception 'Invalid official image path';
  end if;

  insert into public.official_posts (
    id, author_id, department_code, content, image_path
  ) values (
    p_post_id, caller_id, p_department_code, clean_content, p_image_path
  );
end;
$$;

create or replace function public.get_official_posts(
  p_department_code text default null,
  p_limit integer default 50
)
returns table(
  post_id uuid,
  department_code text,
  author_name text,
  author_branch text,
  author_year integer,
  content text,
  created_at timestamptz,
  image_path text,
  is_mine boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required';
  end if;
  if p_department_code is not null and p_department_code not in (
    'ad', 'ai', 'am', 'cb', 'cd', 'ce', 'cm', 'cs', 'ec', 'ee',
    'el', 'et', 'io', 'ir', 'it', 'mc', 'me', 'tc', 'ar'
  ) then
    raise exception 'Unknown department';
  end if;

  return query
  select
    post.id,
    post.department_code,
    coalesce(nullif(btrim(identity.real_name), ''), 'Student'),
    details.branch,
    details.academic_year,
    post.content,
    post.created_at,
    post.image_path,
    post.author_id = auth.uid()
  from public.official_posts as post
  join public.identity_records as identity on identity.user_id = post.author_id
  cross join lateral public.college_details_for_user(post.author_id) as details
  where post.department_code is not distinct from p_department_code
  order by post.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

revoke all on function public.sync_my_college_profile() from public, anon, authenticated;
revoke all on function public.save_my_identity(text, text, text) from public, anon, authenticated;
revoke all on function public.get_my_identity() from public, anon, authenticated;
revoke all on function public.create_official_post(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.get_official_posts(text, integer)
  from public, anon, authenticated;

grant execute on function public.sync_my_college_profile() to authenticated;
grant execute on function public.save_my_identity(text, text, text) to authenticated;
grant execute on function public.get_my_identity() to authenticated;
grant execute on function public.create_official_post(uuid, text, text, text)
  to authenticated;
grant execute on function public.get_official_posts(text, integer)
  to authenticated;
