begin;

-- Keep the existing media feed RPC intact for any older app build. This
-- version adds only an ownership boolean; it never returns author_id.
create or replace function public.get_room_feed_with_media_v2(p_room_id text)
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
  is_mine boolean
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
    post.author_id = auth.uid()
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

revoke all on function public.get_room_feed_with_media_v2(text)
  from public, anon, authenticated;
grant execute on function public.get_room_feed_with_media_v2(text)
  to authenticated;

-- Delete through a narrowly scoped RPC because clients intentionally have no
-- direct SELECT access to posts. The predicate enforces ownership server-side.
create or replace function public.delete_my_post(p_post_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_image_path text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  delete from public.posts as post
  where post.id = p_post_id
    and post.author_id = auth.uid()
  returning post.image_path into deleted_image_path;

  if not found then
    raise exception 'Post not found or not owned by this user'
      using errcode = 'P0002';
  end if;

  return deleted_image_path;
end;
$$;

revoke all on function public.delete_my_post(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_my_post(uuid)
  to authenticated;

notify pgrst, 'reload schema';
commit;
