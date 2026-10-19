begin;

-- Unofficial-only projections include the user's selected avatar seed while
-- keeping auth user IDs private. Official feed RPCs continue to use school icons.
create or replace function public.get_room_feed_with_media_v3(p_room_id text)
returns table (
  post_id uuid,
  room_id text,
  author_username text,
  content text,
  created_at timestamptz,
  like_count bigint,
  liked_by_me boolean,
  image_path text,
  reply_count bigint,
  is_mine boolean,
  avatar_seed text
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
    coalesce(reply_stats.reply_count, 0)::bigint,
    post.author_id = auth.uid(),
    profile.avatar_seed::text
  from public.posts as post
  left join public.profiles as profile on profile.id = post.author_id
  left join lateral (
    select count(like_row.user_id)::bigint as like_count,
      coalesce(bool_or(like_row.user_id = auth.uid()), false) as liked_by_me
    from public.post_likes as like_row where like_row.post_id = post.id
  ) as like_stats on true
  left join lateral (
    select count(*)::bigint as reply_count
    from public.post_replies as reply where reply.post_id = post.id
  ) as reply_stats on true
  where auth.uid() is not null and post.room_id = p_room_id
  order by post.created_at desc;
$$;

revoke all on function public.get_room_feed_with_media_v3(text)
  from public, anon, authenticated;
grant execute on function public.get_room_feed_with_media_v3(text)
  to authenticated;

create or replace function public.get_post_replies_with_avatars(p_post_id uuid)
returns table (
  author_username text,
  content text,
  created_at timestamptz,
  avatar_seed text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    reply.content,
    reply.created_at,
    profile.avatar_seed::text
  from public.post_replies as reply
  left join public.profiles as profile on profile.id = reply.author_id
  where auth.uid() is not null and reply.post_id = p_post_id
  order by reply.created_at asc;
$$;

revoke all on function public.get_post_replies_with_avatars(uuid)
  from public, anon, authenticated;
grant execute on function public.get_post_replies_with_avatars(uuid)
  to authenticated;

commit;
