begin;

-- Room IDs belong to posts, not post_replies. Resolve moderator labels through
-- the parent post so loading replies works with the current schema.
create or replace function public.get_post_replies_with_avatars(p_post_id uuid)
returns table(
  author_username text,
  content text,
  created_at timestamptz,
  avatar_seed text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1
    from public.posts as post
    where post.id = p_post_id
      and post.approval_status = 'approved'
  ) then
    raise exception 'Post is not available' using errcode = '42501';
  end if;

  return query
  select
    (
      coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')
      || case
        when public.is_active_room_moderator(post.room_id, 'unofficial', reply.author_id)
          then ' (Moderator)'
        else ''
      end
    )::text,
    reply.content,
    reply.created_at,
    profile.avatar_seed::text
  from public.post_replies as reply
  join public.posts as post on post.id = reply.post_id
  left join public.profiles as profile on profile.id = reply.author_id
  where reply.post_id = p_post_id
  order by reply.created_at asc;
end;
$$;

revoke all on function public.get_post_replies_with_avatars(uuid)
  from public, anon, authenticated;
grant execute on function public.get_post_replies_with_avatars(uuid)
  to authenticated;

notify pgrst, 'reload schema';
commit;
