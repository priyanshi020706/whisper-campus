begin;

-- Both campus modes use moderator approval for ordinary student posts.
-- Faculty and Super Admin posts are immediately visible. Room moderators may
-- publish directly only in rooms where their assignment is currently active.
alter table public.official_posts add column if not exists approval_status text not null default 'approved';
alter table public.official_posts drop constraint if exists official_posts_approval_status_check;
alter table public.official_posts add constraint official_posts_approval_status_check
  check (approval_status in ('pending','approved','rejected'));
create index if not exists official_posts_room_approved_recent_idx
  on public.official_posts(room_id,created_at desc) where approval_status='approved';

-- Student submissions can include an image; keep the existing owner/path
-- boundary while allowing any authenticated Official student to upload.
drop policy if exists "Official room posters can upload official post images" on storage.objects;
create policy "Official users can upload owned post images" on storage.objects for insert to authenticated
  with check(bucket_id='official-post-images' and (storage.foldername(name))[1]=(select auth.uid())::text
    and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')));

create or replace function public.set_unofficial_post_approval_status()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if public.is_faculty_account(auth.uid()) or public.is_super_admin(auth.uid())
     or public.is_active_room_moderator(new.room_id,'unofficial',auth.uid()) then
    new.approval_status := 'approved';
  else
    new.approval_status := 'pending';
  end if;
  return new;
end;
$$;

create or replace function public.set_official_post_approval_status()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if public.is_faculty(auth.uid()) or public.is_super_admin(auth.uid())
     or public.is_active_room_moderator(new.room_id,'official',auth.uid()) then
    new.approval_status := 'approved';
  else
    new.approval_status := 'pending';
  end if;
  return new;
end;
$$;
drop trigger if exists official_posts_set_approval_status on public.official_posts;
create trigger official_posts_set_approval_status before insert on public.official_posts
  for each row execute function public.set_official_post_approval_status();

create or replace function public.is_eligible_official_user(p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users u join public.profiles p on p.id=u.id
    where u.id=p_uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$' or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email)='25mc1pr108@mitsgwl.ac.in') and p.role in ('student','faculty','super_admin'));
$$;

-- Students may submit Official posts too; status is decided by the database
-- trigger above, never by a client-supplied approval value.
create or replace function public.create_official_post(
  p_post_id uuid,p_content text,p_image_path text,p_department_code text,p_room_id text
)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); clean text:=btrim(coalesce(p_content,''));
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not public.is_eligible_official_user(uid) then raise exception 'Verified Official MITS Google account required' using errcode='42501'; end if;
  if p_room_id='official-live' or not public.is_official_room(p_room_id) then raise exception 'Choose an Official posting room'; end if;
  if p_room_id like 'dept-%' and lower(coalesce(p_department_code,''))<>substring(p_room_id from 6) then raise exception 'Department and room do not match'; end if;
  if p_room_id='general' and p_department_code is not null then raise exception 'Campus-wide posts cannot select a department'; end if;
  if not (public.is_faculty(uid) or public.is_super_admin(uid)
      or public.is_active_room_moderator(p_room_id,'official',uid)
      or exists(select 1 from public.profiles p where p.id=uid and p.role='student')) then
    raise exception 'An eligible MITS account is required to submit' using errcode='42501';
  end if;
  if char_length(clean)>2000 or (clean='' and p_image_path is null) then raise exception 'Add a caption or image'; end if;
  if p_image_path is not null and p_image_path !~ ('^'||uid::text||'/'||p_room_id||'/posts/'||p_post_id::text||'/'||p_post_id::text||'[.](jpg|jpeg|png|webp)$') then raise exception 'Invalid official image path'; end if;
  insert into public.official_posts(id,author_id,department_code,content,image_path,room_id)
    values(p_post_id,uid,p_department_code,clean,p_image_path,p_room_id);
end;
$$;

create or replace function public.get_official_posts_with_activity(p_department_code text,p_limit integer,p_room_id text)
returns table(post_id uuid,department_code text,author_name text,author_branch text,author_year integer,content text,
  created_at timestamptz,image_path text,is_mine boolean,like_count bigint,liked_by_me boolean,comment_count bigint)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles me on me.id=u.id
    where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$' or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email)='25mc1pr108@mitsgwl.ac.in') and me.role in ('student','faculty','super_admin')) then
    raise exception 'Official MITS account required' using errcode='42501';
  end if;
  if p_room_id='official-live' or not public.is_official_room(p_room_id) then raise exception 'Choose an Official posting room'; end if;
  if p_room_id like 'dept-%' and lower(coalesce(p_department_code,''))<>substring(p_room_id from 6) then raise exception 'Department and room do not match'; end if;
  return query select post.id,post.department_code,
    (coalesce(nullif(btrim(i.real_name),''),'Student')||case when public.is_active_room_moderator(p_room_id,'official',post.author_id) then ' (Moderator)' else '' end)::text,
    case when p.role='faculty' then 'Faculty'||case when p.branch_code is null then '' else ' · '||p.branch_code end else coalesce(p.branch_code,'') end::text,
    case when p.role='faculty' then null else p.academic_year end,post.content,post.created_at,post.image_path,post.author_id=auth.uid(),
    (select count(*)::bigint from public.official_post_likes l where l.post_id=post.id),
    exists(select 1 from public.official_post_likes l where l.post_id=post.id and l.user_id=auth.uid()),
    (select count(*)::bigint from public.official_post_replies r where r.post_id=post.id)
  from public.official_posts post join public.identity_records i on i.user_id=post.author_id join public.profiles p on p.id=post.author_id
  where post.room_id=p_room_id and post.department_code is not distinct from p_department_code
    and post.approval_status='approved'
  order by post.created_at desc limit greatest(1,least(coalesce(p_limit,50),100));
end;
$$;

create or replace function public.get_pending_unofficial_room_posts(p_room_id text)
returns table(post_id uuid,author_username text,content text,created_at timestamptz,image_path text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not (public.is_super_admin(auth.uid()) or public.is_active_room_moderator(p_room_id,'unofficial',auth.uid())) then
    raise exception 'Room moderator access required' using errcode='42501';
  end if;
  return query select p.id,coalesce(nullif(btrim(profile.anon_username),''),'Anonymous'),p.content,p.created_at,p.image_path
    from public.posts p left join public.profiles profile on profile.id=p.author_id
    where p.room_id=p_room_id and p.approval_status='pending' order by p.created_at;
end;
$$;

create or replace function public.get_pending_official_room_posts(p_room_id text)
returns table(post_id uuid,author_name text,content text,created_at timestamptz,image_path text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_active_room_moderator(p_room_id,'official',auth.uid())) then
    raise exception 'Room moderator access required' using errcode='42501';
  end if;
  return query select p.id,coalesce(nullif(btrim(i.real_name),''),'Student'),p.content,p.created_at,p.image_path
    from public.official_posts p left join public.identity_records i on i.user_id=p.author_id
    where p.room_id=p_room_id and p.approval_status='pending' order by p.created_at;
end;
$$;

create or replace function public.review_unofficial_room_post(p_post_id uuid,p_decision text)
returns void language plpgsql security definer set search_path='' as $$
declare post_room text;
begin
  if p_decision not in ('approved','rejected') then raise exception 'Choose approve or reject'; end if;
  select p.room_id into post_room from public.posts p where p.id=p_post_id and p.approval_status='pending' for update;
  if post_room is null then raise exception 'Pending post not found'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_active_room_moderator(post_room,'unofficial',auth.uid())) then
    raise exception 'Room moderator access required' using errcode='42501';
  end if;
  update public.posts set approval_status=p_decision where id=p_post_id;
end;
$$;

create or replace function public.review_official_room_post(p_post_id uuid,p_decision text)
returns void language plpgsql security definer set search_path='' as $$
declare post_room text;
begin
  if p_decision not in ('approved','rejected') then raise exception 'Choose approve or reject'; end if;
  if not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  select p.room_id into post_room from public.official_posts p where p.id=p_post_id and p.approval_status='pending' for update;
  if post_room is null then raise exception 'Pending post not found'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_active_room_moderator(post_room,'official',auth.uid())) then
    raise exception 'Room moderator access required' using errcode='42501';
  end if;
  update public.official_posts set approval_status=p_decision where id=p_post_id;
