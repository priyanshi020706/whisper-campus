-- Mute for a while, and a 10-minute edit window.
--
--  * Rooms can be muted for a set time (1 hour, 8 hours...) or until the user
--    unmutes them. A timed mute simply stops counting once it has passed, so
--    nothing has to run to switch it off.
--  * Posts and comments can be edited for 10 minutes after posting (it was 24
--    hours).
begin;

------------------------------------------------------------------------------
-- Timed mutes
------------------------------------------------------------------------------
alter table public.room_mutes add column if not exists muted_until timestamptz;

-- Replaces the 3-argument version (two versions with defaults would be
-- ambiguous for the API).
drop function if exists public.set_room_muted(text, text, boolean);

-- p_minutes null means "until I unmute". Pass p_muted false to unmute.
create or replace function public.set_room_muted(
  p_room_id text,
  p_mode text,
  p_muted boolean,
  p_minutes integer default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You cannot mute this room' using errcode = '42501';
  end if;
  if p_minutes is not null and p_minutes not between 1 and 525600 then
    raise exception 'Choose a mute time between 1 minute and 1 year.';
  end if;

  -- Tidy: forget this person's mutes that have already run out.
  delete from public.room_mutes m
  where m.user_id = uid and m.muted_until is not null and m.muted_until <= now();

  if p_muted then
    insert into public.room_mutes as r (user_id, room_id, room_mode, muted_until)
    values (uid, p_room_id, p_mode,
            case when p_minutes is null then null else now() + make_interval(mins => p_minutes) end)
    on conflict (user_id, room_id, room_mode) do update
      set muted_until = excluded.muted_until, muted_at = now();
  else
    delete from public.room_mutes m
    where m.user_id = uid and m.room_id = p_room_id and m.room_mode = p_mode;
  end if;
end;
$$;

drop function if exists public.get_my_muted_rooms(text);
create function public.get_my_muted_rooms(p_mode text)
returns table (room_id text, muted_at timestamptz, muted_until timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.room_id, m.muted_at, m.muted_until
  from public.room_mutes m
  where auth.uid() is not null and m.user_id = auth.uid() and m.room_mode = p_mode
    and (m.muted_until is null or m.muted_until > now())
  order by m.muted_at desc;
$$;

drop function if exists public.get_my_room_activity(text);
create function public.get_my_room_activity(p_mode text)
returns table (
  room_id text,
  last_message_at timestamptz,
  last_message_mine boolean,
  unread_count integer,
  pinned boolean,
  pinned_at timestamptz,
  muted boolean,
  muted_until timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown mode';
  end if;

  return query
  with involved as (
    select r.room_id as rid from public.room_chat_reads as r
    where r.user_id = uid and r.room_mode = p_mode
    union
    select p.room_id from public.room_pins as p
    where p.user_id = uid and p.room_mode = p_mode
    union
    select m.room_id from public.room_mutes as m
    where m.user_id = uid and m.room_mode = p_mode
      and (m.muted_until is null or m.muted_until > now())
  )
  select
    i.rid,
    latest.created_at,
    coalesce(latest.sender_id = uid, false),
    coalesce(unread.total, 0),
    pin.room_id is not null,
    pin.pinned_at,
    mute.room_id is not null,
    mute.muted_until
  from involved as i
  left join lateral (
    select m.created_at, m.sender_id
    from public.room_messages as m
    where m.room_id = i.rid and m.room_mode = p_mode
      and m.created_at >= now() - interval '7 days'
    order by m.created_at desc
    limit 1
  ) as latest on true
  left join lateral (
    select count(*)::integer as total
    from public.room_messages as m
    left join public.room_chat_reads as rr
      on rr.room_id = i.rid and rr.room_mode = p_mode and rr.user_id = uid
    where m.room_id = i.rid and m.room_mode = p_mode
      and m.sender_id <> uid
      and m.created_at >= greatest(
        coalesce(rr.last_read_at, '-infinity'::timestamptz),
        now() - interval '7 days'
      )
  ) as unread on true
  left join public.room_pins as pin
    on pin.room_id = i.rid and pin.room_mode = p_mode and pin.user_id = uid
  left join public.room_mutes as mute
    on mute.room_id = i.rid and mute.room_mode = p_mode and mute.user_id = uid
    and (mute.muted_until is null or mute.muted_until > now())
  where i.rid not in ('general', 'official-live')
    and public.can_use_room_chat(i.rid, p_mode, uid);
end;
$$;

------------------------------------------------------------------------------
-- Pushes honour timed mutes
------------------------------------------------------------------------------
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
      and (p_room_mode is null or m.room_mode = p_room_mode)
      and (m.muted_until is null or m.muted_until > now())) then
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
      select 1 from public.room_mutes m
      where m.user_id = s.user_id and m.room_id = new.room_id
        and (m.muted_until is null or m.muted_until > now())));
  return null;
