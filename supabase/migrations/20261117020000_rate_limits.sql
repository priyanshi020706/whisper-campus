-- Server-side rate limits for everything students can write. Client checks are
-- not enough because the API can be called directly. Limits are per user and
-- apply to normal accounts; Super Admins are exempt.
--
-- The raised message uses the default error code (P0001), which the app shows
-- to the user as written.
begin;

create or replace function public.enforce_insert_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_column text := tg_argv[0];
  max_rows integer := tg_argv[1]::integer;
  window_seconds integer := tg_argv[2]::integer;
  actor uuid;
  recent_rows integer;
begin
  actor := nullif(to_jsonb(new) ->> actor_column, '')::uuid;
  if actor is null or public.is_super_admin(actor) then
    return new;
  end if;

  execute format(
    'select count(*) from %I.%I where %I = $1 and created_at > now() - make_interval(secs => $2)',
    tg_table_schema, tg_table_name, actor_column
  ) into recent_rows using actor, window_seconds;

  if recent_rows >= max_rows then
    raise exception 'You are doing that too quickly. Please wait a moment and try again.';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_insert_rate_limit() from public, anon, authenticated;

create index if not exists posts_author_created_at_idx
  on public.posts (author_id, created_at desc);
create index if not exists post_replies_author_created_at_idx
  on public.post_replies (author_id, created_at desc);
create index if not exists official_posts_author_created_at_idx
  on public.official_posts (author_id, created_at desc);
create index if not exists official_post_replies_author_created_at_idx
  on public.official_post_replies (author_id, created_at desc);
create index if not exists room_messages_sender_created_at_idx
  on public.room_messages (sender_id, created_at desc);

drop trigger if exists rate_limit_posts on public.posts;
create trigger rate_limit_posts before insert on public.posts
  for each row execute function public.enforce_insert_rate_limit('author_id', '5', '600');

drop trigger if exists rate_limit_post_replies on public.post_replies;
create trigger rate_limit_post_replies before insert on public.post_replies
  for each row execute function public.enforce_insert_rate_limit('author_id', '20', '600');

drop trigger if exists rate_limit_official_posts on public.official_posts;
create trigger rate_limit_official_posts before insert on public.official_posts
  for each row execute function public.enforce_insert_rate_limit('author_id', '5', '600');

drop trigger if exists rate_limit_official_post_replies on public.official_post_replies;
create trigger rate_limit_official_post_replies before insert on public.official_post_replies
  for each row execute function public.enforce_insert_rate_limit('author_id', '20', '600');

drop trigger if exists rate_limit_room_messages on public.room_messages;
create trigger rate_limit_room_messages before insert on public.room_messages
  for each row execute function public.enforce_insert_rate_limit('sender_id', '30', '60');

notify pgrst, 'reload schema';
commit;
