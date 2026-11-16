-- Phase 4: push notifications (Web Push).
--
-- How it works
--   1. The browser subscribes and the app saves the subscription with
--      save_push_subscription.
--   2. Database triggers decide who should be notified (respecting the user's
--      notification settings and muted rooms) and add rows to push_outbox.
--   3. A statement trigger asks the "send-push" Edge Function to deliver the
--      queued rows (via pg_net). A one-minute pg_cron job repeats this so a
--      missed call is retried.
--   4. The Edge Function sends the messages and marks them sent.
--
-- Nothing here reveals who did something: pushes say "Someone liked your post",
-- never a name, so anonymity is kept even on a lock screen.
--
-- Setup is explained in supabase/README.md (VAPID keys, secrets, push_settings).
begin;

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (char_length(endpoint) between 20 and 2048),
  p256dh text not null check (char_length(p256dh) between 20 and 200),
  auth text not null check (char_length(auth) between 8 and 100),
  user_agent text check (char_length(user_agent) <= 300),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

create table if not exists public.push_outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  url text not null default '/',
  tag text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts integer not null default 0,
  last_error text
);
create index if not exists push_outbox_unsent_idx on public.push_outbox (id) where sent_at is null;
create index if not exists push_outbox_tag_idx on public.push_outbox (user_id, tag, created_at desc);

-- Where the Edge Function lives and the shared secret it expects. Filled in once
-- by an admin (see supabase/README.md). Never readable by clients.
create table if not exists public.push_settings (
  id integer primary key check (id = 1),
  function_url text not null,
  shared_secret text not null
);

alter table public.push_subscriptions enable row level security;
alter table public.push_outbox enable row level security;
alter table public.push_settings enable row level security;
revoke all on table public.push_subscriptions, public.push_outbox, public.push_settings
  from public, anon, authenticated;
grant all on table public.push_subscriptions, public.push_outbox, public.push_settings
  to service_role;

alter table public.campus_events add column if not exists reminder_sent boolean not null default false;

