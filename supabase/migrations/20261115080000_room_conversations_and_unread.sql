begin;

-- Give every room conversation its own Official/Unofficial stream. The
-- existing always-on rooms remain separate and keep their current behavior.
alter table public.room_messages
  add column if not exists room_mode text not null default 'unofficial';
update public.room_messages
set room_mode = 'official'
where room_id = 'official-live';
alter table public.room_messages
  drop constraint if exists room_messages_room_mode_check;
alter table public.room_messages
  add constraint room_messages_room_mode_check
  check (room_mode in ('official', 'unofficial'));
create index if not exists room_messages_conversation_recent_idx
  on public.room_messages(room_id, room_mode, created_at desc);

alter table public.room_sessions
  add column if not exists room_mode text not null default 'unofficial';
update public.room_sessions
set room_mode = 'official'
where room_id = 'official-live';
alter table public.room_sessions
  drop constraint if exists room_sessions_room_mode_check;
alter table public.room_sessions
  add constraint room_sessions_room_mode_check
  check (room_mode in ('official', 'unofficial'));
drop index if exists public.room_sessions_one_active;
create unique index room_sessions_one_active
  on public.room_sessions(user_id, room_id, room_mode)
  where left_at is null;

create table if not exists public.room_chat_reads (
  room_id text not null references public.rooms(id) on delete cascade,
  room_mode text not null check (room_mode in ('official', 'unofficial')),
  user_id uuid not null references auth.users(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (room_id, room_mode, user_id)
);
alter table public.room_chat_reads enable row level security;
revoke all on public.room_chat_reads from public, anon, authenticated;
grant all on public.room_chat_reads to service_role;

create or replace function public.can_use_room_chat(p_room_id text, p_mode text, p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_user_id is null or p_mode not in ('official', 'unofficial') then false
    when p_mode = 'official' then
      public.is_official_room(p_room_id)
      and exists (select 1 from public.profiles p where p.id = p_user_id and p.role in ('student', 'faculty', 'super_admin'))
    else
      p_room_id <> 'official-live'
      and not public.is_faculty_account(p_user_id)
      and exists (select 1 from public.profiles p where p.id = p_user_id and p.role in ('student', 'super_admin'))
  end;
$$;

create or replace function public.join_room_chat(p_room_id text, p_mode text)
returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); joined timestamptz;
begin
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You cannot join this room chat' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.room_blocks b
    where b.room_id = p_room_id and b.user_id = uid and b.ends_at > now()
  ) then
    raise exception 'You are temporarily blocked from this room' using errcode = '42501';
  end if;
  update public.room_sessions
  set left_at = now()
  where user_id = uid and room_id = p_room_id and room_mode = p_mode and left_at is null;
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

-- Preserve the legacy RPC names used by the two always-on campus chats while
-- recording their Official/Unofficial mode in the upgraded session table.
create or replace function public.join_room(p_room_id text)
returns timestamptz
language sql security definer set search_path = '' as $$
  select public.join_room_chat(
    p_room_id,
    case when p_room_id = 'official-live' then 'official' else 'unofficial' end
  );
$$;

create or replace function public.leave_room_chat(p_room_id text, p_mode text)
returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  update public.room_sessions
  set left_at = now()
  where user_id = uid and room_id = p_room_id and room_mode = p_mode and left_at is null;
  insert into public.room_chat_reads(room_id, room_mode, user_id, last_read_at)
  values (p_room_id, p_mode, uid, now())
  on conflict (room_id, room_mode, user_id)
  do update set last_read_at = excluded.last_read_at;
end;
$$;

create or replace function public.leave_room(p_room_id text)
returns void
language sql security definer set search_path = '' as $$
  select public.leave_room_chat(
    p_room_id,
    case when p_room_id = 'official-live' then 'official' else 'unofficial' end
  );
$$;

