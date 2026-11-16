-- Recent chats and pinned rooms for room conversations.
--
-- get_my_room_activity(mode) tells the app, for every room the signed-in user
-- has joined the chat of (or pinned), when its latest message arrived, whether
-- that message was theirs, how many messages are unread, and whether the room is
-- pinned. The app orders rooms by this: pinned first, then by latest message.
--
-- Pins are stored per user and per mode, at most 3 each, enforced here so the
-- limit cannot be bypassed from the client.
begin;

create table if not exists public.room_pins (
  user_id uuid not null references auth.users(id) on delete cascade,
  room_id text not null references public.rooms(id) on delete cascade,
  room_mode text not null check (room_mode in ('official', 'unofficial')),
  pinned_at timestamptz not null default now(),
  primary key (user_id, room_id, room_mode)
);

alter table public.room_pins enable row level security;
revoke all on table public.room_pins from public, anon, authenticated;
grant all on table public.room_pins to service_role;

create or replace function public.pin_room(p_room_id text, p_mode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  pinned_count integer;
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You cannot pin this room' using errcode = '42501';
  end if;

  -- Serialise a user's pin changes so two quick taps cannot exceed the limit.
  perform pg_advisory_xact_lock(hashtextextended(uid::text || ':' || p_mode, 0));

  if exists (
    select 1 from public.room_pins p
    where p.user_id = uid and p.room_id = p_room_id and p.room_mode = p_mode
  ) then
    return;
  end if;

  select count(*) into pinned_count
  from public.room_pins p
  where p.user_id = uid and p.room_mode = p_mode;
  if pinned_count >= 3 then
    raise exception 'You can pin up to 3 rooms. Unpin one first.';
  end if;

  insert into public.room_pins (user_id, room_id, room_mode)
  values (uid, p_room_id, p_mode);
end;
$$;

create or replace function public.unpin_room(p_room_id text, p_mode text)
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
  delete from public.room_pins p
  where p.user_id = uid and p.room_id = p_room_id and p.room_mode = p_mode;
end;
$$;

create or replace function public.get_my_room_activity(p_mode text)
returns table (
  room_id text,
  last_message_at timestamptz,
  last_message_mine boolean,
  unread_count integer,
  pinned boolean,
  pinned_at timestamptz
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
    -- Rooms whose chat I have joined, plus rooms I pinned.
    select r.room_id as rid
    from public.room_chat_reads as r
    where r.user_id = uid and r.room_mode = p_mode
    union
    select p.room_id
    from public.room_pins as p
    where p.user_id = uid and p.room_mode = p_mode
  )
  select
    i.rid,
    latest.created_at,
    coalesce(latest.sender_id = uid, false),
    coalesce(unread.total, 0),
    pin.room_id is not null,
    pin.pinned_at
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
  where i.rid not in ('general', 'official-live')
    and public.can_use_room_chat(i.rid, p_mode, uid);
end;
$$;

revoke all on function public.pin_room(text, text) from public, anon, authenticated;
revoke all on function public.unpin_room(text, text) from public, anon, authenticated;
revoke all on function public.get_my_room_activity(text) from public, anon, authenticated;
grant execute on function public.pin_room(text, text) to authenticated;
grant execute on function public.unpin_room(text, text) to authenticated;
grant execute on function public.get_my_room_activity(text) to authenticated;

notify pgrst, 'reload schema';
commit;
