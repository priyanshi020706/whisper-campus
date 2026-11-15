begin;

-- Keep room membership and chat availability consistent in both campus modes.
-- Department rooms use the same room ID but are separated by room_mode.
create or replace function public.can_use_room_chat(
  p_room_id text,
  p_mode text,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user_id is not null
    and p_mode in ('official', 'unofficial')
    and (
      (p_mode = 'unofficial' and p_room_id = 'general')
      or exists (select 1 from public.rooms r where r.id = p_room_id)
    )
    and (
      (p_mode = 'official'
        and public.is_official_room(p_room_id)
        and exists (
          select 1 from public.profiles p
          where p.id = p_user_id and p.role in ('student', 'faculty', 'super_admin')
        ))
      or
      (p_mode = 'unofficial'
        and p_room_id <> 'official-live'
        and exists (
          select 1 from public.profiles p
          where p.id = p_user_id and p.role in ('student', 'faculty', 'super_admin')
        ))
    );
$$;

create or replace function public.join_room_chat(p_room_id text, p_mode text)
returns timestamptz
language plpgsql security definer set search_path = '' as $$
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
  if exists (
    select 1 from public.room_blocks b
    where b.room_id = p_room_id and b.user_id = uid and b.ends_at > now()
  ) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;

  update public.room_sessions
  set left_at = now()
  where room_id = p_room_id and room_mode = p_mode and user_id = uid and left_at is null;

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
language plpgsql security definer set search_path = '' as $$
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
  if exists (
    select 1 from public.room_blocks b
    where b.room_id = p_room_id and b.user_id = uid and b.ends_at > now()
  ) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_sessions s
    where s.room_id = p_room_id and s.room_mode = p_mode
      and s.user_id = uid and s.left_at is null
  ) then
    raise exception 'Join this room chat before sending' using errcode = '42501';
  end if;

  insert into public.room_messages(room_id, room_mode, sender_id, content)
  values (p_room_id, p_mode, uid, clean)
  returning id into message_id;
  return message_id;
end;
$$;

-- The always-on chats also use a checked server-side send endpoint. This avoids
-- relying on client table grants for posting from Flutter Web or installed PWAs.
create or replace function public.send_campus_live_message(p_room_id text, p_content text)
returns uuid
language plpgsql security definer set search_path = '' as $$
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
  if exists (
    select 1 from public.room_blocks b
    where b.room_id = p_room_id and b.user_id = uid and b.ends_at > now()
  ) then
    raise exception 'You are blocked from this room' using errcode = '42501';
  end if;
  if p_room_id = 'official-live' and not exists (
    select 1 from public.room_sessions s
    where s.room_id = p_room_id and s.room_mode = mode_value
      and s.user_id = uid and s.left_at is null
  ) then
    raise exception 'Join Official Campus Live before sending' using errcode = '42501';
  end if;

  insert into public.room_messages(room_id, room_mode, sender_id, content)
  values (p_room_id, mode_value, uid, clean)
  returning id into message_id;
  return message_id;
end;
$$;

