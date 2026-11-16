-- Phase 3: search, events and announcements.
--
--  * search_posts      : find approved posts by title/text/tag. Results go
--                        through get_post_cards, so visibility rules and
--                        anonymity are exactly the same as in the feeds.
--  * campus_events     : events with date, place and Going / Interested counts.
--  * announcements     : notices, optionally pinned or tied to a room.
--
-- Who may post events and announcements: Super Admins, faculty, and active room
-- moderators (only for their own room). The organizer is shown by role ("Faculty",
-- "Room moderator"), never by name, so students stay anonymous.
begin;

------------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------------
-- Readable text of a stored post (title, body and tags), for searching.
create or replace function public.post_plain_text(p_content text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  doc jsonb;
begin
  if p_content is null then
    return '';
  end if;
  if left(p_content, 11) <> 'WC_POST_V1:' then
    return p_content;
  end if;
  begin
    doc := substr(p_content, 12)::jsonb;
  exception when others then
    return p_content;
  end;
  return trim(concat_ws(' ',
    doc ->> 'title',
    doc ->> 'body',
    (select string_agg(t, ' ') from jsonb_array_elements_text(
       case when jsonb_typeof(doc -> 'tags') = 'array' then doc -> 'tags' else '[]'::jsonb end) as t)
  ));
end;
$$;

create or replace function public.search_posts(
  p_kind text,
  p_query text,
  p_room_id text default null,
  p_limit integer default 30
)
returns table (
  post_kind text,
  post_id uuid,
  room_id text,
  author_label text,
  avatar_seed text,
  content text,
  image_path text,
  created_at timestamptz,
  like_count bigint,
  comment_count bigint,
  liked_by_me boolean,
  is_mine boolean,
  edited_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  needle text := btrim(coalesce(p_query, ''));
  pattern text;
  ids uuid[];
  cap integer := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  if uid is null or p_kind not in ('post', 'official_post')
     or not public.can_view_post_kind(p_kind, uid) then
    return;
  end if;
  if char_length(needle) < 2 then
    raise exception 'Type at least 2 characters to search.';
  end if;
  if char_length(needle) > 100 then
    raise exception 'That search is too long.';
  end if;
  -- Treat the query literally: escape LIKE wildcards.
  pattern := '%' || replace(replace(replace(needle, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  if p_kind = 'post' then
    select coalesce(array_agg(x.id), '{}') into ids from (
      select r.id from (
        select p.id, p.content, p.created_at from public.posts p
        where p.approval_status = 'approved'
          and (p_room_id is null or p.room_id = p_room_id)
        order by p.created_at desc limit 3000) r
      where public.post_plain_text(r.content) ilike pattern escape '\'
      order by r.created_at desc limit cap) x;
  else
    select coalesce(array_agg(x.id), '{}') into ids from (
      select r.id from (
        select p.id, p.content, p.created_at from public.official_posts p
        where p.approval_status = 'approved'
          and (p_room_id is null or p.room_id = p_room_id)
        order by p.created_at desc limit 3000) r
      where public.post_plain_text(r.content) ilike pattern escape '\'
      order by r.created_at desc limit cap) x;
  end if;

  return query
  select c.post_kind, c.post_id, c.room_id, c.author_label, c.avatar_seed, c.content,
         c.image_path, c.created_at, c.like_count, c.comment_count, c.liked_by_me,
         c.is_mine, c.edited_at
  from public.get_post_cards(p_kind, ids) c
  order by c.created_at desc;
end;
$$;

------------------------------------------------------------------------------
-- Who may publish campus content
------------------------------------------------------------------------------
create or replace function public.can_manage_campus_content(p_uid uuid, p_room_id text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null and (
    public.is_super_admin(p_uid)
    or public.is_faculty_account(p_uid)
    or (p_room_id is not null and (
      public.is_active_room_moderator(p_room_id, 'unofficial', p_uid)
      or public.is_active_room_moderator(p_room_id, 'official', p_uid)))
  );
$$;

-- The organizer as shown to everyone: a role, never a name.
create or replace function public.campus_organizer_label(p_uid uuid, p_room_id text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when public.is_super_admin(p_uid) then 'Admin'
    when public.is_faculty_account(p_uid) then 'Faculty'
    when p_room_id is not null then 'Room moderator'
    else 'Campus team'
  end;
$$;

create or replace function public.is_campus_member(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = p_uid and p.role in ('student', 'faculty', 'super_admin'));
$$;

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
create table if not exists public.campus_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text not null default '' check (char_length(description) <= 1000),
  location text not null default '' check (char_length(location) <= 120),
  starts_at timestamptz not null,
  ends_at timestamptz,
  room_id text references public.rooms(id) on delete set null,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  organizer_label text not null,
  cancelled boolean not null default false,
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);
create index if not exists campus_events_starts_idx on public.campus_events (starts_at);

create table if not exists public.event_rsvps (
  event_id uuid not null references public.campus_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('going', 'interested')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.campus_events enable row level security;
alter table public.event_rsvps enable row level security;
revoke all on table public.campus_events, public.event_rsvps from public, anon, authenticated;
grant all on table public.campus_events, public.event_rsvps to service_role;

create or replace function public.create_event(
  p_title text,
  p_description text,
  p_location text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_room_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
  recent integer;
begin
  if uid is null or not public.can_manage_campus_content(uid, p_room_id) then
    raise exception 'Only faculty, admins and room moderators can create events.' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then
    raise exception 'Give the event a title (up to 120 characters).';
  end if;
  if char_length(coalesce(p_description, '')) > 1000 then
    raise exception 'The description can be at most 1000 characters.';
  end if;
  if char_length(coalesce(p_location, '')) > 120 then
    raise exception 'The place can be at most 120 characters.';
  end if;
  if p_starts_at is null or p_starts_at < now() - interval '5 minutes'
     or p_starts_at > now() + interval '1 year' then
    raise exception 'Choose a start time in the next year.';
  end if;
  if p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'The event must end after it starts.';
  end if;
  if p_room_id is not null and not exists (select 1 from public.rooms r where r.id = p_room_id) then
    raise exception 'That room does not exist.';
  end if;

  select count(*) into recent from public.campus_events e
  where e.created_by = uid and e.created_at > now() - interval '24 hours';
  if recent >= 10 then
    raise exception 'You have created many events today. Please try again tomorrow.';
  end if;

  insert into public.campus_events
    (title, description, location, starts_at, ends_at, room_id, organizer_label)
  values
    (btrim(p_title), btrim(coalesce(p_description, '')), btrim(coalesce(p_location, '')),
     p_starts_at, p_ends_at, p_room_id, public.campus_organizer_label(uid, p_room_id))
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.cancel_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  update public.campus_events e set cancelled = true
  where e.id = p_event_id and (e.created_by = uid or public.is_super_admin(uid));
  if not found then
    raise exception 'You cannot cancel this event.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.list_events(p_include_past boolean default false, p_limit integer default 50)
returns table (
  event_id uuid,
  title text,
  description text,
  location text,
  starts_at timestamptz,
  ends_at timestamptz,
  room_id text,
  organizer_label text,
  cancelled boolean,
  going_count integer,
  interested_count integer,
  my_status text,
  can_manage boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or not public.is_campus_member(uid) then
    raise exception 'Campus account required' using errcode = '42501';
  end if;
  return query
  select e.id, e.title, e.description, e.location, e.starts_at, e.ends_at, e.room_id,
    e.organizer_label, e.cancelled,
    (select count(*)::integer from public.event_rsvps r where r.event_id = e.id and r.status = 'going'),
    (select count(*)::integer from public.event_rsvps r where r.event_id = e.id and r.status = 'interested'),
    (select r.status from public.event_rsvps r where r.event_id = e.id and r.user_id = uid),
    (e.created_by = uid or public.is_super_admin(uid))
  from public.campus_events e
  where case when p_include_past
      then true
      else coalesce(e.ends_at, e.starts_at + interval '3 hours') >= now() end
  order by case when p_include_past then null else e.starts_at end asc,
           case when p_include_past then e.starts_at end desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

-- Pass a status to set it; pass null (or the same status) to take it back.
create or replace function public.rsvp_event(p_event_id uuid, p_status text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  ev public.campus_events%rowtype;
  existing text;
begin
  if uid is null or not public.is_campus_member(uid) then
    raise exception 'Campus account required' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('going', 'interested') then
    raise exception 'Unknown response.';
  end if;
  select * into ev from public.campus_events e where e.id = p_event_id;
  if not found then
    raise exception 'That event no longer exists.';
  end if;
  if ev.cancelled then
    raise exception 'This event was cancelled.';
  end if;
  if coalesce(ev.ends_at, ev.starts_at + interval '3 hours') < now() then
    raise exception 'This event has already finished.';
  end if;

  select r.status into existing from public.event_rsvps r
  where r.event_id = p_event_id and r.user_id = uid;
  if p_status is null or p_status = existing then
    delete from public.event_rsvps r where r.event_id = p_event_id and r.user_id = uid;
  else
    insert into public.event_rsvps (event_id, user_id, status)
    values (p_event_id, uid, p_status)
    on conflict (event_id, user_id) do update set status = excluded.status, created_at = now();
  end if;
end;
$$;

------------------------------------------------------------------------------
-- Announcements
------------------------------------------------------------------------------
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  body text not null default '' check (char_length(body) <= 2000),
  pinned boolean not null default false,
  room_id text references public.rooms(id) on delete cascade,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  organizer_label text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
create index if not exists announcements_recent_idx on public.announcements (created_at desc);
alter table public.announcements enable row level security;
revoke all on table public.announcements from public, anon, authenticated;
grant all on table public.announcements to service_role;

create or replace function public.create_announcement(
  p_title text,
  p_body text,
  p_room_id text default null,
  p_pinned boolean default false,
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  campus_wide boolean := p_room_id is null;
  is_staff boolean;
  new_id uuid;
  recent integer;
begin
  is_staff := public.is_super_admin(uid) or public.is_faculty_account(uid);
  if uid is null or not public.can_manage_campus_content(uid, p_room_id) then
    raise exception 'Only faculty, admins and room moderators can post announcements.' using errcode = '42501';
  end if;
  if campus_wide and not is_staff then
    raise exception 'Room moderators can post announcements for their own room only.' using errcode = '42501';
  end if;
  if coalesce(p_pinned, false) and not is_staff then
    raise exception 'Only faculty and admins can pin announcements.' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 120 then
    raise exception 'Give the announcement a title (up to 120 characters).';
  end if;
  if char_length(coalesce(p_body, '')) > 2000 then
    raise exception 'The announcement can be at most 2000 characters.';
  end if;
  if p_expires_at is not null and (p_expires_at <= now() or p_expires_at > now() + interval '1 year') then
    raise exception 'Choose an end date in the next year.';
  end if;
  if p_room_id is not null and not exists (select 1 from public.rooms r where r.id = p_room_id) then
    raise exception 'That room does not exist.';
  end if;

  select count(*) into recent from public.announcements a
  where a.created_by = uid and a.created_at > now() - interval '24 hours';
  if recent >= 10 then
    raise exception 'You have posted many announcements today. Please try again tomorrow.';
  end if;

  insert into public.announcements (title, body, pinned, room_id, organizer_label, expires_at)
  values (btrim(p_title), btrim(coalesce(p_body, '')), coalesce(p_pinned, false), p_room_id,
          public.campus_organizer_label(uid, p_room_id), p_expires_at)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.delete_announcement(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  delete from public.announcements a
  where a.id = p_id and (a.created_by = uid or public.is_super_admin(uid));
  if not found then
    raise exception 'You cannot remove this announcement.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.list_announcements(p_limit integer default 30)
returns table (
  announcement_id uuid,
  title text,
  body text,
  pinned boolean,
  room_id text,
  organizer_label text,
  created_at timestamptz,
  expires_at timestamptz,
  can_manage boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or not public.is_campus_member(uid) then
    raise exception 'Campus account required' using errcode = '42501';
  end if;
  return query
  select a.id, a.title, a.body, a.pinned, a.room_id, a.organizer_label, a.created_at,
         a.expires_at, (a.created_by = uid or public.is_super_admin(uid))
  from public.announcements a
  where a.expires_at is null or a.expires_at > now()
  order by a.pinned desc, a.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

------------------------------------------------------------------------------
-- Live updates: one private topic for all campus members
------------------------------------------------------------------------------
create or replace function public.announce_campus_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', tg_argv[0], 'op', lower(tg_op)),
      'update', 'campus:updates', true);
  exception when others then
    null;
  end;
  return null;
end;
$$;

drop trigger if exists live_signal_campus_events on public.campus_events;
create trigger live_signal_campus_events
  after insert or update or delete on public.campus_events
  for each row execute function public.announce_campus_update('event');
drop trigger if exists live_signal_event_rsvps on public.event_rsvps;
create trigger live_signal_event_rsvps
  after insert or update or delete on public.event_rsvps
  for each row execute function public.announce_campus_update('event');
drop trigger if exists live_signal_announcements on public.announcements;
create trigger live_signal_announcements
  after insert or update or delete on public.announcements
  for each row execute function public.announce_campus_update('announcement');

drop policy if exists "Campus members receive campus updates" on realtime.messages;
create policy "Campus members receive campus updates"
  on realtime.messages for select to authenticated
  using (
    extension = 'broadcast'
    and realtime.topic() = 'campus:updates'
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.role in ('student', 'faculty', 'super_admin'))
  );

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------
revoke all on function public.post_plain_text(text) from public, anon, authenticated;
revoke all on function public.can_manage_campus_content(uuid, text) from public, anon, authenticated;
revoke all on function public.campus_organizer_label(uuid, text) from public, anon, authenticated;
revoke all on function public.is_campus_member(uuid) from public, anon, authenticated;
revoke all on function public.announce_campus_update() from public, anon, authenticated;

revoke all on function public.search_posts(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.create_event(text, text, text, timestamptz, timestamptz, text) from public, anon, authenticated;
revoke all on function public.cancel_event(uuid) from public, anon, authenticated;
revoke all on function public.list_events(boolean, integer) from public, anon, authenticated;
revoke all on function public.rsvp_event(uuid, text) from public, anon, authenticated;
revoke all on function public.create_announcement(text, text, text, boolean, timestamptz) from public, anon, authenticated;
revoke all on function public.delete_announcement(uuid) from public, anon, authenticated;
revoke all on function public.list_announcements(integer) from public, anon, authenticated;

grant execute on function public.search_posts(text, text, text, integer) to authenticated;
grant execute on function public.create_event(text, text, text, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.cancel_event(uuid) to authenticated;
grant execute on function public.list_events(boolean, integer) to authenticated;
grant execute on function public.rsvp_event(uuid, text) to authenticated;
grant execute on function public.create_announcement(text, text, text, boolean, timestamptz) to authenticated;
grant execute on function public.delete_announcement(uuid) to authenticated;
grant execute on function public.list_announcements(integer) to authenticated;

notify pgrst, 'reload schema';
commit;
