begin;

-- Official interactions stay separate from the anonymous posts and replies.
create table public.official_post_likes (
  post_id uuid not null references public.official_posts(id) on delete cascade,
  user_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index official_post_likes_user_idx
  on public.official_post_likes (user_id, post_id);

alter table public.official_post_likes enable row level security;
revoke all on table public.official_post_likes from public, anon, authenticated;
grant insert (post_id) on table public.official_post_likes to authenticated;
grant select (post_id) on table public.official_post_likes to authenticated;
grant delete on table public.official_post_likes to authenticated;

create policy "MITS students can like Official posts as themselves"
  on public.official_post_likes
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and lower(coalesce(auth.jwt() ->> 'email', ''))
      ~ '^[^@]+@mitsgwl[.]ac[.]in$'
  );

create policy "MITS students can remove their Official likes"
  on public.official_post_likes
  for delete to authenticated
  using (
    user_id = (select auth.uid())
    and lower(coalesce(auth.jwt() ->> 'email', ''))
      ~ '^[^@]+@mitsgwl[.]ac[.]in$'
  );

create table public.official_post_replies (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.official_posts(id) on delete cascade,
  author_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  content text not null
    check (char_length(btrim(content)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index official_post_replies_post_created_at_idx
  on public.official_post_replies (post_id, created_at);
create index official_post_replies_author_created_at_idx
  on public.official_post_replies (author_id, created_at desc);

alter table public.official_post_replies enable row level security;
revoke all on table public.official_post_replies from public, anon, authenticated;
grant insert (post_id, content) on table public.official_post_replies
  to authenticated;

create policy "MITS students can reply to Official posts as themselves"
  on public.official_post_replies
  for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and lower(coalesce(auth.jwt() ->> 'email', ''))
      ~ '^[^@]+@mitsgwl[.]ac[.]in$'
  );

create function public.get_my_unofficial_profile_stats()
returns table(post_count bigint, like_count bigint, comment_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  return query
  select
    (select count(*)::bigint
       from public.posts as post
      where post.author_id = caller_id),
    (select count(*)::bigint
       from public.post_likes as liked
       join public.posts as post on post.id = liked.post_id
      where post.author_id = caller_id),
    (select count(*)::bigint
       from public.post_replies as reply
      where reply.author_id = caller_id);
end;
$$;

create function public.get_my_unofficial_profile_activity(
  p_section text,
  p_limit integer default 100
)
returns table(
  activity_type text,
  activity_id uuid,
  post_id uuid,
  room_id text,
  scope_name text,
  activity_content text,
  post_content text,
  post_author_name text,
  created_at timestamptz,
  like_count bigint,
  liked_by_me boolean,
  comment_count bigint,
  image_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  row_limit integer := greatest(1, least(coalesce(p_limit, 100), 100));
begin
  if caller_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_section is null or p_section not in ('posts', 'comments') then
    raise exception 'Unknown profile section';
  end if;

  if p_section = 'posts' then
    return query
    select
      'post'::text,
      post.id,
      post.id,
      post.room_id,
      coalesce(nullif(btrim(room.name), ''), post.room_id),
      post.content,
      post.content,
      coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
      post.created_at,
      (select count(*)::bigint from public.post_likes as liked
        where liked.post_id = post.id),
      exists (select 1 from public.post_likes as liked
        where liked.post_id = post.id and liked.user_id = caller_id),
      (select count(*)::bigint from public.post_replies as reply
        where reply.post_id = post.id),
      post.image_path
    from public.posts as post
    left join public.profiles as profile on profile.id = post.author_id
    left join public.rooms as room on room.id = post.room_id
    where post.author_id = caller_id
    order by post.created_at desc
    limit row_limit;
  else
    return query
    select
      'comment'::text,
      reply.id,
      post.id,
      post.room_id,
      coalesce(nullif(btrim(room.name), ''), post.room_id),
      reply.content,
      post.content,
      coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
      reply.created_at,
      (select count(*)::bigint from public.post_likes as liked
        where liked.post_id = post.id),
      exists (select 1 from public.post_likes as liked
        where liked.post_id = post.id and liked.user_id = caller_id),
      (select count(*)::bigint from public.post_replies as post_reply
        where post_reply.post_id = post.id),
      post.image_path
    from public.post_replies as reply
    join public.posts as post on post.id = reply.post_id
    left join public.profiles as profile on profile.id = post.author_id
    left join public.rooms as room on room.id = post.room_id
    where reply.author_id = caller_id
    order by reply.created_at desc
    limit row_limit;
  end if;
end;
$$;

create function public.get_my_official_profile_stats()
returns table(post_count bigint, like_count bigint, comment_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required'
      using errcode = '42501';
  end if;

  return query
  select
    (select count(*)::bigint
       from public.official_posts as post
      where post.author_id = caller_id),
    (select count(*)::bigint
       from public.official_post_likes as liked
       join public.official_posts as post on post.id = liked.post_id
      where post.author_id = caller_id),
    (select count(*)::bigint
       from public.official_post_replies as reply
      where reply.author_id = caller_id);
end;
$$;

create function public.get_my_official_profile_activity(
  p_section text,
  p_limit integer default 100
)
returns table(
  activity_type text,
  activity_id uuid,
  post_id uuid,
  department_code text,
  scope_name text,
  activity_content text,
  post_content text,
  post_author_name text,
  created_at timestamptz,
  like_count bigint,
  liked_by_me boolean,
  comment_count bigint,
  image_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  row_limit integer := greatest(1, least(coalesce(p_limit, 100), 100));
begin
  if caller_id is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required'
      using errcode = '42501';
  end if;
  if p_section is null or p_section not in ('posts', 'comments') then
    raise exception 'Unknown profile section';
  end if;

  if p_section = 'posts' then
    return query
    select
      'post'::text,
      post.id,
      post.id,
      post.department_code,
      case post.department_code
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
        else 'Campus-wide'
      end::text,
      post.content,
      post.content,
      coalesce(nullif(btrim(identity.real_name), ''), 'Student')::text,
      post.created_at,
      (select count(*)::bigint from public.official_post_likes as liked
        where liked.post_id = post.id),
      exists (select 1 from public.official_post_likes as liked
        where liked.post_id = post.id and liked.user_id = caller_id),
      (select count(*)::bigint from public.official_post_replies as reply
        where reply.post_id = post.id),
      post.image_path
    from public.official_posts as post
    left join public.identity_records as identity
      on identity.user_id = post.author_id
    where post.author_id = caller_id
    order by post.created_at desc
    limit row_limit;
  else
    return query
    select
      'comment'::text,
      reply.id,
      post.id,
      post.department_code,
      case post.department_code
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
        else 'Campus-wide'
      end::text,
      reply.content,
      post.content,
      coalesce(nullif(btrim(identity.real_name), ''), 'Student')::text,
      reply.created_at,
      (select count(*)::bigint from public.official_post_likes as liked
        where liked.post_id = post.id),
      exists (select 1 from public.official_post_likes as liked
        where liked.post_id = post.id and liked.user_id = caller_id),
      (select count(*)::bigint from public.official_post_replies as post_reply
        where post_reply.post_id = post.id),
      post.image_path
    from public.official_post_replies as reply
    join public.official_posts as post on post.id = reply.post_id
    left join public.identity_records as identity
      on identity.user_id = post.author_id
    where reply.author_id = caller_id
    order by reply.created_at desc
    limit row_limit;
  end if;
end;
$$;

create function public.get_official_post_replies(p_post_id uuid)
returns table(author_name text, content text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required'
      using errcode = '42501';
  end if;

  return query
  select
    coalesce(nullif(btrim(identity.real_name), ''), 'Student')::text,
    reply.content,
    reply.created_at
  from public.official_post_replies as reply
  join public.identity_records as identity
    on identity.user_id = reply.author_id
  where reply.post_id = p_post_id
  order by reply.created_at asc;
end;
$$;

create function public.toggle_official_post_like(p_post_id uuid)
returns table(like_count bigint, liked_by_me boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.official_posts as post where post.id = p_post_id
  ) then
    raise exception 'Official post not found' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.official_post_likes as liked
    where liked.post_id = p_post_id and liked.user_id = caller_id
  ) then
    delete from public.official_post_likes as liked
    where liked.post_id = p_post_id and liked.user_id = caller_id;
  else
    insert into public.official_post_likes (post_id, user_id)
    values (p_post_id, caller_id)
    on conflict (post_id, user_id) do nothing;
  end if;

  return query
  select count(*)::bigint,
         exists (
           select 1 from public.official_post_likes as liked
           where liked.post_id = p_post_id and liked.user_id = caller_id
         )
  from public.official_post_likes as liked
  where liked.post_id = p_post_id;
end;
$$;

create function public.get_official_posts_with_activity(
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
  is_mine boolean,
  like_count bigint,
  liked_by_me boolean,
  comment_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or lower(coalesce(auth.jwt() ->> 'email', ''))
      !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'An authenticated MITS college account is required'
      using errcode = '42501';
  end if;

  return query
  select
    post.id,
    post.department_code,
    coalesce(nullif(btrim(identity.real_name), ''), 'Student')::text,
    details.branch,
    details.academic_year,
    post.content,
    post.created_at,
    post.image_path,
    post.author_id = auth.uid(),
    (select count(*)::bigint from public.official_post_likes as liked
      where liked.post_id = post.id),
    exists (select 1 from public.official_post_likes as liked
      where liked.post_id = post.id and liked.user_id = auth.uid()),
    (select count(*)::bigint from public.official_post_replies as reply
      where reply.post_id = post.id)
  from public.official_posts as post
  join public.identity_records as identity on identity.user_id = post.author_id
  cross join lateral public.college_details_for_user(post.author_id) as details
  where post.department_code is not distinct from p_department_code
  order by post.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

revoke all on function public.get_my_unofficial_profile_stats()
  from public, anon, authenticated;
revoke all on function public.get_my_unofficial_profile_activity(text, integer)
  from public, anon, authenticated;
revoke all on function public.get_my_official_profile_stats()
  from public, anon, authenticated;
revoke all on function public.get_my_official_profile_activity(text, integer)
  from public, anon, authenticated;
revoke all on function public.get_official_post_replies(uuid)
  from public, anon, authenticated;
revoke all on function public.toggle_official_post_like(uuid)
  from public, anon, authenticated;
revoke all on function public.get_official_posts_with_activity(text, integer)
  from public, anon, authenticated;

grant execute on function public.get_my_unofficial_profile_stats()
  to authenticated;
grant execute on function public.get_my_unofficial_profile_activity(text, integer)
  to authenticated;
grant execute on function public.get_my_official_profile_stats()
  to authenticated;
grant execute on function public.get_my_official_profile_activity(text, integer)
  to authenticated;
grant execute on function public.get_official_post_replies(uuid)
  to authenticated;
grant execute on function public.toggle_official_post_like(uuid)
  to authenticated;
grant execute on function public.get_official_posts_with_activity(text, integer)
  to authenticated;

notify pgrst, 'reload schema';
commit;
