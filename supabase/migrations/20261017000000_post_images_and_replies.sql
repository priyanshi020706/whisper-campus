begin;

-- Post image objects stay private and are served with short-lived signed URLs.
do $$
begin
  if exists (
    select 1
    from storage.buckets
    where id = 'campus-post-images'
      and (
        name <> 'campus-post-images'
        or public is distinct from false
        or file_size_limit is distinct from 5242880
        or allowed_mime_types is distinct from
          array['image/jpeg', 'image/png', 'image/webp']::text[]
      )
  ) then
    raise exception
      'The campus-post-images bucket already exists with different settings.';
  end if;

  insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
  )
  values (
    'campus-post-images',
    'campus-post-images',
    false,
    5242880,
    array['image/jpeg', 'image/png', 'image/webp']::text[]
  )
  on conflict (id) do nothing;
end;
$$;

alter table public.posts
  add column image_path text;

-- Grant only these insert columns; author_id continues to come from auth.uid()
-- and the existing posts INSERT RLS policy remains in force.
revoke insert on table public.posts from public, anon, authenticated;
revoke insert (id, author_id, content, created_at, room_id, image_path)
  on table public.posts from public, anon, authenticated;
grant insert (id, content, room_id, image_path)
  on table public.posts to authenticated;

create policy "Authenticated users can upload campus post images"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'campus-post-images'
    and owner_id = (select auth.uid()::text)
    and name ~ '^posts/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
  );

-- Restrictive guards prevent any older broad Storage policies from making
-- this bucket anonymously readable or writable.
create policy "Campus post images require an authenticated owner to upload"
  on storage.objects
  as restrictive
  for insert
  to public
  with check (
    bucket_id <> 'campus-post-images'
    or (
      auth.uid() is not null
      and owner_id = (select auth.uid()::text)
      and name ~ '^posts/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
    )
  );

create policy "Authenticated users can read campus post images"
  on storage.objects
  for select
  to authenticated
  using (bucket_id = 'campus-post-images');

create policy "Campus post images are never anonymously readable"
  on storage.objects
  as restrictive
  for select
  to public
  using (
    bucket_id <> 'campus-post-images'
    or auth.uid() is not null
  );

create policy "Users can remove their own campus post image uploads"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'campus-post-images'
    and owner_id = (select auth.uid()::text)
  );

create policy "Campus post image deletes require the owner"
  on storage.objects
  as restrictive
  for delete
  to public
  using (
    bucket_id <> 'campus-post-images'
    or (
      auth.uid() is not null
      and owner_id = (select auth.uid()::text)
    )
  );

-- Bind each post's image path to an object uploaded by its author.
create function public.validate_post_image_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.image_path is not null and not exists (
    select 1
    from storage.objects as object_row
    where object_row.bucket_id = 'campus-post-images'
      and object_row.name = new.image_path
      and object_row.owner_id = auth.uid()::text
  ) then
    raise exception 'The selected image is not owned by this account.';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_post_image_owner() from public, anon, authenticated;

create trigger validate_post_image_owner_before_write
before insert or update of image_path on public.posts
for each row
execute function public.validate_post_image_owner();

create table public.post_replies (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  content text not null
    check (char_length(btrim(content)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index post_replies_post_created_at_idx
  on public.post_replies (post_id, created_at);

alter table public.post_replies enable row level security;

revoke all on table public.post_replies from public, anon, authenticated;
grant insert (post_id, content) on table public.post_replies to authenticated;

create policy "Authenticated users can reply as themselves"
  on public.post_replies
  for insert
  to authenticated
  with check (author_id = (select auth.uid()));

-- Keep the current get_room_feed(text) RPC untouched. This projection adds
-- only image_path and reply_count while retaining anonymous author display.
create function public.get_room_feed_with_media(p_room_id text)
returns table (
  post_id uuid,
  room_id text,
  author_username text,
  content text,
  created_at timestamptz,
  like_count bigint,
  liked_by_me boolean,
  image_path text,
  reply_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    post.id,
    post.room_id,
    coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    post.content,
    post.created_at,
    coalesce(like_stats.like_count, 0)::bigint,
    coalesce(like_stats.liked_by_me, false),
    post.image_path,
    coalesce(reply_stats.reply_count, 0)::bigint
  from public.posts as post
  left join public.profiles as profile
    on profile.id = post.author_id
  left join lateral (
    select
      count(like_row.user_id)::bigint as like_count,
      coalesce(bool_or(like_row.user_id = auth.uid()), false) as liked_by_me
    from public.post_likes as like_row
    where like_row.post_id = post.id
  ) as like_stats on true
  left join lateral (
    select count(*)::bigint as reply_count
    from public.post_replies as reply
    where reply.post_id = post.id
  ) as reply_stats on true
  where auth.uid() is not null
    and post.room_id = p_room_id
  order by post.created_at desc;
$$;

revoke all on function public.get_room_feed_with_media(text)
  from public, anon, authenticated;
grant execute on function public.get_room_feed_with_media(text)
  to authenticated;

create function public.get_post_replies(p_post_id uuid)
returns table (
  author_username text,
  content text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    reply.content,
    reply.created_at
  from public.post_replies as reply
  left join public.profiles as profile
    on profile.id = reply.author_id
  where auth.uid() is not null
    and reply.post_id = p_post_id
  order by reply.created_at asc;
$$;

revoke all on function public.get_post_replies(uuid)
  from public, anon, authenticated;
grant execute on function public.get_post_replies(uuid)
  to authenticated;

commit;
