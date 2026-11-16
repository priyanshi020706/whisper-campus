begin;

-- These legacy feed RPCs predate per-room post approval. Current Flutter uses
-- the approved-only v3 feeds; disable the old public projections so a caller
-- cannot fetch a post while it is still pending moderator review.
revoke all on function public.get_room_feed_with_media(text)
  from public, anon, authenticated;
revoke all on function public.get_room_feed_with_media_v2(text)
  from public, anon, authenticated;
revoke all on function public.get_post_replies(uuid)
  from public, anon, authenticated;
revoke all on function public.get_official_posts(text, integer)
  from public, anon, authenticated;
revoke all on function public.get_official_posts_with_activity(text, integer)
  from public, anon, authenticated;

-- Official and Unofficial can share a room_id. A block must therefore be
-- scoped to the campus mode, just like room sessions and moderator roles.
alter table public.room_blocks
  add column if not exists room_mode text not null default 'official';

update public.room_blocks as block
set room_mode = case
  when block.room_id = 'general' then 'unofficial'
  when block.room_id = 'official-live' then 'official'
  else coalesce(
    (
      select session.room_mode
      from public.room_sessions as session
      where session.room_id = block.room_id
        and session.user_id = block.user_id
        and session.joined_at <= block.created_at
      order by session.joined_at desc
      limit 1
    ),
    'official'
  )
end;

alter table public.room_blocks
  drop constraint if exists room_blocks_room_mode_check;
alter table public.room_blocks
  add constraint room_blocks_room_mode_check
  check (room_mode in ('official', 'unofficial'));
alter table public.room_blocks
  drop constraint if exists room_blocks_pkey;
alter table public.room_blocks
  add constraint room_blocks_pkey primary key (room_id, room_mode, user_id);

create or replace function public.is_room_user_blocked(
  p_room_id text,
  p_mode text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.room_blocks as block
    where block.room_id = p_room_id
      and block.room_mode = p_mode
      and block.user_id = auth.uid()
      and block.ends_at > now()
  );
$$;