-- Permit Super Admins to select Unofficial moderators for department rooms too.
create or replace function public.list_moderation_rooms(p_mode text)
returns table(room_id text, room_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown campus mode';
  end if;
  if not (public.is_super_admin(auth.uid())
      or (p_mode = 'official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator management access required' using errcode = '42501';
  end if;
  return query
  select r.id, r.name
  from public.rooms r
  where r.id <> 'official-live'
    and (p_mode = 'unofficial' or public.is_official_room(r.id))
  order by r.name;
end;
$$;

create or replace function public.assign_room_moderator(
  p_room_id text,
  p_student_id uuid,
  p_ends_at timestamptz default null,
  p_mode text default 'official'
)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown campus mode';
  end if;
  if not (public.is_super_admin(auth.uid())
      or (p_mode = 'official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator assignment access required' using errcode = '42501';
  end if;
  if not public.can_use_room_chat(p_room_id, p_mode, auth.uid()) then
    raise exception 'Choose a room on the selected campus side';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = p_student_id and p.role = 'student'
  ) then
    raise exception 'Only students can moderate';
  end if;
  if p_ends_at is not null and p_ends_at <= now() then
    raise exception 'End date must be in the future';
  end if;

  insert into public.room_moderators(room_id, room_mode, student_id, assigned_by, ends_at)
  values (p_room_id, p_mode, p_student_id, auth.uid(), p_ends_at)
  on conflict (room_id, room_mode, student_id)
  do update set assigned_by = excluded.assigned_by,
    starts_at = now(), ends_at = excluded.ends_at, active = true;

  insert into public.room_moderator_audit(room_id, room_mode, student_id, changed_by, action, ends_at)
  values (p_room_id, p_mode, p_student_id, auth.uid(), 'assigned', p_ends_at);
end;
$$;

-- Enrollment numbers are prefix searched as the admin types; names and roll
-- numbers still need three characters to avoid broad, noisy results.
create or replace function public.search_students(
  p_query text,
  p_branch_code text default null,
  p_mode text default 'official'
)
returns table(
  student_id uuid,
  student_name text,
  branch_code text,
  branch_name text,
  study_year int,
  enrollment_number text,
  roll_number text
)
language plpgsql stable security definer set search_path = '' as $$
declare
  q text := btrim(coalesce(p_query, ''));
begin
  if p_mode not in ('official', 'unofficial') then
    raise exception 'Unknown campus mode';
  end if;
  if not (public.is_super_admin(auth.uid())
      or (p_mode = 'official' and public.is_faculty(auth.uid()))) then
    raise exception 'You cannot search students for this campus mode' using errcode = '42501';
  end if;
  if q = '' then return; end if;

  return query
  select p.id,
    coalesce(nullif(btrim(i.real_name), ''), 'Student')::text,
    p.branch_code,
    p.department,
    p.academic_year,
    p.enrollment_number,
    right(split_part(lower(u.email), '@', 1), 3)::text
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.identity_records i on i.user_id = p.id
  where p.role = 'student'
    and p.enrollment_number is not null
    and (p_branch_code is null or upper(p.branch_code) = upper(p_branch_code))
    and (
      p.enrollment_number like upper(q) || '%'
      or (char_length(q) >= 3 and (
        i.real_name ilike '%' || q || '%'
        or right(split_part(lower(u.email), '@', 1), 3) ilike '%' || q || '%'
      ))
    )
  order by case when p.enrollment_number like upper(q) || '%' then 0 else 1 end,
    i.real_name
  limit 20;
end;
$$;

-- Let a moderator inbox include assignments in the newly supported Unofficial
-- department rooms. Non-admins still see only their own active assignments.
create or replace function public.list_my_moderated_rooms()
returns table(room_id text, room_mode text, room_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if public.is_super_admin(auth.uid()) then
    return query
    select r.id, modes.mode_name, r.name
    from public.rooms r
    cross join (values ('official'::text), ('unofficial'::text)) modes(mode_name)
    where r.id <> 'official-live'
      and (modes.mode_name = 'unofficial' or public.is_official_room(r.id))
    order by modes.mode_name, r.name;
    return;
  end if;

  return query
  select r.id, m.room_mode, r.name
  from public.room_moderators m
  join public.rooms r on r.id = m.room_id
  where m.student_id = auth.uid()
    and m.active and m.starts_at <= now()
    and (m.ends_at is null or m.ends_at > now())
    and r.id <> 'official-live'
  order by m.room_mode, r.name;
end;
$$;

create or replace function public.can_receive_room_chat_broadcast(p_topic text)
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  mode_value text := split_part(p_topic, ':', 2);
  room_value text := split_part(p_topic, ':', 3);
begin
  if uid is null then return false; end if;

  if p_topic = 'room:general' then
    return public.can_use_room_chat('general', 'unofficial', uid)
      and not exists (
        select 1 from public.room_blocks b
        where b.room_id = 'general' and b.user_id = uid and b.ends_at > now()
      );
  end if;

  if p_topic = 'room:official-live' then
    return public.can_use_room_chat('official-live', 'official', uid)
      and exists (
        select 1 from public.room_sessions s
        where s.room_id = 'official-live' and s.room_mode = 'official'
          and s.user_id = uid and s.left_at is null
      )
      and not exists (
        select 1 from public.room_blocks b
        where b.room_id = 'official-live' and b.user_id = uid and b.ends_at > now()
      );
  end if;

  if split_part(p_topic, ':', 1) <> 'room'
      or mode_value not in ('official', 'unofficial') or room_value = '' then
    return false;
  end if;

  return public.can_use_room_chat(room_value, mode_value, uid)
    and exists (
      select 1 from public.room_sessions s
      where s.room_id = room_value and s.room_mode = mode_value
        and s.user_id = uid and s.left_at is null
    )
    and not exists (
      select 1 from public.room_blocks b
      where b.room_id = room_value and b.user_id = uid and b.ends_at > now()
    );
end;
$$;

drop policy if exists "Authenticated users can receive room broadcasts" on realtime.messages;
create policy "Authenticated users can receive room broadcasts"
  on realtime.messages for select to authenticated
  using (
    extension = 'broadcast'
    and public.can_receive_room_chat_broadcast(realtime.topic())
  );

-- Retain per-room session and block checks while no longer forbidding faculty
-- from receiving their anonymous Unofficial room messages.
drop policy if exists "Faculty receive only Official room broadcasts" on realtime.messages;
drop policy if exists "Faculty can receive only Official live broadcasts" on realtime.messages;
drop policy if exists "Faculty cannot use Unofficial room chat" on public.room_messages;
drop policy if exists "Faculty can use only Official live messages" on public.room_messages;

drop policy if exists "Users can send messages as themselves" on public.room_messages;
create policy "Users can send messages as themselves"
  on public.room_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.can_use_room_chat(room_id, room_mode, auth.uid())
    and not exists (
      select 1 from public.room_blocks b
      where b.room_id = room_messages.room_id
        and b.user_id = auth.uid() and b.ends_at > now()
    )
    and (
      (room_id = 'general' and room_mode = 'unofficial')
      or (room_id = 'official-live' and room_mode = 'official'
        and exists (
          select 1 from public.room_sessions s
          where s.room_id = room_messages.room_id
            and s.room_mode = room_messages.room_mode
            and s.user_id = auth.uid() and s.left_at is null
        ))
      or (room_id not in ('general', 'official-live')
        and exists (
          select 1 from public.room_sessions s
          where s.room_id = room_messages.room_id
            and s.room_mode = room_messages.room_mode
            and s.user_id = auth.uid() and s.left_at is null
        ))
    )
  );

revoke all on function public.can_use_room_chat(text, text, uuid),
  public.join_room_chat(text, text),
  public.send_room_chat_message(text, text, text),
  public.send_campus_live_message(text, text),
  public.list_moderation_rooms(text),
  public.assign_room_moderator(text, uuid, timestamptz, text),
  public.search_students(text, text, text),
  public.list_my_moderated_rooms(),
  public.can_receive_room_chat_broadcast(text)
  from public, anon, authenticated;

grant execute on function public.join_room_chat(text, text),
  public.can_use_room_chat(text, text, uuid),
  public.can_receive_room_chat_broadcast(text),
  public.send_room_chat_message(text, text, text),
  public.send_campus_live_message(text, text),
  public.list_moderation_rooms(text),
  public.assign_room_moderator(text, uuid, timestamptz, text),
  public.search_students(text, text, text),
  public.list_my_moderated_rooms()
  to authenticated;

grant insert on public.room_messages to authenticated;

notify pgrst, 'reload schema';
commit;