end;
$$;

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
      select 1 from public.room_mutes m
      where m.user_id = s.user_id and m.room_id = new.room_id
        and (m.muted_until is null or m.muted_until > now())));
  return null;
end;
$$;

------------------------------------------------------------------------------
-- 10-minute edit window
------------------------------------------------------------------------------
create or replace function public.edit_post(p_kind text, p_post_id uuid, p_content text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  clean text := btrim(coalesce(p_content, ''));
  row_room text;
  row_image text;
  row_created timestamptz;
  row_status text;
  new_status text;
begin
  if uid is null or not public.can_view_post_kind(p_kind, uid) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if char_length(clean) > 2000 then
    raise exception 'Posts can be at most 2000 characters.';
  end if;

  if p_kind = 'post' then
    select p.room_id, p.image_path, p.created_at, p.approval_status
      into row_room, row_image, row_created, row_status
    from public.posts p where p.id = p_post_id and p.author_id = uid for update;
  elsif p_kind = 'official_post' then
    select p.room_id, p.image_path, p.created_at, p.approval_status
      into row_room, row_image, row_created, row_status
    from public.official_posts p where p.id = p_post_id and p.author_id = uid for update;
  else
    raise exception 'Unknown post type';
  end if;

  if not found then
    raise exception 'You can only edit your own posts.';
  end if;
  if row_created < now() - interval '10 minutes' then
    raise exception 'Posts can be edited for 10 minutes after posting.';
  end if;
  if clean = '' and row_image is null then
    raise exception 'A post needs some text or an image.';
  end if;

  new_status := row_status;
  if row_status = 'approved' and public.post_needs_review(p_kind, row_room, uid) then
    new_status := 'pending';
  end if;

  if p_kind = 'post' then
    update public.posts
    set content = clean, edited_at = now(), approval_status = new_status
    where id = p_post_id;
  else
    update public.official_posts
    set content = clean, edited_at = now(), approval_status = new_status
    where id = p_post_id;
  end if;
  return new_status;
end;
$$;

create or replace function public.edit_reply(p_kind text, p_reply_id uuid, p_content text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  clean text := btrim(coalesce(p_content, ''));
  row_created timestamptz;
begin
  if uid is null or not public.can_view_post_kind(
      case p_kind when 'reply' then 'post' else 'official_post' end, uid) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if char_length(clean) not between 1 and 2000 then
    raise exception 'Comments must contain 1 to 2000 characters.';
  end if;

  if p_kind = 'reply' then
    select r.created_at into row_created
    from public.post_replies r where r.id = p_reply_id and r.author_id = uid for update;
  elsif p_kind = 'official_reply' then
    select r.created_at into row_created
    from public.official_post_replies r where r.id = p_reply_id and r.author_id = uid for update;
  else
    raise exception 'Unknown comment type';
  end if;
  if not found then
    raise exception 'You can only edit your own comments.';
  end if;
  if row_created < now() - interval '10 minutes' then
    raise exception 'Comments can be edited for 10 minutes after posting.';
  end if;

  if p_kind = 'reply' then
    update public.post_replies set content = clean, edited_at = now() where id = p_reply_id;
  else
    update public.official_post_replies set content = clean, edited_at = now() where id = p_reply_id;
  end if;
end;
$$;

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------
revoke all on function public.set_room_muted(text, text, boolean, integer) from public, anon, authenticated;
revoke all on function public.get_my_muted_rooms(text) from public, anon, authenticated;
revoke all on function public.get_my_room_activity(text) from public, anon, authenticated;
grant execute on function public.set_room_muted(text, text, boolean, integer) to authenticated;
grant execute on function public.get_my_muted_rooms(text) to authenticated;
grant execute on function public.get_my_room_activity(text) to authenticated;

notify pgrst, 'reload schema';
commit;