create or replace function public.get_my_room_block(p_room_id text, p_mode text)
returns table(reason text, ends_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select block.reason, block.ends_at
  from public.room_blocks as block
  where block.room_id = p_room_id
    and block.room_mode = p_mode
    and block.user_id = auth.uid()
    and block.ends_at > now();
$$;

-- Preserve the old RPC shape for already-open app versions. New versions pass
-- p_mode explicitly so a department-room ban cannot cross campus modes.
create or replace function public.get_my_room_block(p_room_id text)
returns table(reason text, ends_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.get_my_room_block(
    p_room_id,
    case when p_room_id = 'official-live' then 'official' else 'unofficial' end
  );
$$;

create or replace function public.get_or_create_room_moderator_thread(
  p_room_id text,
  p_mode text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  thread_id uuid;
begin
  if auth.uid() is null or p_mode not in ('official', 'unofficial')
      or not public.can_use_room_chat(p_room_id, p_mode, auth.uid()) then
    raise exception 'You cannot contact moderators for this room' using errcode = '42501';
  end if;
  if p_mode = 'official' and not public.is_eligible_official_user(auth.uid()) then
    raise exception 'Verified Official MITS account required' using errcode = '42501';
  end if;
  if public.is_room_user_blocked(p_room_id, p_mode) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_moderators as moderator
    where moderator.room_id = p_room_id
      and moderator.room_mode = p_mode
      and moderator.active
      and moderator.starts_at <= now()
      and (moderator.ends_at is null or moderator.ends_at > now())
  ) then
    raise exception 'This room has no active moderator yet';
  end if;

  insert into public.room_moderator_threads(room_id, room_mode, student_id)
  values (p_room_id, p_mode, auth.uid())
  on conflict (room_id, room_mode, student_id) do nothing;
  select thread.id into thread_id
  from public.room_moderator_threads as thread
  where thread.room_id = p_room_id
    and thread.room_mode = p_mode
    and thread.student_id = auth.uid();
  return thread_id;
end;
$$;

create or replace function public.block_room_user(
  p_room_id text,
  p_user_id uuid,
  p_reason text,
  p_mode text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  expires_at timestamptz := now() + interval '3 days';
  clean_reason text := left(btrim(coalesce(p_reason, '')), 500);
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown campus mode';
  end if;
  if not (
    public.is_super_admin(uid)
    or public.is_active_room_moderator(p_room_id, p_mode, uid)
    or (p_room_id = 'official-live' and p_mode = 'official' and public.is_faculty(uid))
  ) then
    raise exception 'Room moderator access required' using errcode = '42501';
  end if;
  if p_user_id = uid
      or public.is_super_admin(p_user_id)
      or public.is_faculty(p_user_id)
      or public.is_active_room_moderator(p_room_id, p_mode, p_user_id) then
    raise exception 'Cannot block faculty, Super Admins, or another room moderator';
  end if;
  if not exists (
    select 1 from public.profiles as profile
    where profile.id = p_user_id and profile.role = 'student'
  ) then
    raise exception 'Only students can be blocked';
  end if;
  if char_length(clean_reason) = 0 then
    raise exception 'A warning reason is required';
  end if;

  insert into public.room_blocks(room_id, room_mode, user_id, blocked_by, reason, ends_at)
  values (p_room_id, p_mode, p_user_id, uid, clean_reason, expires_at)
  on conflict (room_id, room_mode, user_id) do update
    set blocked_by = excluded.blocked_by,
        reason = excluded.reason,
        ends_at = excluded.ends_at,
        created_at = now();

  update public.room_sessions
  set left_at = now()
  where room_id = p_room_id and room_mode = p_mode
    and user_id = p_user_id and left_at is null;

  return expires_at;
end;
$$;

-- Compatibility overload for clients predating mode-aware blocking.
create or replace function public.block_room_user(
  p_room_id text,
  p_user_id uuid,
  p_reason text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  mode_value text;
begin
  select session.room_mode into mode_value
  from public.room_sessions as session
  where session.room_id = p_room_id
    and session.user_id = auth.uid()
    and session.left_at is null
  order by session.joined_at desc
  limit 1;
  if mode_value is null then
    mode_value := case when p_room_id = 'official-live' then 'official' else 'unofficial' end;
  end if;
  return public.block_room_user(p_room_id, p_user_id, p_reason, mode_value);
end;
$$;

create or replace function public.join_room_chat(p_room_id text, p_mode text)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  joined timestamptz;
begin
  if uid is null then
    raise exception 'Sign in to join this chat' using errcode = '42501';
  end if;
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You do not have access to this room chat' using errcode = '42501';
  end if;
  if public.is_room_user_blocked(p_room_id, p_mode) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;

  update public.room_sessions
  set left_at = now()
  where room_id = p_room_id and room_mode = p_mode
    and user_id = uid and left_at is null;

  insert into public.room_sessions(room_id, room_mode, user_id)
  values (p_room_id, p_mode, uid)
  returning joined_at into joined;

  insert into public.room_chat_reads(room_id, room_mode, user_id, last_read_at)
  values (p_room_id, p_mode, uid, now())
  on conflict (room_id, room_mode, user_id)
  do update set last_read_at = excluded.last_read_at;

  return joined;
end;
$$;

create or replace function public.send_room_chat_message(
  p_room_id text,
  p_mode text,
  p_content text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  message_id uuid;
  clean text := btrim(coalesce(p_content, ''));
begin
  if uid is null then
    raise exception 'Sign in to send a message' using errcode = '42501';
  end if;
  if not public.can_use_room_chat(p_room_id, p_mode, uid)
      or p_room_id in ('general', 'official-live') then
    raise exception 'You cannot send messages in this room' using errcode = '42501';
  end if;
  if char_length(clean) not between 1 and 2000 then
    raise exception 'Messages must contain 1 to 2000 characters';
  end if;
  if public.is_room_user_blocked(p_room_id, p_mode) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_sessions as session
    where session.room_id = p_room_id and session.room_mode = p_mode
      and session.user_id = uid and session.left_at is null
  ) then
    raise exception 'Join this room chat before sending' using errcode = '42501';
  end if;

  insert into public.room_messages(room_id, room_mode, sender_id, content)
  values (p_room_id, p_mode, uid, clean)
  returning id into message_id;
  return message_id;
end;
$$;

create or replace function public.send_campus_live_message(p_room_id text, p_content text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  mode_value text;
  message_id uuid;
  clean text := btrim(coalesce(p_content, ''));
begin
  if uid is null then
    raise exception 'Sign in to send a message' using errcode = '42501';
  end if;
  if p_room_id not in ('general', 'official-live') then
    raise exception 'This endpoint is only for Campus Live chats';
  end if;
  mode_value := case when p_room_id = 'official-live' then 'official' else 'unofficial' end;
  if not public.can_use_room_chat(p_room_id, mode_value, uid) then
    raise exception 'You do not have access to this Campus Live chat' using errcode = '42501';
  end if;
  if char_length(clean) not between 1 and 2000 then
    raise exception 'Messages must contain 1 to 2000 characters';
  end if;
  if public.is_room_user_blocked(p_room_id, mode_value) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if p_room_id = 'official-live' and not exists (
    select 1 from public.room_sessions as session
    where session.room_id = p_room_id and session.room_mode = mode_value
      and session.user_id = uid and session.left_at is null
  ) then
    raise exception 'Join Official Campus Live before sending' using errcode = '42501';
  end if;

  insert into public.room_messages(room_id, room_mode, sender_id, content)
  values (p_room_id, mode_value, uid, clean)
  returning id into message_id;
  return message_id;
end;
$$;

create or replace function public.get_room_chat_messages(
  p_room_id text,
  p_mode text,
  p_limit integer default 100
)
returns table(
  message_id uuid,
  room_id text,
  author_id uuid,
  author_username text,
  content text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.can_use_room_chat(p_room_id, p_mode, auth.uid()) then
    raise exception 'You cannot read this room chat' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_sessions as session
    where session.room_id = p_room_id and session.room_mode = p_mode
      and session.user_id = auth.uid() and session.left_at is null
  ) then
    raise exception 'Join the room chat first' using errcode = '42501';
  end if;
  if public.is_room_user_blocked(p_room_id, p_mode) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;

  return query
  select message.id,
    message.room_id,
    case when p_mode = 'official' then message.sender_id else null::uuid end,
    (
      case when p_mode = 'official' then
        coalesce(nullif(btrim(identity.real_name), ''), 'Student') || ' · ' ||
        case when profile.role in ('faculty', 'super_admin') then
          'Faculty' || case when profile.branch_code is null then '' else ' · ' || profile.branch_code end
        else coalesce(profile.branch_code, '') || ' · ' ||
          case when profile.academic_year > 4 then 'Alumni'
               when profile.academic_year = 1 then '1st'
               when profile.academic_year = 2 then '2nd'
               when profile.academic_year = 3 then '3rd'
               when profile.academic_year = 4 then '4th'
               else 'Year unavailable' end
        end
      else coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')
      end || case when public.is_active_room_moderator(p_room_id, p_mode, message.sender_id)
        then ' (Moderator)' else '' end
    )::text,
    message.content,
    message.created_at
  from (
    select message_row.id, message_row.room_id, message_row.sender_id,
      message_row.content, message_row.created_at
    from public.room_messages as message_row
    where message_row.room_id = p_room_id and message_row.room_mode = p_mode
      and message_row.room_id not in ('general', 'official-live')
      and message_row.created_at >= now() - interval '7 days'
    order by message_row.created_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 200))
  ) as message
  left join public.profiles as profile on profile.id = message.sender_id
  left join public.identity_records as identity on identity.user_id = message.sender_id
  order by message.created_at asc;
end;
$$;

create or replace function public.can_receive_room_chat_broadcast(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  mode_value text := split_part(p_topic, ':', 2);
  room_value text := split_part(p_topic, ':', 3);
begin
  if uid is null then return false; end if;

  if p_topic = 'room:general' then
    return public.can_use_room_chat('general', 'unofficial', uid)
      and not public.is_room_user_blocked('general', 'unofficial');
  end if;
  if p_topic = 'room:official-live' then
    return public.can_use_room_chat('official-live', 'official', uid)
      and exists (
        select 1 from public.room_sessions as session
        where session.room_id = 'official-live' and session.room_mode = 'official'
          and session.user_id = uid and session.left_at is null
      )
      and not public.is_room_user_blocked('official-live', 'official');
  end if;
  if split_part(p_topic, ':', 1) <> 'room'
      or mode_value not in ('official', 'unofficial') or room_value = '' then
    return false;
  end if;

  return public.can_use_room_chat(room_value, mode_value, uid)
    and exists (
      select 1 from public.room_sessions as session
      where session.room_id = room_value and session.room_mode = mode_value
        and session.user_id = uid and session.left_at is null
    )
    and not public.is_room_user_blocked(room_value, mode_value);
end;
$$;

create or replace function public.get_room_messages(p_room_id text, p_limit integer default 50)
returns table(
  message_id uuid,
  room_id text,
  author_id uuid,
  author_username text,
  content text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  mode_value text := case when p_room_id = 'official-live' then 'official' else 'unofficial' end;
  joined timestamptz;
begin
  if p_room_id not in ('general', 'official-live') then
    raise exception 'Use the room conversation endpoint for this room';
  end if;
  if auth.uid() is null or not exists (
    select 1 from public.profiles as profile
    where profile.id = auth.uid() and profile.role in ('student', 'faculty', 'super_admin')
  ) then
    raise exception 'MITS account required' using errcode = '42501';
  end if;
  if public.is_room_user_blocked(p_room_id, mode_value) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if p_room_id = 'official-live' then
    select session.joined_at into joined
    from public.room_sessions as session
    where session.room_id = p_room_id and session.room_mode = mode_value
      and session.user_id = auth.uid() and session.left_at is null
    order by session.joined_at desc limit 1;
    if joined is null then
      raise exception 'Join room to read messages' using errcode = '42501';
    end if;
  end if;

  return query
  select message.id,
    message.room_id,
    case when mode_value = 'official' then message.sender_id else null::uuid end,
    (
      case when mode_value = 'official' then
        coalesce(nullif(btrim(identity.real_name), ''), 'Student') || ' · ' ||
        case when profile.role in ('faculty', 'super_admin') then
          'Faculty' || case when profile.branch_code is null then '' else ' · ' || profile.branch_code end
        else coalesce(profile.branch_code, '') || ' · ' ||
          case when profile.academic_year > 4 then 'Alumni'
               when profile.academic_year = 1 then '1st'
               when profile.academic_year = 2 then '2nd'
               when profile.academic_year = 3 then '3rd'
               when profile.academic_year = 4 then '4th'
               else 'Year unavailable' end
        end
      else coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')
      end || case when public.is_active_room_moderator(p_room_id, mode_value, message.sender_id)
        then ' (Moderator)' else '' end
    )::text,
    message.content,
    message.created_at
  from (
    select message_row.id, message_row.room_id, message_row.sender_id,
      message_row.content, message_row.created_at
    from public.room_messages as message_row
    where message_row.room_id = p_room_id and message_row.room_mode = mode_value
      and (p_room_id <> 'official-live' or (message_row.created_at >= joined and message_row.created_at <= now()))
    order by message_row.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) as message
  left join public.profiles as profile on profile.id = message.sender_id
  left join public.identity_records as identity on identity.user_id = message.sender_id
  order by message.created_at asc;
end;
$$;

drop policy if exists "Users can send messages as themselves" on public.room_messages;
create policy "Users can send messages as themselves"
  on public.room_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.can_use_room_chat(room_id, room_mode, auth.uid())
    and not public.is_room_user_blocked(room_id, room_mode)
    and (
      (room_id = 'general' and room_mode = 'unofficial')
      or (room_id = 'official-live' and room_mode = 'official'
        and exists (
          select 1 from public.room_sessions as session
          where session.room_id = room_messages.room_id
            and session.room_mode = room_messages.room_mode
            and session.user_id = auth.uid() and session.left_at is null
        ))
      or (room_id not in ('general', 'official-live')
        and exists (
          select 1 from public.room_sessions as session
          where session.room_id = room_messages.room_id
            and session.room_mode = room_messages.room_mode
            and session.user_id = auth.uid() and session.left_at is null
        ))
    )
  );

revoke all on function public.is_room_user_blocked(text, text),
  public.get_my_room_block(text, text), public.get_my_room_block(text),
  public.block_room_user(text, uuid, text, text), public.block_room_user(text, uuid, text),
  public.get_or_create_room_moderator_thread(text, text),
  public.join_room_chat(text, text), public.send_room_chat_message(text, text, text),
  public.send_campus_live_message(text, text), public.get_room_chat_messages(text, text, integer),
  public.can_receive_room_chat_broadcast(text), public.get_room_messages(text, integer)
  from public, anon, authenticated;

grant execute on function public.get_my_room_block(text, text), public.get_my_room_block(text),
  public.block_room_user(text, uuid, text, text), public.block_room_user(text, uuid, text),
  public.get_or_create_room_moderator_thread(text, text),
  public.join_room_chat(text, text), public.send_room_chat_message(text, text, text),
  public.send_campus_live_message(text, text), public.get_room_chat_messages(text, text, integer),
  public.get_room_messages(text, integer)
  to authenticated;
grant execute on function public.is_room_user_blocked(text, text)
  to authenticated;
grant execute on function public.can_receive_room_chat_broadcast(text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