create or replace function public.get_room_chat_messages(p_room_id text, p_mode text, p_limit integer default 100)
returns table(message_id uuid, room_id text, author_id uuid, author_username text, content text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can_use_room_chat(p_room_id, p_mode, auth.uid()) then
    raise exception 'You cannot read this room chat' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_sessions s where s.room_id = p_room_id
      and s.room_mode = p_mode and s.user_id = auth.uid() and s.left_at is null
  ) then raise exception 'Join the room chat first' using errcode = '42501'; end if;

  return query
  select m.id, m.room_id,
    case when p_mode = 'official' then m.sender_id else null::uuid end,
    case when p_mode = 'official' then
      coalesce(nullif(btrim(i.real_name), ''), 'Student') || ' · ' ||
      case when p.role = 'faculty' then 'Faculty' || case when p.branch_code is null then '' else ' · ' || p.branch_code end
        else coalesce(p.branch_code, '') || ' · ' || case
          when p.academic_year > 4 then 'Alumni'
          when p.academic_year = 1 then '1st'
          when p.academic_year = 2 then '2nd'
          when p.academic_year = 3 then '3rd'
          when p.academic_year = 4 then '4th'
          else 'Year unavailable' end
      end
    else coalesce(nullif(btrim(p.anon_username), ''), 'Anonymous') end::text,
    m.content, m.created_at
  from (
    select x.id, x.room_id, x.sender_id, x.content, x.created_at
    from public.room_messages x
    where x.room_id = p_room_id and x.room_mode = p_mode
      and x.room_id not in ('general', 'official-live')
      and x.created_at >= now() - interval '7 days'
    order by x.created_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 200))
  ) m
  join public.profiles p on p.id = m.sender_id
  left join public.identity_records i on i.user_id = m.sender_id
  order by m.created_at asc;
end;
$$;

create or replace function public.send_room_chat_message(p_room_id text, p_mode text, p_content text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); message_id uuid; clean text := btrim(coalesce(p_content, ''));
begin
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You cannot post in this room chat' using errcode = '42501';
  end if;
  if p_room_id in ('general', 'official-live') then
    raise exception 'Use the campus live chat for this room' using errcode = '42501';
  end if;
  if char_length(clean) not between 1 and 2000 then
    raise exception 'Messages must contain 1 to 2000 characters';
  end if;
  if not exists (
    select 1 from public.room_sessions s where s.room_id = p_room_id
      and s.room_mode = p_mode and s.user_id = uid and s.left_at is null
  ) then raise exception 'Join the room chat before sending' using errcode = '42501'; end if;
  insert into public.room_messages(room_id, room_mode, sender_id, content)
  values (p_room_id, p_mode, uid, clean)
  returning id into message_id;
  return message_id;
end;
$$;

create or replace function public.get_room_chat_unread(p_room_id text, p_mode text)
returns integer
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); last_read timestamptz;
begin
  if not public.can_use_room_chat(p_room_id, p_mode, uid) then
    raise exception 'You cannot read this room chat' using errcode = '42501';
  end if;
  if p_room_id in ('general', 'official-live') then return 0; end if;
  select r.last_read_at into last_read from public.room_chat_reads r
  where r.room_id = p_room_id and r.room_mode = p_mode and r.user_id = uid;
  return (
    select count(*)::integer from public.room_messages m
    where m.room_id = p_room_id and m.room_mode = p_mode
      and m.created_at >= greatest(coalesce(last_read, '-infinity'::timestamptz), now() - interval '7 days')
      and m.sender_id <> uid
  );
end;
$$;

-- Chat-tab sends go through the RPC. Keep legacy live-room writes but require
-- the expected mode and enforce active sessions for the Official live room.
drop policy if exists "Users can send messages as themselves" on public.room_messages;
create policy "Users can send messages as themselves"
  on public.room_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (
      (room_id = 'official-live' and room_mode = 'official'
        and exists (select 1 from public.room_sessions s where s.room_id = room_messages.room_id
          and s.room_mode = room_messages.room_mode and s.user_id = auth.uid() and s.left_at is null))
      or (room_id = 'general' and room_mode = 'unofficial' and not public.is_faculty_account(auth.uid()))
      or (room_id not in ('general', 'official-live')
        and exists (select 1 from public.room_sessions s where s.room_id = room_messages.room_id
          and s.room_mode = room_messages.room_mode and s.user_id = auth.uid() and s.left_at is null)
        and public.can_use_room_chat(room_id, room_mode, auth.uid()))
    )
  );

drop policy if exists "Official live history only for active session" on public.room_messages;
create policy "Room chat messages are session and mode scoped"
  on public.room_messages for select to authenticated
  using (
    room_id = 'official-live' and room_mode = 'official'
    and exists (select 1 from public.room_sessions s where s.room_id = room_messages.room_id
      and s.room_mode = room_messages.room_mode and s.user_id = auth.uid()
      and room_messages.created_at >= s.joined_at and room_messages.created_at <= coalesce(s.left_at, now()))
  );

-- Keep the existing faculty guard, but permit faculty in every Official room.
drop policy if exists "Faculty can use only Official live messages" on public.room_messages;
create policy "Faculty cannot use Unofficial room chat"
  on public.room_messages as restrictive for all to authenticated
  using (not public.is_faculty_account(auth.uid()) or room_mode = 'official')
  with check (not public.is_faculty_account(auth.uid()) or room_mode = 'official');

