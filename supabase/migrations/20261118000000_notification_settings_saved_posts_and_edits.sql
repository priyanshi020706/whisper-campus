-- Phase 1: notification settings and muted rooms, saved posts, and editing.
--
--  * notification_prefs  : per-user switches (likes, comments, chat replies,
--                          events, announcements). In-app notifications and
--                          later push messages respect them.
--  * room_mutes          : rooms a user muted. get_my_room_activity reports it.
--  * saved_posts         : bookmarks. Saved posts are re-checked for visibility
--                          every time they are read.
--  * edited_at + RPCs    : authors can edit their own posts and comments for 24
--                          hours. An approved post that a moderator would have
--                          to review is sent back for review after an edit, so
--                          editing cannot be used to bypass moderation.
begin;

------------------------------------------------------------------------------
-- Notification preferences
------------------------------------------------------------------------------
create table if not exists public.notification_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  likes boolean not null default true,
  comments boolean not null default true,
  chat_replies boolean not null default true,
  events boolean not null default true,
  announcements boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;
revoke all on table public.notification_prefs from public, anon, authenticated;
grant all on table public.notification_prefs to service_role;

create or replace function public.get_my_notification_prefs()
returns table (
  likes boolean,
  comments boolean,
  chat_replies boolean,
  events boolean,
  announcements boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  return query
  select coalesce(p.likes, true), coalesce(p.comments, true),
         coalesce(p.chat_replies, true), coalesce(p.events, true),
         coalesce(p.announcements, true)
  from (select 1) as one
  left join public.notification_prefs as p on p.user_id = auth.uid();
end;
$$;

-- Null means "leave unchanged".
create or replace function public.set_my_notification_prefs(
  p_likes boolean default null,
  p_comments boolean default null,
  p_chat_replies boolean default null,
  p_events boolean default null,
  p_announcements boolean default null
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
  insert into public.notification_prefs as n (user_id, likes, comments, chat_replies, events, announcements)
  values (uid, coalesce(p_likes, true), coalesce(p_comments, true),
          coalesce(p_chat_replies, true), coalesce(p_events, true),
          coalesce(p_announcements, true))
  on conflict (user_id) do update set
    likes = coalesce(p_likes, n.likes),
    comments = coalesce(p_comments, n.comments),
    chat_replies = coalesce(p_chat_replies, n.chat_replies),
    events = coalesce(p_events, n.events),
    announcements = coalesce(p_announcements, n.announcements),
    updated_at = now();
end;
$$;

-- In-app notifications now honour the like / comment switches.
create or replace function public.get_my_notifications(p_limit integer default 50)
returns table(
  notification_id uuid,
  actor_name text,
  campus_mode text,
  activity_type text,
  post_id uuid,
  preview text,
  created_at timestamptz,
  read_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select n.id,
    case when n.campus_mode = 'official'
      then coalesce(nullif(btrim(identity.real_name), ''), 'MITS member')
      else coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous') end::text,
    n.campus_mode, n.activity_type, n.post_id, n.preview, n.created_at, n.read_at
  from public.app_notifications n
  left join public.identity_records identity on identity.user_id = n.actor_id
  left join public.profiles profile on profile.id = n.actor_id
  left join public.notification_prefs pref on pref.user_id = n.recipient_id
  where auth.uid() is not null and n.recipient_id = auth.uid()
    and (n.activity_type <> 'like' or coalesce(pref.likes, true))
    and (n.activity_type <> 'comment' or coalesce(pref.comments, true))
  order by n.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
$$;

create or replace function public.get_my_unread_notification_count()
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.app_notifications n
  left join public.notification_prefs pref on pref.user_id = n.recipient_id
  where auth.uid() is not null and n.recipient_id = auth.uid() and n.read_at is null
    and (n.activity_type <> 'like' or coalesce(pref.likes, true))
    and (n.activity_type <> 'comment' or coalesce(pref.comments, true));
$$;

------------------------------------------------------------------------------
-- Muted rooms
------------------------------------------------------------------------------
create table if not exists public.room_mutes (
  user_id uuid not null references auth.users(id) on delete cascade,
  room_id text not null references public.rooms(id) on delete cascade,
  room_mode text not null check (room_mode in ('official', 'unofficial')),
  muted_at timestamptz not null default now(),
  primary key (user_id, room_id, room_mode)
);
alter table public.room_mutes enable row level security;
revoke all on table public.room_mutes from public, anon, authenticated;
grant all on table public.room_mutes to service_role;

create or replace function public.set_room_muted(p_room_id text, p_mode text, p_muted boolean)
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
  if p_muted then
    insert into public.room_mutes (user_id, room_id, room_mode)
    values (uid, p_room_id, p_mode)
    on conflict do nothing;
  else
    delete from public.room_mutes m
    where m.user_id = uid and m.room_id = p_room_id and m.room_mode = p_mode;
  end if;
end;
$$;

create or replace function public.get_my_muted_rooms(p_mode text)
returns table (room_id text, muted_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.room_id, m.muted_at
  from public.room_mutes m
  where auth.uid() is not null and m.user_id = auth.uid() and m.room_mode = p_mode
  order by m.muted_at desc;
$$;

-- get_my_room_activity gains "muted" (a new return column needs a new function).
drop function if exists public.get_my_room_activity(text);
create function public.get_my_room_activity(p_mode text)
returns table (
  room_id text,
  last_message_at timestamptz,
  last_message_mine boolean,
  unread_count integer,
  pinned boolean,
  pinned_at timestamptz,
  muted boolean
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
  )
  select
    i.rid,
    latest.created_at,
    coalesce(latest.sender_id = uid, false),
    coalesce(unread.total, 0),
    pin.room_id is not null,
    pin.pinned_at,
    mute.room_id is not null
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
  where i.rid not in ('general', 'official-live')
    and public.can_use_room_chat(i.rid, p_mode, uid);
end;
$$;

------------------------------------------------------------------------------
-- Who may see posts (the same rules the feeds use)
------------------------------------------------------------------------------
create or replace function public.can_view_post_kind(p_kind text, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_kind
    when 'post' then exists (
      select 1 from public.profiles p
      where p.id = p_uid and p.role in ('student', 'faculty', 'super_admin'))
    when 'official_post' then public.is_eligible_official_user(p_uid)
    else false
  end;
$$;

------------------------------------------------------------------------------
-- Edit times
------------------------------------------------------------------------------
alter table public.posts add column if not exists edited_at timestamptz;
alter table public.post_replies add column if not exists edited_at timestamptz;
alter table public.official_posts add column if not exists edited_at timestamptz;
alter table public.official_post_replies add column if not exists edited_at timestamptz;

------------------------------------------------------------------------------
-- Post cards: one shape for saved posts (and, later, search results)
------------------------------------------------------------------------------
-- Internal helper: not callable by clients. It re-checks, for every id, that
-- the caller may see the post and that it is approved.
create or replace function public.get_post_cards(p_kind text, p_ids uuid[])
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
begin
  if uid is null or not public.can_view_post_kind(p_kind, uid) then
    return;
  end if;

  if p_kind = 'post' then
    return query
    select 'post'::text, post.id, post.room_id,
      (coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')
        || case when public.is_active_room_moderator(post.room_id, 'unofficial', post.author_id)
             then ' (Moderator)' else '' end)::text,
      profile.avatar_seed::text, post.content, post.image_path, post.created_at,
      (select count(*) from public.post_likes l where l.post_id = post.id)::bigint,
      (select count(*) from public.post_replies r where r.post_id = post.id)::bigint,
      exists (select 1 from public.post_likes l where l.post_id = post.id and l.user_id = uid),
      post.author_id = uid,
      post.edited_at
    from public.posts post
    left join public.profiles profile on profile.id = post.author_id
    where post.id = any (p_ids) and post.approval_status = 'approved';
  else
    return query
    select 'official_post'::text, post.id, post.room_id,
      (coalesce(nullif(btrim(i.real_name), ''), 'Student')
        || case when public.is_active_room_moderator(post.room_id, 'official', post.author_id)
             then ' (Moderator)' else '' end)::text,
      null::text, post.content, post.image_path, post.created_at,
      (select count(*) from public.official_post_likes l where l.post_id = post.id)::bigint,
      (select count(*) from public.official_post_replies r where r.post_id = post.id)::bigint,
      exists (select 1 from public.official_post_likes l where l.post_id = post.id and l.user_id = uid),
      post.author_id = uid,
      post.edited_at
    from public.official_posts post
    left join public.identity_records i on i.user_id = post.author_id
    where post.id = any (p_ids) and post.approval_status = 'approved';
  end if;
end;
$$;

------------------------------------------------------------------------------
-- Saved posts
------------------------------------------------------------------------------
create table if not exists public.saved_posts (
  user_id uuid not null references auth.users(id) on delete cascade,
  post_kind text not null check (post_kind in ('post', 'official_post')),
  post_id uuid not null,
  saved_at timestamptz not null default now(),
  primary key (user_id, post_kind, post_id)
);
create index if not exists saved_posts_user_saved_idx
  on public.saved_posts (user_id, saved_at desc);
alter table public.saved_posts enable row level security;
revoke all on table public.saved_posts from public, anon, authenticated;
grant all on table public.saved_posts to service_role;

-- Remove bookmarks when the post itself is deleted.
create or replace function public.cleanup_saved_posts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.saved_posts s
  where s.post_id = old.id and s.post_kind = tg_argv[0];
  return old;
end;
$$;
revoke all on function public.cleanup_saved_posts() from public, anon, authenticated;

drop trigger if exists cleanup_saved_posts on public.posts;
create trigger cleanup_saved_posts after delete on public.posts
  for each row execute function public.cleanup_saved_posts('post');
drop trigger if exists cleanup_saved_official_posts on public.official_posts;
create trigger cleanup_saved_official_posts after delete on public.official_posts
  for each row execute function public.cleanup_saved_posts('official_post');

create or replace function public.save_post(p_kind text, p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  saved_total integer;
begin
  if uid is null or not public.can_view_post_kind(p_kind, uid) then
    raise exception 'You cannot save this post' using errcode = '42501';
  end if;
  if not exists (select 1 from public.get_post_cards(p_kind, array[p_post_id])) then
    raise exception 'That post is not available';
  end if;
  if exists (
    select 1 from public.saved_posts s
    where s.user_id = uid and s.post_kind = p_kind and s.post_id = p_post_id
  ) then
    return;
  end if;
  select count(*) into saved_total from public.saved_posts s where s.user_id = uid;
  if saved_total >= 200 then
    raise exception 'You can save up to 200 posts. Remove some first.';
  end if;
  insert into public.saved_posts (user_id, post_kind, post_id)
  values (uid, p_kind, p_post_id);
end;
$$;

create or replace function public.unsave_post(p_kind text, p_post_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.saved_posts s
  where s.user_id = auth.uid() and s.post_kind = p_kind and s.post_id = p_post_id;
$$;

-- Which of the given posts have I saved? (for the bookmark icons)
create or replace function public.get_my_saved_post_ids(p_kind text)
returns table (post_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select s.post_id from public.saved_posts s
  where auth.uid() is not null and s.user_id = auth.uid() and s.post_kind = p_kind;
$$;

create or replace function public.get_my_saved_posts()
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
  edited_at timestamptz,
  saved_at timestamptz
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
  return query
  select c.post_kind, c.post_id, c.room_id, c.author_label, c.avatar_seed,
         c.content, c.image_path, c.created_at, c.like_count, c.comment_count,
         c.liked_by_me, c.is_mine, c.edited_at, s.saved_at
  from public.saved_posts s
  join lateral (
    select * from public.get_post_cards(
      s.post_kind, array[s.post_id])
  ) c on true
  where s.user_id = uid
  order by s.saved_at desc
  limit 200;
end;
$$;

------------------------------------------------------------------------------
-- Editing posts and comments
------------------------------------------------------------------------------
-- Does a post by this author in this room need a moderator's review?
create or replace function public.post_needs_review(p_kind text, p_room text, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_kind
    when 'post' then not (
      public.is_faculty_account(p_uid) or public.is_super_admin(p_uid)
      or public.is_active_room_moderator(p_room, 'unofficial', p_uid))
    else not (
      public.is_faculty(p_uid) or public.is_super_admin(p_uid)
      or public.is_active_room_moderator(p_room, 'official', p_uid))
  end;
$$;

-- Returns 'approved' when the edit is live, 'pending' when it needs review.
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
  if row_created < now() - interval '24 hours' then
    raise exception 'Posts can be edited for 24 hours after posting.';
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
  if row_created < now() - interval '24 hours' then
    raise exception 'Comments can be edited for 24 hours after posting.';
  end if;

  if p_kind = 'reply' then
    update public.post_replies set content = clean, edited_at = now() where id = p_reply_id;
  else
    update public.official_post_replies set content = clean, edited_at = now() where id = p_reply_id;
  end if;
end;
$$;

-- Which of these items were edited? kind: post, official_post, reply,
-- official_reply. Only edit times are returned.
create or replace function public.get_edit_times(p_kind text, p_ids uuid[])
returns table (item_id uuid, edited_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    return;
  end if;
  if p_kind = 'post' then
    return query select x.id, x.edited_at from public.posts x
      where x.id = any (p_ids) and x.edited_at is not null and x.approval_status = 'approved';
  elsif p_kind = 'official_post' then
    return query select x.id, x.edited_at from public.official_posts x
      where x.id = any (p_ids) and x.edited_at is not null and x.approval_status = 'approved';
  elsif p_kind = 'reply' then
    return query select x.id, x.edited_at from public.post_replies x
      where x.id = any (p_ids) and x.edited_at is not null;
  elsif p_kind = 'official_reply' then
    return query select x.id, x.edited_at from public.official_post_replies x
      where x.id = any (p_ids) and x.edited_at is not null;
  end if;
end;
$$;

-- Comments with their ids, "mine" and edit time (the older comment RPCs do not
-- return these). kind: post or official_post.
create or replace function public.get_post_replies_v2(p_kind text, p_post_id uuid)
returns table (
  reply_id uuid,
  author_label text,
  avatar_seed text,
  content text,
  created_at timestamptz,
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
begin
  if uid is null or not public.can_view_post_kind(p_kind, uid) then
    raise exception 'Post is not available' using errcode = '42501';
  end if;

  if p_kind = 'post' then
    if not exists (select 1 from public.posts p where p.id = p_post_id and p.approval_status = 'approved') then
      raise exception 'Post is not available' using errcode = '42501';
    end if;
    return query
    select r.id,
      (coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')
        || case when public.is_active_room_moderator(post.room_id, 'unofficial', r.author_id)
             then ' (Moderator)' else '' end)::text,
      profile.avatar_seed::text, r.content, r.created_at, r.author_id = uid, r.edited_at
    from public.post_replies r
    join public.posts post on post.id = r.post_id
    left join public.profiles profile on profile.id = r.author_id
    where r.post_id = p_post_id
    order by r.created_at asc;
  elsif p_kind = 'official_post' then
    if not exists (select 1 from public.official_posts p where p.id = p_post_id and p.approval_status = 'approved') then
      raise exception 'Post is not available' using errcode = '42501';
    end if;
    return query
    select r.id,
      (coalesce(nullif(btrim(i.real_name), ''), 'Student')
        || case when p.role = 'faculty' then ' · Faculty'
             || case when p.branch_code is null then '' else ' · ' || p.branch_code end
           else '' end)::text,
      null::text, r.content, r.created_at, r.author_id = uid, r.edited_at
    from public.official_post_replies r
    join public.profiles p on p.id = r.author_id
    left join public.identity_records i on i.user_id = r.author_id
    where r.post_id = p_post_id
    order by r.created_at asc;
  else
    raise exception 'Unknown post type';
  end if;
end;
$$;

-- Other people see an edited comment live: signal updates as well as inserts.
drop trigger if exists live_signal_post_replies on public.post_replies;
create trigger live_signal_post_replies
  after insert or update of content or delete on public.post_replies
  for each row execute function public.broadcast_feed_activity('unofficial', 'reply');
drop trigger if exists live_signal_official_post_replies on public.official_post_replies;
create trigger live_signal_official_post_replies
  after insert or update of content or delete on public.official_post_replies
  for each row execute function public.broadcast_feed_activity('official', 'reply');

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------
revoke all on function public.can_view_post_kind(text, uuid) from public, anon, authenticated;
revoke all on function public.post_needs_review(text, text, uuid) from public, anon, authenticated;
revoke all on function public.get_post_cards(text, uuid[]) from public, anon, authenticated;
revoke all on function public.cleanup_saved_posts() from public, anon, authenticated;

revoke all on function public.get_my_notification_prefs() from public, anon, authenticated;
revoke all on function public.set_my_notification_prefs(boolean, boolean, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function public.get_my_notifications(integer) from public, anon, authenticated;
revoke all on function public.get_my_unread_notification_count() from public, anon, authenticated;
revoke all on function public.set_room_muted(text, text, boolean) from public, anon, authenticated;
revoke all on function public.get_my_muted_rooms(text) from public, anon, authenticated;
revoke all on function public.get_my_room_activity(text) from public, anon, authenticated;
revoke all on function public.save_post(text, uuid) from public, anon, authenticated;
revoke all on function public.unsave_post(text, uuid) from public, anon, authenticated;
revoke all on function public.get_my_saved_post_ids(text) from public, anon, authenticated;
revoke all on function public.get_my_saved_posts() from public, anon, authenticated;
revoke all on function public.edit_post(text, uuid, text) from public, anon, authenticated;
revoke all on function public.edit_reply(text, uuid, text) from public, anon, authenticated;
revoke all on function public.get_edit_times(text, uuid[]) from public, anon, authenticated;
revoke all on function public.get_post_replies_v2(text, uuid) from public, anon, authenticated;

grant execute on function public.get_my_notification_prefs() to authenticated;
grant execute on function public.set_my_notification_prefs(boolean, boolean, boolean, boolean, boolean) to authenticated;
grant execute on function public.get_my_notifications(integer) to authenticated;
grant execute on function public.get_my_unread_notification_count() to authenticated;
grant execute on function public.set_room_muted(text, text, boolean) to authenticated;
grant execute on function public.get_my_muted_rooms(text) to authenticated;
grant execute on function public.get_my_room_activity(text) to authenticated;
grant execute on function public.save_post(text, uuid) to authenticated;
grant execute on function public.unsave_post(text, uuid) to authenticated;
grant execute on function public.get_my_saved_post_ids(text) to authenticated;
grant execute on function public.get_my_saved_posts() to authenticated;
grant execute on function public.edit_post(text, uuid, text) to authenticated;
grant execute on function public.edit_reply(text, uuid, text) to authenticated;
grant execute on function public.get_edit_times(text, uuid[]) to authenticated;
grant execute on function public.get_post_replies_v2(text, uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