------------------------------------------------------------------------------
-- Device subscriptions
------------------------------------------------------------------------------
create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or not public.is_campus_member(uid) then
    raise exception 'Campus account required' using errcode = '42501';
  end if;
  if p_endpoint is null or p_endpoint !~ '^https://' then
    raise exception 'Invalid push subscription.';
  end if;

  -- The same browser may have been used by someone else before: the endpoint
  -- moves to the account that is signed in now.
  insert into public.push_subscriptions as s (user_id, endpoint, p256dh, auth, user_agent)
  values (uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, last_seen_at = now();

  -- Keep at most 5 devices per person.
  delete from public.push_subscriptions s
  where s.user_id = uid and s.id not in (
    select x.id from public.push_subscriptions x
    where x.user_id = uid order by x.last_seen_at desc limit 5);
end;
$$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_subscriptions s
  where s.endpoint = p_endpoint and s.user_id = auth.uid();
$$;

create or replace function public.has_push_subscription(p_endpoint text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.push_subscriptions s
    where s.endpoint = p_endpoint and s.user_id = auth.uid());
$$;

------------------------------------------------------------------------------
-- Queueing
------------------------------------------------------------------------------
-- Adds a push for one person if they want it. Internal: called by triggers.
create or replace function public.enqueue_push(
  p_user uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_url text,
  p_tag text,
  p_room_id text default null,
  p_room_mode text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  wanted boolean;
begin
  if p_user is null then
    return;
  end if;
  if not exists (select 1 from public.push_subscriptions s where s.user_id = p_user) then
    return;
  end if;

  select case p_kind
    when 'like' then coalesce(n.likes, true)
    when 'comment' then coalesce(n.comments, true)
    when 'chat_reply' then coalesce(n.chat_replies, true)
    when 'event' then coalesce(n.events, true)
    when 'announcement' then coalesce(n.announcements, true)
    else true end
  into wanted
  from (select 1) one
  left join public.notification_prefs n on n.user_id = p_user;
  if not coalesce(wanted, true) then
    return;
  end if;

  if p_room_id is not null and exists (
    select 1 from public.room_mutes m
    where m.user_id = p_user and m.room_id = p_room_id
      and (p_room_mode is null or m.room_mode = p_room_mode)) then
    return;
  end if;

  -- One push per thing is enough: skip repeats of the same tag for a minute.
  if p_tag is not null and exists (
    select 1 from public.push_outbox o
    where o.user_id = p_user and o.tag = p_tag
      and o.created_at > now() - interval '1 minute') then
    return;
  end if;

  insert into public.push_outbox (user_id, kind, title, body, url, tag)
  values (p_user, p_kind, left(p_title, 120), left(coalesce(p_body, ''), 200),
          coalesce(p_url, '/'), p_tag);
end;
$$;

-- Likes and comments on my posts.
create or replace function public.push_for_post_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.enqueue_push(
    new.recipient_id,
    case when new.activity_type = 'like' then 'like' else 'comment' end,
    case when new.activity_type = 'like'
      then 'Someone liked your post' else 'Someone commented on your post' end,
    'Open Whisper Campus to see it.',
    '/',
    new.activity_type || '-' || new.post_id::text);
  return null;
end;
$$;
drop trigger if exists push_post_activity on public.app_notifications;
create trigger push_post_activity after insert on public.app_notifications
  for each row execute function public.push_for_post_activity();

-- Someone replied to my chat message.
create or replace function public.push_for_chat_reply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  original_sender uuid;
  room_label text;
begin
  select q.sender_id into original_sender from public.room_messages q where q.id = new.reply_to;
  if original_sender is null or original_sender = new.sender_id then
    return null;
  end if;
  select coalesce(nullif(r.name, ''), new.room_id) into room_label
  from public.rooms r where r.id = new.room_id;
  perform public.enqueue_push(
    original_sender, 'chat_reply',
    'New reply in ' || coalesce(room_label, 'a room'),
    'Someone replied to your message.',
    '/', 'chat-reply-' || new.id::text, new.room_id, new.room_mode);
  return null;
end;
$$;
drop trigger if exists push_chat_reply on public.room_messages;
create trigger push_chat_reply
  after update of reply_to on public.room_messages
  for each row
  when (old.reply_to is distinct from new.reply_to and new.reply_to is not null)
  execute function public.push_for_chat_reply();

-- New announcements go to everyone with a subscribed device.
create or replace function public.push_for_announcement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.push_outbox (user_id, kind, title, body, url, tag)
  select s.user_id, 'announcement', left(new.title, 120),
         left(coalesce(nullif(new.body, ''), new.organizer_label), 200),
         '/', 'announcement-' || new.id::text
  from (select distinct user_id from public.push_subscriptions) s
  join public.profiles p on p.id = s.user_id and p.role in ('student', 'faculty', 'super_admin')
  left join public.notification_prefs n on n.user_id = s.user_id
  where coalesce(n.announcements, true)
    and s.user_id is distinct from new.created_by
    and (new.room_id is null or not exists (
      select 1 from public.room_mutes m where m.user_id = s.user_id and m.room_id = new.room_id));
  return null;
end;
$$;
drop trigger if exists push_announcement on public.announcements;
create trigger push_announcement after insert on public.announcements
  for each row execute function public.push_for_announcement();

-- New events go to everyone with a subscribed device.
create or replace function public.push_for_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.push_outbox (user_id, kind, title, body, url, tag)
  select s.user_id, 'event', left('New event: ' || new.title, 120),
         to_char(new.starts_at at time zone 'Asia/Kolkata', 'Dy DD Mon, HH24:MI')
           || case when new.location <> '' then ' · ' || new.location else '' end,
         '/', 'event-' || new.id::text
  from (select distinct user_id from public.push_subscriptions) s
  join public.profiles p on p.id = s.user_id and p.role in ('student', 'faculty', 'super_admin')
  left join public.notification_prefs n on n.user_id = s.user_id
  where coalesce(n.events, true)
    and s.user_id is distinct from new.created_by
    and (new.room_id is null or not exists (
      select 1 from public.room_mutes m where m.user_id = s.user_id and m.room_id = new.room_id));
  return null;
end;
$$;
drop trigger if exists push_event on public.campus_events;
create trigger push_event after insert on public.campus_events
  for each row execute function public.push_for_event();

-- Reminder about an hour before an event, for people who said they are going.
create or replace function public.queue_event_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  due record;
  total integer := 0;
begin
  for due in
    select e.id, e.title, e.location
    from public.campus_events e
    where not e.cancelled and not e.reminder_sent
      and e.starts_at between now() + interval '30 minutes' and now() + interval '65 minutes'
    for update skip locked
  loop
    insert into public.push_outbox (user_id, kind, title, body, url, tag)
    select r.user_id, 'event', left('Starting soon: ' || due.title, 120),
           'Starts in about an hour' || case when due.location <> '' then ' · ' || due.location else '' end,
           '/', 'event-reminder-' || due.id::text
    from public.event_rsvps r
    join public.push_subscriptions s on s.user_id = r.user_id
    left join public.notification_prefs n on n.user_id = r.user_id
    where r.event_id = due.id and r.status = 'going' and coalesce(n.events, true)
    group by r.user_id;
    update public.campus_events set reminder_sent = true where id = due.id;
    total := total + 1;
  end loop;
  return total;
end;
$$;

------------------------------------------------------------------------------
-- Delivery
------------------------------------------------------------------------------
-- Asks the Edge Function to send whatever is waiting. Safe to call any time;
-- does nothing until push_settings is filled in and pg_net is available.
create or replace function public.dispatch_push_queue()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.push_settings%rowtype;
begin
  select * into cfg from public.push_settings s where s.id = 1;
  if not found or to_regnamespace('net') is null then
    return;
  end if;
  begin
    execute 'select net.http_post(url := $1, headers := $2, body := $3)'
      using cfg.function_url,
            jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.shared_secret),
            '{}'::jsonb;
  exception when others then
    null; -- a failed call must never block the write that queued the push
  end;
end;
$$;

create or replace function public.dispatch_push_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.dispatch_push_queue();
  return null;
end;
$$;
drop trigger if exists push_outbox_dispatch on public.push_outbox;
create trigger push_outbox_dispatch
  after insert on public.push_outbox
  referencing new table as inserted
  for each statement execute function public.dispatch_push_after_insert();

-- Retry every minute and send event reminders every ten, when pg_cron exists.
do $$
begin
  begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      execute 'create extension pg_cron';
    end if;
    if to_regnamespace('cron') is not null then
      execute $q$select cron.schedule('whisper-push-retry', '* * * * *',
        $job$select public.dispatch_push_queue()$job$)$q$;
      execute $q$select cron.schedule('whisper-event-reminders', '*/10 * * * *',
        $job$select public.queue_event_reminders()$job$)$q$;
    end if;
  exception when others then
    raise notice 'pg_cron is not available; push retries and event reminders are off (%).', sqlerrm;
  end;
end
$$;

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------
revoke all on function public.enqueue_push(uuid, text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_for_post_activity() from public, anon, authenticated;
revoke all on function public.push_for_chat_reply() from public, anon, authenticated;
revoke all on function public.push_for_announcement() from public, anon, authenticated;
revoke all on function public.push_for_event() from public, anon, authenticated;
revoke all on function public.queue_event_reminders() from public, anon, authenticated;
revoke all on function public.dispatch_push_queue() from public, anon, authenticated;
revoke all on function public.dispatch_push_after_insert() from public, anon, authenticated;

revoke all on function public.save_push_subscription(text, text, text, text) from public, anon, authenticated;
revoke all on function public.remove_push_subscription(text) from public, anon, authenticated;
revoke all on function public.has_push_subscription(text) from public, anon, authenticated;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.remove_push_subscription(text) to authenticated;
grant execute on function public.has_push_subscription(text) to authenticated;

notify pgrst, 'reload schema';
commit;