create or replace function public.broadcast_room_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare display_name text; branch text; year_no integer; member_role text; payload jsonb; topic text;
begin
  if new.room_id in ('general', 'official-live') then
    topic := 'room:' || new.room_id;
    if new.room_id = 'official-live' then
      new.room_mode := 'official';
    else
      new.room_mode := 'unofficial';
    end if;
  else
    topic := 'room:' || new.room_mode || ':' || new.room_id;
  end if;
  if new.room_mode = 'official' then
    select coalesce(nullif(btrim(i.real_name), ''), 'Student'), p.branch_code,
      p.academic_year, p.role into display_name, branch, year_no, member_role
    from public.profiles p left join public.identity_records i on i.user_id = p.id
    where p.id = new.sender_id;
    display_name := display_name || ' · ' || case
      when member_role = 'faculty' then 'Faculty' || case when branch is null then '' else ' · ' || branch end
      else coalesce(branch, '') || ' · ' || case
        when year_no > 4 then 'Alumni' when year_no = 1 then '1st'
        when year_no = 2 then '2nd' when year_no = 3 then '3rd'
        when year_no = 4 then '4th' else 'Year unavailable' end end;
  else
    select coalesce(nullif(btrim(p.anon_username), ''), 'Anonymous')
      into display_name from public.profiles p where p.id = new.sender_id;
  end if;
  payload := jsonb_build_object('message_id', new.id, 'room_id', new.room_id,
    'room_mode', new.room_mode, 'author_username', coalesce(display_name, 'Anonymous'),
    'content', new.content, 'created_at', new.created_at);
  if new.room_mode = 'official' then payload := payload || jsonb_build_object('author_id', new.sender_id); end if;
  perform realtime.send(payload, 'new_message', topic, true);
  return new;
end;
$$;

-- Private broadcast channel access follows the same room/mode and active-chat
-- rules as the room sessions. Existing global live channels retain their policy.
drop policy if exists "Authenticated users can receive room broadcasts" on realtime.messages;
drop policy if exists "Faculty can receive only Official live broadcasts" on realtime.messages;
create policy "Authenticated users can receive room broadcasts"
  on realtime.messages for select to authenticated
  using (
    extension = 'broadcast'
    and (
      (realtime.topic() = 'room:official-live' and exists (
        select 1 from public.room_sessions s where s.room_id = 'official-live'
          and s.room_mode = 'official' and s.user_id = auth.uid() and s.left_at is null))
      or (realtime.topic() = 'room:general' and not public.is_faculty_account(auth.uid()))
      or (split_part(realtime.topic(), ':', 1) = 'room'
        and split_part(realtime.topic(), ':', 2) in ('official', 'unofficial')
        and public.can_use_room_chat(split_part(realtime.topic(), ':', 3), split_part(realtime.topic(), ':', 2), auth.uid())
        and exists (select 1 from public.room_sessions s
          where s.room_id = split_part(realtime.topic(), ':', 3)
            and s.room_mode = split_part(realtime.topic(), ':', 2)
            and s.user_id = auth.uid() and s.left_at is null))
    )
  );
create policy "Faculty receive only Official room broadcasts"
  on realtime.messages as restrictive for select to authenticated
  using (
    not public.is_faculty_account(auth.uid())
    or realtime.topic() = 'room:official-live'
    or (split_part(realtime.topic(), ':', 2) = 'official'
      and public.is_official_room(split_part(realtime.topic(), ':', 3)))
  );

revoke all on function public.can_use_room_chat(text,text,uuid),
  public.join_room_chat(text,text), public.leave_room_chat(text,text),
  public.get_room_chat_messages(text,text,integer), public.send_room_chat_message(text,text,text),
  public.get_room_chat_unread(text,text) from public, anon, authenticated;
grant execute on function public.join_room_chat(text,text), public.leave_room_chat(text,text),
  public.get_room_chat_messages(text,text,integer), public.send_room_chat_message(text,text,text),
  public.get_room_chat_unread(text,text) to authenticated;

-- Expire room-conversation history after seven days. Reads already hide older
-- messages; pg_cron physically removes them when that extension is available.
do $$
begin
  begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      execute 'create extension pg_cron';
    end if;
    if to_regnamespace('cron') is not null then
      execute $q$
        select cron.schedule(
          'whisper-room-chat-expiry',
          '23 * * * *',
          $job$delete from public.room_messages
               where room_id not in ('general', 'official-live')
                 and created_at < now() - interval '7 days'$job$
        )
        where not exists (select 1 from cron.job where jobname = 'whisper-room-chat-expiry')
      $q$;
    end if;
  exception when others then
    raise warning 'Room chat reads still enforce a 7-day window, but automatic physical cleanup was not scheduled: %', sqlerrm;
  end;
end;
$$;

notify pgrst, 'reload schema';
commit;