end;
$$;

create or replace function public.get_my_pending_room_posts(p_mode text)
returns table(post_id uuid,room_id text,content text,created_at timestamptz,approval_status text)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or p_mode not in ('official','unofficial') then raise exception 'Invalid request' using errcode='42501'; end if;
  if p_mode='official' then
    return query select p.id,p.room_id,p.content,p.created_at,p.approval_status from public.official_posts p
      where p.author_id=auth.uid() and p.approval_status in ('pending','rejected') order by p.created_at desc;
  else
    return query select p.id,p.room_id,p.content,p.created_at,p.approval_status from public.posts p
      where p.author_id=auth.uid() and p.approval_status in ('pending','rejected') order by p.created_at desc;
  end if;
end;
$$;

-- Keep pending/rejected Official submissions out of the normal profile feed;
-- their author sees their status in the dedicated pending-status section.
do $$
declare fn_oid oid; definition text; changed text;
begin
  select p.oid into fn_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='get_my_official_profile_activity' and p.pronargs=2;
  if fn_oid is not null then
    definition:=pg_get_functiondef(fn_oid);
    changed:=replace(definition,'where p.author_id=uid order by p.created_at desc','where p.author_id=uid and p.approval_status=''approved'' order by p.created_at desc');
    changed:=replace(changed,'where c.author_id=uid order by c.created_at desc','where c.author_id=uid and p.approval_status=''approved'' order by c.created_at desc');
    if changed<>definition then execute changed; end if;
  end if;
