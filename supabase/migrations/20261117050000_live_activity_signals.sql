-- Live updates for posts, likes, comments and notifications.
--
-- The feed tables are not readable by clients (access goes through RPCs), so
-- Postgres Changes cannot be used. Instead, small "something changed" signals
-- are sent over private Realtime broadcast channels, and the app re-runs its
-- normal RPC to fetch fresh data. Signals carry only ids (no content, no
-- author), so they reveal nothing the app could not already see.
--
-- Topics
--   feed:unofficial / feed:official   post, like and reply activity (all rooms;
--                                     the payload names the room so apps filter)
--   user:<user id>                    notification changes for that user only
--
-- A failure to send a signal must never block the write itself, so every send
-- is wrapped in an exception handler.
begin;

create or replace function public.broadcast_feed_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  feed_mode text := tg_argv[0];
  activity_kind text := tg_argv[1];
  row_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  target_post uuid;
  target_room text;
begin
  if activity_kind = 'post' then
    target_post := (row_data ->> 'id')::uuid;
    target_room := row_data ->> 'room_id';
  else
    target_post := (row_data ->> 'post_id')::uuid;
    if feed_mode = 'official' then
      select p.room_id into target_room from public.official_posts as p where p.id = target_post;
    else
      select p.room_id into target_room from public.posts as p where p.id = target_post;
    end if;
  end if;

  begin
    perform realtime.send(
      jsonb_build_object(
        'kind', activity_kind,
        'op', lower(tg_op),
        'post_id', target_post,
        'room_id', target_room
      ),
      'activity',
      'feed:' || feed_mode,
      true
    );
  exception when others then
    null;
  end;
  return null;
end;
$$;

create or replace function public.broadcast_user_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  recipient uuid := (row_data ->> 'recipient_id')::uuid;
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'notification', 'op', lower(tg_op)),
      'activity',
      'user:' || recipient::text,
      true
    );
  exception when others then
    null;
  end;
  return null;
end;
$$;

revoke all on function public.broadcast_feed_activity() from public, anon, authenticated;
revoke all on function public.broadcast_user_activity() from public, anon, authenticated;

-- Unofficial feed
drop trigger if exists live_signal_posts on public.posts;
create trigger live_signal_posts after insert or update or delete on public.posts
  for each row execute function public.broadcast_feed_activity('unofficial', 'post');

drop trigger if exists live_signal_post_likes on public.post_likes;
create trigger live_signal_post_likes after insert or delete on public.post_likes
  for each row execute function public.broadcast_feed_activity('unofficial', 'like');

drop trigger if exists live_signal_post_replies on public.post_replies;
create trigger live_signal_post_replies after insert or delete on public.post_replies
  for each row execute function public.broadcast_feed_activity('unofficial', 'reply');

-- Official feed
drop trigger if exists live_signal_official_posts on public.official_posts;
create trigger live_signal_official_posts after insert or update or delete on public.official_posts
  for each row execute function public.broadcast_feed_activity('official', 'post');

drop trigger if exists live_signal_official_post_likes on public.official_post_likes;
create trigger live_signal_official_post_likes after insert or delete on public.official_post_likes
  for each row execute function public.broadcast_feed_activity('official', 'like');

drop trigger if exists live_signal_official_post_replies on public.official_post_replies;
create trigger live_signal_official_post_replies after insert or delete on public.official_post_replies
  for each row execute function public.broadcast_feed_activity('official', 'reply');

-- Notifications (new ones and "marked as read")
drop trigger if exists live_signal_notifications on public.app_notifications;
create trigger live_signal_notifications after insert or update or delete on public.app_notifications
  for each row execute function public.broadcast_user_activity();

-- Who may listen: signed-in campus members on the two feed topics, and each
-- user only on their own notification topic.
drop policy if exists "Campus members receive live activity signals" on realtime.messages;
create policy "Campus members receive live activity signals"
  on realtime.messages for select to authenticated
  using (
    extension = 'broadcast'
    and (
      (
        realtime.topic() in ('feed:unofficial', 'feed:official')
        and exists (
          select 1 from public.profiles as p
          where p.id = (select auth.uid())
            and p.role in ('student', 'faculty', 'super_admin')
        )
      )
      or realtime.topic() = 'user:' || (select auth.uid())::text
    )
  );

notify pgrst, 'reload schema';
commit;
