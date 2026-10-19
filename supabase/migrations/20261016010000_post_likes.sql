begin;

-- One row per user/post pair prevents duplicate likes.
create table public.post_likes (
  post_id uuid not null
    references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.post_likes enable row level security;

-- Clients may only supply the post ID. The user ID comes from the JWT.
revoke all on table public.post_likes from public, anon, authenticated;
grant usage on schema public to authenticated;
grant insert (post_id) on table public.post_likes to authenticated;
grant select (post_id) on table public.post_likes to authenticated;
grant delete on table public.post_likes to authenticated;

create policy "Authenticated users can like posts as themselves"
  on public.post_likes
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "Authenticated users can unlike their own likes"
  on public.post_likes
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- Keep get_anonymous_feed() unchanged. This interaction-aware projection adds
-- only the post ID needed for toggling, aggregate count, and the caller's state.
create function public.get_anonymous_feed_with_likes()
returns table (
  post_id uuid,
  author_username text,
  content text,
  created_at timestamptz,
  like_count bigint,
  liked_by_me boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    post.id,
    coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
    post.content,
    post.created_at,
    count(liked.user_id)::bigint,
    coalesce(bool_or(liked.user_id = auth.uid()), false)
  from public.posts as post
  left join public.profiles as profile
    on profile.id = post.author_id
  left join public.post_likes as liked
    on liked.post_id = post.id
  where auth.uid() is not null
  group by post.id, post.content, post.created_at, profile.anon_username
  order by post.created_at desc;
$$;

revoke all on function public.get_anonymous_feed_with_likes()
  from public, anon, authenticated;
grant execute on function public.get_anonymous_feed_with_likes()
  to authenticated;

commit;