end;
$$;

-- Expand only the Official identity card with the rooms this person currently
-- moderates. The function remains inaccessible from Unofficial mode.
drop function if exists public.get_official_profile_card(uuid);
create function public.get_official_profile_card(p_user_id uuid)
returns table(real_name text,branch_code text,branch_name text,study_year int,role text,enrollment_number text,moderated_rooms text[])
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles me on me.id=u.id
    where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$' or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email)='25mc1pr108@mitsgwl.ac.in') and me.role in ('student','faculty','super_admin')) then
    raise exception 'Official MITS profile access required' using errcode='42501';
  end if;
  return query select i.real_name,p.branch_code,p.department,p.academic_year,p.role,
    case when p.role in ('student','faculty','super_admin') then p.enrollment_number else null end,
    coalesce((select array_agg(case m.room_id
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
          else m.room_id end order by m.room_id) from public.room_moderators m
      where m.student_id=p.id and m.room_mode='official' and m.active and m.starts_at<=now()
        and (m.ends_at is null or m.ends_at>now())),array[]::text[])
  from public.profiles p join public.identity_records i on i.user_id=p.id where p.id=p_user_id;
end;
$$;

-- Private room-scoped contact threads. These are separate from the room group
-- chat so suggestions are visible only to the sender and that room's staff.
create table if not exists public.room_moderator_threads (
  id uuid primary key default gen_random_uuid(),
  room_id text not null,
  room_mode text not null check(room_mode in ('official','unofficial')),
  student_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(room_id,room_mode,student_id)
);
create table if not exists public.room_moderator_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.room_moderator_threads(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  content text not null check(char_length(btrim(content)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists room_moderator_messages_thread_recent_idx
  on public.room_moderator_messages(thread_id,created_at);
alter table public.room_moderator_threads enable row level security;
alter table public.room_moderator_messages enable row level security;
revoke all on table public.room_moderator_threads,public.room_moderator_messages from anon,authenticated;
grant all on table public.room_moderator_threads,public.room_moderator_messages to service_role;

create or replace function public.get_or_create_room_moderator_thread(p_room_id text,p_mode text)
returns uuid language plpgsql security definer set search_path='' as $$
declare thread_id uuid;
begin
  if auth.uid() is null or p_mode not in ('official','unofficial')
     or not public.can_use_room_chat(p_room_id,p_mode,auth.uid()) then
    raise exception 'You cannot contact moderators for this room' using errcode='42501';
  end if;
  if p_mode='official' and not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  if exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now()) then
    raise exception 'You are blocked from this room' using errcode='42501';
  end if;
  if not exists(select 1 from public.room_moderators m where m.room_id=p_room_id and m.room_mode=p_mode
      and m.active and m.starts_at<=now() and (m.ends_at is null or m.ends_at>now())) then
    raise exception 'This room has no active moderator yet';
  end if;
  insert into public.room_moderator_threads(room_id,room_mode,student_id)
    values(p_room_id,p_mode,auth.uid()) on conflict(room_id,room_mode,student_id) do nothing;
  select t.id into thread_id from public.room_moderator_threads t
    where t.room_id=p_room_id and t.room_mode=p_mode and t.student_id=auth.uid();
  return thread_id;
end;
$$;

create or replace function public.list_room_moderator_threads(p_room_id text,p_mode text)
returns table(thread_id uuid,display_name text,last_message text,last_message_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or p_mode not in ('official','unofficial')
     or not public.can_use_room_chat(p_room_id,p_mode,auth.uid()) then
    raise exception 'Room access required' using errcode='42501';
  end if;
  if p_mode='official' and not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_active_room_moderator(p_room_id,p_mode,auth.uid())) then
    return query select t.id,
      case when p_mode='official' then coalesce(nullif(btrim(i.real_name),''),'Student') else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end,
      (select m.content from public.room_moderator_messages m where m.thread_id=t.id order by m.created_at desc limit 1),
      (select m.created_at from public.room_moderator_messages m where m.thread_id=t.id order by m.created_at desc limit 1)
    from public.room_moderator_threads t left join public.profiles p on p.id=t.student_id
      left join public.identity_records i on i.user_id=t.student_id
    where t.room_id=p_room_id and t.room_mode=p_mode and t.student_id=auth.uid();
    return;
  end if;
  return query select t.id,
    case when p_mode='official' then coalesce(nullif(btrim(i.real_name),''),'Student') else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end,
    (select m.content from public.room_moderator_messages m where m.thread_id=t.id order by m.created_at desc limit 1),
    (select m.created_at from public.room_moderator_messages m where m.thread_id=t.id order by m.created_at desc limit 1)
  from public.room_moderator_threads t left join public.profiles p on p.id=t.student_id
    left join public.identity_records i on i.user_id=t.student_id
  where t.room_id=p_room_id and t.room_mode=p_mode order by t.created_at desc;
end;
$$;

create or replace function public.get_room_moderator_messages(p_thread_id uuid)
returns table(message_id uuid,sender_id uuid,is_mine boolean,display_name text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare t public.room_moderator_threads%rowtype;
begin
  select * into t from public.room_moderator_threads where id=p_thread_id;
  if not found or auth.uid() is null or not public.can_use_room_chat(t.room_id,t.room_mode,auth.uid())
     or not (t.student_id=auth.uid() or public.is_super_admin(auth.uid())
       or public.is_active_room_moderator(t.room_id,t.room_mode,auth.uid())) then
    raise exception 'Private moderator thread access required' using errcode='42501';
  end if;
  if t.room_mode='official' and not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  return query select m.id,case when t.room_mode='official' then m.sender_id else null::uuid end,m.sender_id=auth.uid(),
    (case when t.room_mode='official' then coalesce(nullif(btrim(i.real_name),''),'Student') else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end)::text,
    m.content,m.created_at
  from public.room_moderator_messages m left join public.profiles p on p.id=m.sender_id
    left join public.identity_records i on i.user_id=m.sender_id
  where m.thread_id=p_thread_id order by m.created_at;
end;
$$;

create or replace function public.send_room_moderator_message(p_thread_id uuid,p_content text)
returns uuid language plpgsql security definer set search_path='' as $$
declare t public.room_moderator_threads%rowtype; message_id uuid;
begin
  select * into t from public.room_moderator_threads where id=p_thread_id;
  if not found or auth.uid() is null or not public.can_use_room_chat(t.room_id,t.room_mode,auth.uid())
     or not (t.student_id=auth.uid() or public.is_super_admin(auth.uid())
       or public.is_active_room_moderator(t.room_id,t.room_mode,auth.uid())) then
    raise exception 'Private moderator thread access required' using errcode='42501';
  end if;
  if t.room_mode='official' and not public.is_eligible_official_user(auth.uid()) then raise exception 'Verified Official MITS account required' using errcode='42501'; end if;
  if exists(select 1 from public.room_blocks b where b.room_id=t.room_id and b.user_id=auth.uid() and b.ends_at>now()) then
    raise exception 'You are blocked from this room' using errcode='42501';
  end if;
  if char_length(btrim(coalesce(p_content,''))) not between 1 and 2000 then raise exception 'Message must be 1 to 2000 characters'; end if;
  insert into public.room_moderator_messages(thread_id,sender_id,content)
    values(p_thread_id,auth.uid(),btrim(p_content)) returning id into message_id;
  return message_id;
end;
$$;

revoke all on function public.get_pending_official_room_posts(text),public.review_official_room_post(uuid,text),public.get_my_pending_room_posts(text),
  public.get_or_create_room_moderator_thread(text,text),public.list_room_moderator_threads(text,text),
  public.get_room_moderator_messages(uuid),public.send_room_moderator_message(uuid,text) from public,anon,authenticated;
grant execute on function public.get_pending_official_room_posts(text),public.review_official_room_post(uuid,text),public.get_my_pending_room_posts(text),
  public.get_or_create_room_moderator_thread(text,text),public.list_room_moderator_threads(text,text),
  public.get_room_moderator_messages(uuid),public.send_room_moderator_message(uuid,text) to authenticated;
revoke all on function public.get_official_profile_card(uuid) from public,anon,authenticated;
grant execute on function public.get_official_profile_card(uuid) to authenticated;
revoke all on function public.is_eligible_official_user(uuid) from public,anon,authenticated;
revoke all on function public.is_super_admin(uuid) from public,anon,authenticated;
grant execute on function public.is_super_admin(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
