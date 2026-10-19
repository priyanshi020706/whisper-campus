-- Clients read only the anonymous projection through get_anonymous_feed().
-- The function returns no post or user identifiers.
revoke select on table public.posts from public, anon, authenticated;

-- Let authenticated clients create posts without supplying an author ID.
alter table public.posts
  alter column author_id set default auth.uid();

revoke insert on table public.posts from public, anon, authenticated;
grant insert (content) on table public.posts to authenticated;

create or replace function public.get_anonymous_feed()
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
    post.content,
    post.created_at
  from public.posts as post
  left join public.profiles as profile
    on profile.id = post.author_id
  where auth.uid() is not null
  order by post.created_at desc;
$$;

-- Functions are executable by PUBLIC by default; restrict the feed RPC.
revoke all on function public.get_anonymous_feed() from public;
revoke all on function public.get_anonymous_feed() from anon;
grant execute on function public.get_anonymous_feed() to authenticated;
