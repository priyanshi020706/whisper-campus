begin;

-- The deployed profile constraint predates the Super Admin role.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('student','faculty','super_admin'));

-- Promote the explicitly requested test account. Its role is Super Admin;
-- faculty capabilities are retained through is_faculty/is_faculty_account.
update public.profiles p set role='super_admin'
from auth.users u
where u.id=p.id and lower(u.email)='25mc1pr108@mitsgwl.ac.in'
  and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google';

-- Keep the test account elevated after its next verified Google profile sync.
do $$
declare fn oid; definition text; changed text;
begin
  select p.oid into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='sync_my_college_profile' and p.pronargs=0;
  if fn is null then raise exception 'sync_my_college_profile was not found'; end if;
  definition:=pg_get_functiondef(fn);
  changed:=replace(definition,
    'role=case when existing_role=''super_admin'' then existing_role else ''faculty'' end,',
    'role=case when mail=''25mc1pr108@mitsgwl.ac.in'' then ''super_admin'' when existing_role=''super_admin'' then existing_role else ''faculty'' end,');
  if changed=definition then raise exception 'Could not extend the verified profile sync for the requested admin account'; end if;
  execute changed;
end;
$$;

-- The test Super Admin also retains the anonymous faculty identity in Unofficial.
create or replace function public.is_faculty_account(p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.profiles p join auth.users u on u.id=p.id
    where p.id=p_uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
      and (p.role='faculty' or (p.role='super_admin' and lower(u.email)='25mc1pr108@mitsgwl.ac.in'))
      and (lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$' or lower(u.email)='25mc1pr108@mitsgwl.ac.in'));
$$;

-- Show this dual-capability test account as Faculty in Official author labels
-- while preserving the Super Admin label and backend privileges.
do $$
declare fn record; definition text; changed text;
begin
  for fn in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('get_official_posts_with_activity','get_room_chat_messages','broadcast_room_message')
  loop
    definition:=pg_get_functiondef(fn.oid);
    changed:=replace(definition,'p.role=''faculty'' then','p.role in (''faculty'',''super_admin'') then');
    changed:=replace(changed,'member_role=''faculty'' then','member_role in (''faculty'',''super_admin'') then');
    if changed<>definition then execute changed; end if;
  end loop;
end;
$$;

-- One query supplies the assigned rooms for the moderator's permanent inbox.
create or replace function public.list_my_moderated_rooms()
returns table(room_id text,room_mode text,room_name text)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if public.is_super_admin(auth.uid()) then
    return query select r.id,campus_mode.mode_name,
      coalesce(nullif(r.name,''),case r.id
        when 'dept-ad' then 'AI & Data Science' when 'dept-ai' then 'Artificial Intelligence'
        when 'dept-am' then 'AI & Machine Learning' when 'dept-cb' then 'CS & Business Systems'
        when 'dept-cd' then 'CS & Design' when 'dept-ce' then 'Civil Engineering'
        when 'dept-cm' then 'Chemical Engineering' when 'dept-cs' then 'Computer Science & Engg'
        when 'dept-ec' then 'Electronics & Communication' when 'dept-ee' then 'Electrical Engineering'
        when 'dept-el' then 'Electronics Engineering' when 'dept-et' then 'Electronics & Telecommunication'
        when 'dept-io' then 'Internet of Things (IoT)' when 'dept-ir' then 'IT (AI & Robotics)'
        when 'dept-it' then 'Information Technology' when 'dept-mc' then 'Mathematics & Computing'
        when 'dept-me' then 'Mechanical Engineering' when 'dept-tc' then 'CS & Technology'
        when 'dept-ar' then 'Architecture (B.Arch)' when 'general' then 'Campus-wide'
        else r.name end)
    from public.rooms r cross join (values('official'::text),('unofficial'::text)) campus_mode(mode_name)
    where r.id<>'official-live'
      and ((campus_mode.mode_name='official' and public.is_official_room(r.id))
        or (campus_mode.mode_name='unofficial' and r.id not like 'dept-%'))
    order by campus_mode.mode_name,r.name;
  else
    return query select r.id,m.room_mode,
      coalesce(nullif(r.name,''),case r.id
        when 'dept-ad' then 'AI & Data Science' when 'dept-ai' then 'Artificial Intelligence'
        when 'dept-am' then 'AI & Machine Learning' when 'dept-cb' then 'CS & Business Systems'
        when 'dept-cd' then 'CS & Design' when 'dept-ce' then 'Civil Engineering'
        when 'dept-cm' then 'Chemical Engineering' when 'dept-cs' then 'Computer Science & Engg'
        when 'dept-ec' then 'Electronics & Communication' when 'dept-ee' then 'Electrical Engineering'
        when 'dept-el' then 'Electronics Engineering' when 'dept-et' then 'Electronics & Telecommunication'
        when 'dept-io' then 'Internet of Things (IoT)' when 'dept-ir' then 'IT (AI & Robotics)'
        when 'dept-it' then 'Information Technology' when 'dept-mc' then 'Mathematics & Computing'
        when 'dept-me' then 'Mechanical Engineering' when 'dept-tc' then 'CS & Technology'
        when 'dept-ar' then 'Architecture (B.Arch)' when 'general' then 'Campus-wide'
        else r.name end)
    from public.room_moderators m join public.rooms r on r.id=m.room_id
    where m.student_id=auth.uid() and m.active and m.starts_at<=now()
      and (m.ends_at is null or m.ends_at>now()) and r.id<>'official-live'
    order by m.room_mode,r.name;
  end if;
end;
$$;

-- Merge the latest private Contact Moderator messages across all permitted rooms.
create or replace function public.get_my_moderator_inbox()
returns table(thread_id uuid,room_id text,room_mode text,room_name text,display_name text,last_message text,last_message_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  return query
  with allowed_rooms as (
    select r.room_id,r.room_mode,r.room_name from public.list_my_moderated_rooms() r
  ), latest as (
    select distinct on (m.thread_id) m.thread_id,m.content,m.created_at
    from public.room_moderator_messages m order by m.thread_id,m.created_at desc
  )
  select t.id,t.room_id,t.room_mode,ar.room_name,
    case when t.room_mode='official' then coalesce(nullif(btrim(i.real_name),''),'Student')
      else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end::text,
    coalesce(latest.content,'Conversation started'),latest.created_at
  from public.room_moderator_threads t join allowed_rooms ar on ar.room_id=t.room_id and ar.room_mode=t.room_mode
    left join public.profiles p on p.id=t.student_id
    left join public.identity_records i on i.user_id=t.student_id
    left join latest on latest.thread_id=t.id
  order by latest.created_at desc nulls last,t.created_at desc;
end;
$$;

-- Admin-only deletion endpoints. Storage objects are removed by the client
-- after the database confirms the owning post was deleted.
create or replace function public.admin_delete_post(p_post_id uuid,p_mode text)
returns text language plpgsql security definer set search_path='' as $$
declare image text;
begin
  if not public.is_super_admin(auth.uid()) then raise exception 'Super Admin access required' using errcode='42501'; end if;
  if p_mode='official' then
    delete from public.official_posts where id=p_post_id returning image_path into image;
  elsif p_mode='unofficial' then
    delete from public.posts where id=p_post_id returning image_path into image;
  else raise exception 'Unknown campus mode';
  end if;
  if not found then raise exception 'Post not found'; end if;
  return image;
end;
$$;

create or replace function public.admin_delete_room_message(p_message_id uuid,p_room_id text,p_mode text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.is_super_admin(auth.uid()) then raise exception 'Super Admin access required' using errcode='42501'; end if;
  delete from public.room_messages where id=p_message_id and room_id=p_room_id and room_mode=p_mode;
  if not found then raise exception 'Message not found in this room'; end if;
end;
$$;

create or replace function public.broadcast_room_message_deleted()
returns trigger language plpgsql security definer set search_path='' as $$
declare topic text;
begin
  if old.room_id='general' then topic:='room:general';
  elsif old.room_id='official-live' then topic:='room:official-live';
  else topic:='room:'||old.room_mode||':'||old.room_id; end if;
  perform realtime.send(jsonb_build_object('message_id',old.id,'room_id',old.room_id,'room_mode',old.room_mode),
    'message_removed',topic,true);
  return old;
end;
$$;
drop trigger if exists room_messages_broadcast_deleted on public.room_messages;
create trigger room_messages_broadcast_deleted after delete on public.room_messages
  for each row execute function public.broadcast_room_message_deleted();

-- Admin may clean up images after admin_delete_post; ordinary users remain
-- limited to their own objects by the existing policies.
drop policy if exists "Super Admin can delete campus post images" on storage.objects;
create policy "Super Admin can delete campus post images" on storage.objects for delete to authenticated
  using(public.is_super_admin(auth.uid()) and bucket_id in ('campus-post-images','official-post-images'));

revoke all on function public.list_my_moderated_rooms(),public.get_my_moderator_inbox(),
  public.admin_delete_post(uuid,text),public.admin_delete_room_message(uuid,text,text) from public,anon,authenticated;
grant execute on function public.list_my_moderated_rooms(),public.get_my_moderator_inbox(),
  public.admin_delete_post(uuid,text),public.admin_delete_room_message(uuid,text,text) to authenticated;
revoke all on function public.broadcast_room_message_deleted() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
