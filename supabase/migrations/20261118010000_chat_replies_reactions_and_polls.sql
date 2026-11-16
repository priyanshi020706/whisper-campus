-- Phase 2: chat replies, reactions and polls.
--
--  * Reply to a message: room_messages.reply_to plus send_chat_message_with_reply,
--    which wraps the existing send functions so every existing rule (blocks,
--    sessions, rate limits) still applies.
--  * Reactions: one emoji per user per message. Only counts are returned, never
--    who reacted, so anonymity is kept.
--  * Polls: attached to a post, an official post or a chat message. Votes are
--    anonymous; results are counts.
--  * get_chat_message_extras returns replies, reactions and polls for a batch of
--    messages in one call. Live changes are announced on the room's existing
--    private channel (events reaction_changed and poll_changed).
begin;

------------------------------------------------------------------------------
-- Reply to a message
------------------------------------------------------------------------------
alter table public.room_messages
  add column if not exists reply_to uuid references public.room_messages(id) on delete set null;

create or replace function public.room_chat_topic(p_room_id text, p_mode text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_room_id in ('general', 'official-live') then 'room:' || p_room_id
    else 'room:' || p_mode || ':' || p_room_id
  end;
$$;

create or replace function public.send_chat_message_with_reply(
  p_room_id text,
  p_mode text,
  p_content text,
  p_reply_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then
    raise exception 'Sign in to send a message' using errcode = '42501';
  end if;

  if p_reply_to is not null and not exists (
    select 1 from public.room_messages q
    where q.id = p_reply_to and q.room_id = p_room_id and q.room_mode = p_mode
  ) then
    raise exception 'The message you are replying to is no longer available.';
  end if;

  -- The existing senders enforce access, blocks, sessions and length.
  if p_room_id in ('general', 'official-live') then
    new_id := public.send_campus_live_message(p_room_id, p_content);
  else
    new_id := public.send_room_chat_message(p_room_id, p_mode, p_content);
  end if;

  if p_reply_to is not null then
    update public.room_messages
    set reply_to = p_reply_to
    where id = new_id and sender_id = uid;
  end if;
  return new_id;
end;
$$;

------------------------------------------------------------------------------
-- Reactions
------------------------------------------------------------------------------
create table if not exists public.message_reactions (
  message_id uuid not null references public.room_messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null check (emoji in ('👍', '❤️', '😂', '😮', '😢', '🙏')),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
create index if not exists message_reactions_message_idx
  on public.message_reactions (message_id);
alter table public.message_reactions enable row level security;
revoke all on table public.message_reactions from public, anon, authenticated;
grant all on table public.message_reactions to service_role;

-- Pass an emoji to react or change a reaction; pass the same emoji again, or
-- null, to remove it.
create or replace function public.react_to_message(p_message_id uuid, p_emoji text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  msg_room text;
  msg_mode text;
  existing text;
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  select m.room_id, m.room_mode into msg_room, msg_mode
  from public.room_messages m where m.id = p_message_id;
  if msg_room is null or not public.can_use_room_chat(msg_room, msg_mode, uid) then
    raise exception 'You cannot react to this message' using errcode = '42501';
  end if;
  if public.is_room_user_blocked(msg_room, msg_mode) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if p_emoji is not null and p_emoji not in ('👍', '❤️', '😂', '😮', '😢', '🙏') then
    raise exception 'That reaction is not available.';
  end if;

  select r.emoji into existing
  from public.message_reactions r
  where r.message_id = p_message_id and r.user_id = uid;

  if p_emoji is null or p_emoji = existing then
    delete from public.message_reactions r
    where r.message_id = p_message_id and r.user_id = uid;
  else
    insert into public.message_reactions (message_id, user_id, emoji)
    values (p_message_id, uid, p_emoji)
    on conflict (message_id, user_id) do update
      set emoji = excluded.emoji, created_at = now();
  end if;
end;
$$;

create or replace function public.announce_reaction_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_id uuid := coalesce(new.message_id, old.message_id);
  msg_room text;
  msg_mode text;
begin
  select m.room_id, m.room_mode into msg_room, msg_mode
  from public.room_messages m where m.id = target_id;
  if msg_room is null then
    return null;
  end if;
  begin
    perform realtime.send(
      jsonb_build_object('message_id', target_id),
      'reaction_changed',
      public.room_chat_topic(msg_room, msg_mode),
      true
    );
  exception when others then
    null; -- never block a reaction because the live signal failed
  end;
  return null;
end;
$$;

drop trigger if exists live_signal_message_reactions on public.message_reactions;
create trigger live_signal_message_reactions
  after insert or update or delete on public.message_reactions
  for each row execute function public.announce_reaction_change();

------------------------------------------------------------------------------
-- Polls
------------------------------------------------------------------------------
create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  target_kind text not null check (target_kind in ('post', 'official_post', 'chat')),
  target_id uuid not null,
  question text not null check (char_length(btrim(question)) between 1 and 200),
  allows_multiple boolean not null default false,
  closes_at timestamptz,
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (target_kind, target_id)
);

create table if not exists public.poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id) on delete cascade,
  position smallint not null,
  label text not null check (char_length(btrim(label)) between 1 and 80),
  unique (poll_id, position)
);

create table if not exists public.poll_votes (
  poll_id uuid not null references public.polls(id) on delete cascade,
  option_id uuid not null references public.poll_options(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (option_id, user_id)
);
create index if not exists poll_votes_poll_user_idx on public.poll_votes (poll_id, user_id);

alter table public.polls enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes enable row level security;
revoke all on table public.polls, public.poll_options, public.poll_votes from public, anon, authenticated;
grant all on table public.polls, public.poll_options, public.poll_votes to service_role;

-- Polls disappear with the post or message they belong to.
create or replace function public.cleanup_polls()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.polls p where p.target_id = old.id and p.target_kind = tg_argv[0];
  return old;
end;
$$;
drop trigger if exists cleanup_polls on public.posts;
create trigger cleanup_polls after delete on public.posts
  for each row execute function public.cleanup_polls('post');
drop trigger if exists cleanup_polls on public.official_posts;
create trigger cleanup_polls after delete on public.official_posts
  for each row execute function public.cleanup_polls('official_post');
drop trigger if exists cleanup_polls on public.room_messages;
create trigger cleanup_polls after delete on public.room_messages
  for each row execute function public.cleanup_polls('chat');

-- May this user see (and so vote in) the poll's target?
create or replace function public.can_access_poll_target(p_kind text, p_target_id uuid, p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  msg_room text;
  msg_mode text;
begin
  if p_uid is null then
    return false;
  end if;
  if p_kind = 'post' then
    return public.can_view_post_kind('post', p_uid) and exists (
      select 1 from public.posts p where p.id = p_target_id and p.approval_status = 'approved');
  elsif p_kind = 'official_post' then
    return public.can_view_post_kind('official_post', p_uid) and exists (
      select 1 from public.official_posts p where p.id = p_target_id and p.approval_status = 'approved');
  elsif p_kind = 'chat' then
    select m.room_id, m.room_mode into msg_room, msg_mode
    from public.room_messages m where m.id = p_target_id;
    return msg_room is not null and public.can_use_room_chat(msg_room, msg_mode, p_uid);
  end if;
  return false;
end;
$$;

-- Checks the question and options, returning cleaned options.
create or replace function public.clean_poll_input(p_question text, p_options text[], p_closes_at timestamptz)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  cleaned text[] := '{}';
  seen text[] := '{}';
  item text;
begin
  if char_length(btrim(coalesce(p_question, ''))) not between 1 and 200 then
    raise exception 'The poll question must be 1 to 200 characters.';
  end if;
  foreach item in array coalesce(p_options, '{}') loop
    item := btrim(coalesce(item, ''));
    if item = '' then
      continue;
    end if;
    if char_length(item) > 80 then
      raise exception 'Each choice can be at most 80 characters.';
    end if;
    if lower(item) = any (seen) then
      raise exception 'Each choice must be different.';
    end if;
    seen := seen || lower(item);
    cleaned := cleaned || item;
  end loop;
  if coalesce(array_length(cleaned, 1), 0) not between 2 and 6 then
    raise exception 'A poll needs 2 to 6 choices.';
  end if;
  if p_closes_at is not null and (p_closes_at <= now() or p_closes_at > now() + interval '30 days') then
    raise exception 'Choose a closing time within the next 30 days.';
  end if;
  return cleaned;
end;
$$;

create or replace function public.insert_poll(
  p_kind text, p_target_id uuid, p_question text, p_options text[],
  p_multiple boolean, p_closes_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
  cleaned text[] := public.clean_poll_input(p_question, p_options, p_closes_at);
  i integer;
begin
  insert into public.polls (target_kind, target_id, question, allows_multiple, closes_at)
  values (p_kind, p_target_id, btrim(p_question), coalesce(p_multiple, false), p_closes_at)
  returning id into new_id;
  for i in 1 .. array_length(cleaned, 1) loop
    insert into public.poll_options (poll_id, position, label)
    values (new_id, i, cleaned[i]);
  end loop;
  return new_id;
end;
$$;

-- Add a poll to a post just created by the caller (within 15 minutes).
create or replace function public.create_post_poll(
  p_kind text, p_post_id uuid, p_question text, p_options text[],
  p_multiple boolean default false, p_closes_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  owned boolean;
begin
  if uid is null or not public.can_view_post_kind(p_kind, uid) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_kind = 'post' then
    select exists (select 1 from public.posts p
      where p.id = p_post_id and p.author_id = uid and p.created_at > now() - interval '15 minutes')
      into owned;
  elsif p_kind = 'official_post' then
    select exists (select 1 from public.official_posts p
      where p.id = p_post_id and p.author_id = uid and p.created_at > now() - interval '15 minutes')
      into owned;
  else
    raise exception 'Unknown post type';
  end if;
  if not owned then
    raise exception 'You can only add a poll to your own new post.';
  end if;
  return public.insert_poll(p_kind, p_post_id, p_question, p_options, p_multiple, p_closes_at);
end;
$$;

-- Send a chat message that carries a poll. Returns the message id.
create or replace function public.create_chat_poll(
  p_room_id text, p_mode text, p_question text, p_options text[],
  p_multiple boolean default false, p_closes_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  message uuid;
begin
  perform public.clean_poll_input(p_question, p_options, p_closes_at); -- fail early
  message := public.send_chat_message_with_reply(
    p_room_id, p_mode, '📊 ' || left(btrim(p_question), 190), null);
  perform public.insert_poll('chat', message, p_question, p_options, p_multiple, p_closes_at);
  return message;
end;
$$;

-- Replace my vote(s) in a poll. An empty list removes my votes.
create or replace function public.vote_poll(p_poll_id uuid, p_option_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  poll_row public.polls%rowtype;
  chosen uuid[];
  valid_count integer;
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  select * into poll_row from public.polls p where p.id = p_poll_id;
  if not found or not public.can_access_poll_target(poll_row.target_kind, poll_row.target_id, uid) then
    raise exception 'That poll is not available.' using errcode = '42501';
  end if;
  if poll_row.closes_at is not null and poll_row.closes_at <= now() then
    raise exception 'This poll has closed.';
  end if;
  if poll_row.target_kind = 'chat' then
    perform 1 from public.room_messages m
    where m.id = poll_row.target_id and not public.is_room_user_blocked(m.room_id, m.room_mode);
    if not found then
      raise exception 'You are blocked from this room' using errcode = '42501';
    end if;
  end if;

  select coalesce(array_agg(distinct x), '{}') into chosen
  from unnest(coalesce(p_option_ids, '{}')) as x;
  if not poll_row.allows_multiple and array_length(chosen, 1) > 1 then
    raise exception 'Choose only one answer.';
  end if;
  select count(*) into valid_count
  from public.poll_options o where o.poll_id = p_poll_id and o.id = any (chosen);
  if valid_count <> coalesce(array_length(chosen, 1), 0) then
    raise exception 'That choice does not belong to this poll.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_poll_id::text || uid::text, 0));
  delete from public.poll_votes v where v.poll_id = p_poll_id and v.user_id = uid;
  insert into public.poll_votes (poll_id, option_id, user_id)
  select p_poll_id, o, uid from unnest(chosen) as o;
end;
$$;

-- Internal: polls for targets, as json. Never exposes who voted.
create or replace function public.build_polls_json(p_kind text, p_target_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'poll_id', p.id,
    'target_id', p.target_id,
    'question', p.question,
    'allows_multiple', p.allows_multiple,
    'closes_at', p.closes_at,
    'total_voters', (select count(distinct v.user_id) from public.poll_votes v where v.poll_id = p.id),
    'options', (
      select jsonb_agg(jsonb_build_object(
        'option_id', o.id,
        'label', o.label,
        'votes', (select count(*) from public.poll_votes v where v.option_id = o.id),
        'mine', exists (select 1 from public.poll_votes v where v.option_id = o.id and v.user_id = auth.uid())
      ) order by o.position)
      from public.poll_options o where o.poll_id = p.id)
  )), '[]'::jsonb)
  from public.polls p
  where p.target_kind = p_kind and p.target_id = any (p_target_ids);
$$;

-- Polls attached to feed posts. kind: post or official_post.
create or replace function public.get_polls(p_kind text, p_target_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  visible uuid[];
begin
  if uid is null or p_kind not in ('post', 'official_post')
     or not public.can_view_post_kind(p_kind, uid) then
    return '[]'::jsonb;
  end if;
  if p_kind = 'post' then
    select coalesce(array_agg(p.id), '{}') into visible
    from public.posts p where p.id = any (p_target_ids) and p.approval_status = 'approved';
  else
    select coalesce(array_agg(p.id), '{}') into visible
    from public.official_posts p where p.id = any (p_target_ids) and p.approval_status = 'approved';
  end if;
  return public.build_polls_json(p_kind, visible);
end;
$$;

-- Everything extra about a batch of chat messages in one call.
create or replace function public.get_chat_message_extras(p_message_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  readable uuid[];
begin
  if uid is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if coalesce(array_length(p_message_ids, 1), 0) = 0 then
    return jsonb_build_object('links', '[]'::jsonb, 'reactions', '[]'::jsonb, 'polls', '[]'::jsonb);
  end if;
  if array_length(p_message_ids, 1) > 300 then
    raise exception 'Too many messages at once.';
  end if;

  select coalesce(array_agg(m.id), '{}') into readable
  from public.room_messages m
  where m.id = any (p_message_ids) and public.can_use_room_chat(m.room_id, m.room_mode, uid);

  return jsonb_build_object(
    'links', coalesce((
      select jsonb_agg(jsonb_build_object(
        'message_id', m.id, 'reply_to', m.reply_to, 'quoted_content', left(q.content, 160)))
      from public.room_messages m
      left join public.room_messages q on q.id = m.reply_to
      where m.id = any (readable) and m.reply_to is not null), '[]'::jsonb),
    'reactions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'message_id', r.message_id, 'emoji', r.emoji, 'count', r.cnt, 'mine', r.mine))
      from (
        select x.message_id, x.emoji, count(*)::integer as cnt, bool_or(x.user_id = uid) as mine
        from public.message_reactions x
        where x.message_id = any (readable)
        group by x.message_id, x.emoji) r), '[]'::jsonb),
    'polls', public.build_polls_json('chat', readable)
  );
end;
$$;

-- Live signals for votes.
create or replace function public.announce_poll_vote()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  poll_row public.polls%rowtype;
  msg_room text;
  msg_mode text;
  post_room text;
  poll_ref uuid := coalesce(new.poll_id, old.poll_id);
begin
  select * into poll_row from public.polls p where p.id = poll_ref;
  if not found then
    return null;
  end if;
  begin
    if poll_row.target_kind = 'chat' then
      select m.room_id, m.room_mode into msg_room, msg_mode
      from public.room_messages m where m.id = poll_row.target_id;
      if msg_room is not null then
        perform realtime.send(
          jsonb_build_object('poll_id', poll_ref, 'message_id', poll_row.target_id),
          'poll_changed', public.room_chat_topic(msg_room, msg_mode), true);
      end if;
    elsif poll_row.target_kind = 'post' then
      select p.room_id into post_room from public.posts p where p.id = poll_row.target_id;
      perform realtime.send(
        jsonb_build_object('kind', 'poll', 'op', 'update', 'post_id', poll_row.target_id, 'room_id', post_room),
        'activity', 'feed:unofficial', true);
    else
      select p.room_id into post_room from public.official_posts p where p.id = poll_row.target_id;
      perform realtime.send(
        jsonb_build_object('kind', 'poll', 'op', 'update', 'post_id', poll_row.target_id, 'room_id', post_room),
        'activity', 'feed:official', true);
    end if;
  exception when others then
    null;
  end;
  return null;
end;
$$;

drop trigger if exists live_signal_poll_votes on public.poll_votes;
create trigger live_signal_poll_votes
  after insert or delete on public.poll_votes
  for each row execute function public.announce_poll_vote();

-- A new poll on a post shows up in everyone's feed.
create or replace function public.announce_new_post_poll()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  post_room text;
begin
  if new.target_kind = 'chat' then
    return null;
  end if;
  begin
    if new.target_kind = 'post' then
      select p.room_id into post_room from public.posts p where p.id = new.target_id;
      perform realtime.send(
        jsonb_build_object('kind', 'poll', 'op', 'insert', 'post_id', new.target_id, 'room_id', post_room),
        'activity', 'feed:unofficial', true);
    else
      select p.room_id into post_room from public.official_posts p where p.id = new.target_id;
      perform realtime.send(
        jsonb_build_object('kind', 'poll', 'op', 'insert', 'post_id', new.target_id, 'room_id', post_room),
        'activity', 'feed:official', true);
    end if;
  exception when others then
    null;
  end;
  return null;
end;
$$;
drop trigger if exists live_signal_new_poll on public.polls;
create trigger live_signal_new_poll after insert on public.polls
  for each row execute function public.announce_new_post_poll();

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------
revoke all on function public.room_chat_topic(text, text) from public, anon, authenticated;
revoke all on function public.announce_reaction_change() from public, anon, authenticated;
revoke all on function public.announce_poll_vote() from public, anon, authenticated;
revoke all on function public.announce_new_post_poll() from public, anon, authenticated;
revoke all on function public.cleanup_polls() from public, anon, authenticated;
revoke all on function public.can_access_poll_target(text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.clean_poll_input(text, text[], timestamptz) from public, anon, authenticated;
revoke all on function public.insert_poll(text, uuid, text, text[], boolean, timestamptz) from public, anon, authenticated;
revoke all on function public.build_polls_json(text, uuid[]) from public, anon, authenticated;

revoke all on function public.send_chat_message_with_reply(text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.react_to_message(uuid, text) from public, anon, authenticated;
revoke all on function public.create_post_poll(text, uuid, text, text[], boolean, timestamptz) from public, anon, authenticated;
revoke all on function public.create_chat_poll(text, text, text, text[], boolean, timestamptz) from public, anon, authenticated;
revoke all on function public.vote_poll(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.get_polls(text, uuid[]) from public, anon, authenticated;
revoke all on function public.get_chat_message_extras(uuid[]) from public, anon, authenticated;

grant execute on function public.send_chat_message_with_reply(text, text, text, uuid) to authenticated;
grant execute on function public.react_to_message(uuid, text) to authenticated;
grant execute on function public.create_post_poll(text, uuid, text, text[], boolean, timestamptz) to authenticated;
grant execute on function public.create_chat_poll(text, text, text, text[], boolean, timestamptz) to authenticated;
grant execute on function public.vote_poll(uuid, uuid[]) to authenticated;
grant execute on function public.get_polls(text, uuid[]) to authenticated;
grant execute on function public.get_chat_message_extras(uuid[]) to authenticated;

notify pgrst, 'reload schema';
commit;
