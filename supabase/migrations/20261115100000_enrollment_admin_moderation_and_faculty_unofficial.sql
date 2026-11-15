begin;

-- Roles remain assigned by the verified-email server sync. Enrollment numbers
-- are derived only from the student's MITS email local part.
create or replace function public.sync_my_college_profile()
returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  mail text;
  lp text;
  yy int;
  bc text;
  dept text;
  start_year int;
  study_year int;
  existing_role text;
  generated_enrollment text;
  local_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select lower(u.email) into mail from auth.users u
  where u.id=uid and u.email_confirmed_at is not null
    and (u.raw_app_meta_data->'providers') ? 'google';
  if mail is null then raise exception 'Verified Google account required' using errcode='42501'; end if;
  select p.role into existing_role from public.profiles p where p.id=uid;

  if mail ~ '^[^@]+@mitsgwalior[.]in$' or mail='25mc1pr108@mitsgwl.ac.in' then
    update public.profiles set role=case when existing_role='super_admin' then existing_role else 'faculty' end,
      academic_year=null,
      enrollment_number=case when mail='25mc1pr108@mitsgwl.ac.in'
        and split_part(mail,'@',1) ~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$'
        then 'BT'||upper(substring(split_part(mail,'@',1),3,2))||substring(split_part(mail,'@',1),1,2)||'O1'||right(split_part(mail,'@',1),3)
        else null end where id=uid;
    return;
  end if;
  if mail !~ '^[^@]+@mitsgwl[.]ac[.]in$' then
    raise exception 'Use a verified MITS student or faculty Google account' using errcode='42501';
  end if;
  lp := split_part(mail,'@',1);
  if lp !~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$' then
    update public.profiles set role=case when existing_role='super_admin' then existing_role else 'student' end,
      branch_code=null, department=null, academic_year=null, enrollment_number=null where id=uid;
    return;
  end if;
  yy := substring(lp,1,2)::int;
  bc := substring(lp,3,2);
  dept := case bc
    when 'ad' then 'AI & Data Science' when 'ai' then 'Artificial Intelligence'
    when 'am' then 'AI & Machine Learning' when 'cb' then 'CS & Business Systems'
    when 'cd' then 'CS & Design' when 'ce' then 'Civil Engineering' when 'cm' then 'Chemical Engineering'
    when 'cs' then 'Computer Science & Engg' when 'ec' then 'Electronics & Communication'
    when 'ee' then 'Electrical Engineering' when 'el' then 'Electronics Engineering'
    when 'et' then 'Electronics & Telecommunication' when 'io' then 'Internet of Things (IoT)'
    when 'ir' then 'IT (AI & Robotics)' when 'it' then 'Information Technology'
    when 'mc' then 'Mathematics & Computing' when 'me' then 'Mechanical Engineering'
    when 'tc' then 'CS & Technology' when 'ar' then 'Architecture (B.Arch)' end;
  if dept is null then raise exception 'Unknown branch code in MITS student email'; end if;
  start_year := extract(year from local_today)::int - case when extract(month from local_today)<7 then 1 else 0 end;
  study_year := start_year - (2000+yy) + 1;
  generated_enrollment := 'BT'||upper(bc)||lpad(yy::text,2,'0')||'O1'||right(lp,3);
  update public.profiles set role=case when existing_role='super_admin' then existing_role else 'student' end,
    branch_code=upper(bc), department=dept, academic_year=study_year,
    enrollment_number=generated_enrollment where id=uid;

  -- Historical account that could not complete the original name setup.
  if mail='25mc1ri115@mitsgwl.ac.in' then
    insert into public.identity_records(user_id,real_name) values(uid,'Ritesh Rajak')
      on conflict(user_id) do update set real_name='Ritesh Rajak';
    update public.profiles set profile_completed=true where id=uid;
  end if;
exception when unique_violation then
  raise exception 'Enrollment number already assigned to another account';
end;
$$;

-- Backfill existing eligible student accounts using the same exact pattern.
update public.profiles p set enrollment_number =
  'BT'||upper(substring(split_part(lower(u.email),'@',1),3,2))||
  substring(split_part(lower(u.email),'@',1),1,2)||'O1'||
  right(split_part(lower(u.email),'@',1),3),
  academic_year = case when p.role in ('student','super_admin') then
    extract(year from (now() at time zone 'Asia/Kolkata'))::int
      - case when extract(month from (now() at time zone 'Asia/Kolkata'))<7 then 1 else 0 end
      - (2000+substring(split_part(lower(u.email),'@',1),1,2)::int) + 1
    else p.academic_year end
from auth.users u
where u.id=p.id and p.role in ('student','faculty','super_admin')
  and lower(u.email) ~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}@mitsgwl[.]ac[.]in$';

-- Lock the one requested legacy identity on every insert/update and seed it now.
create or replace function public.keep_ritesh_identity_fixed()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from auth.users u where u.id=new.user_id and lower(u.email)='25mc1ri115@mitsgwl.ac.in') then
    new.real_name := 'Ritesh Rajak';
  end if;
  return new;
end;
$$;
drop trigger if exists keep_ritesh_identity_fixed on public.identity_records;
create trigger keep_ritesh_identity_fixed before insert or update of real_name
  on public.identity_records for each row execute function public.keep_ritesh_identity_fixed();
insert into public.identity_records(user_id,real_name)
select id,'Ritesh Rajak' from auth.users where lower(email)='25mc1ri115@mitsgwl.ac.in'
on conflict(user_id) do update set real_name='Ritesh Rajak';
update public.profiles p set profile_completed=true
from auth.users u where u.id=p.id and lower(u.email)='25mc1ri115@mitsgwl.ac.in';

create or replace function public.is_super_admin(p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.profiles p where p.id=p_uid and p.role='super_admin');
$$;

-- Add a distinct moderator assignment for each room and campus mode. Existing
-- assignments are classified as Official, matching their original workflow.
alter table public.room_moderators add column if not exists room_mode text not null default 'official';
alter table public.room_moderators drop constraint if exists room_moderators_room_mode_check;
alter table public.room_moderators add constraint room_moderators_room_mode_check
  check(room_mode in ('official','unofficial'));
alter table public.room_moderators drop constraint if exists room_moderators_room_id_student_id_key;
create unique index if not exists room_moderators_room_mode_student_unique
  on public.room_moderators(room_id,room_mode,student_id);
alter table public.room_moderator_audit add column if not exists room_mode text not null default 'official';

create or replace function public.is_active_room_moderator(p_room text,p_mode text,p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.room_moderators m join public.profiles p on p.id=m.student_id
    where m.room_id=p_room and m.room_mode=p_mode and m.student_id=p_uid and p.role='student'
      and m.active and m.starts_at<=now() and (m.ends_at is null or m.ends_at>now()));
$$;
create or replace function public.is_active_room_moderator(p_room text,p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select public.is_active_room_moderator(p_room,'official',p_uid);
$$;

-- Remove both the previous two-argument RPC and any partially deployed
-- three-argument version before recreating the canonical return shape.
drop function if exists public.search_students(text,text,text);
drop function if exists public.search_students(text,text);
create function public.search_students(p_query text,p_branch_code text default null,p_mode text default 'official')
returns table(student_id uuid,student_name text,branch_code text,branch_name text,study_year int,enrollment_number text,roll_number text)
language plpgsql stable security definer set search_path='' as $$
declare q text:=btrim(coalesce(p_query,''));
begin
  if not (public.is_super_admin(auth.uid()) or (p_mode='official' and public.is_faculty(auth.uid()))) then
    raise exception 'You cannot search students for this campus mode' using errcode='42501';
  end if;
  if p_mode not in ('official','unofficial') then raise exception 'Unknown campus mode'; end if;
  if char_length(q)<3 then raise exception 'Enter at least 3 characters'; end if;
  return query select p.id,coalesce(nullif(btrim(i.real_name),''),'Student')::text,p.branch_code,p.department,p.academic_year,
    p.enrollment_number,right(split_part(lower(u.email),'@',1),3)::text
  from public.profiles p join auth.users u on u.id=p.id
  left join public.identity_records i on i.user_id=p.id
  where p.role='student' and p.enrollment_number is not null
    and (p_branch_code is null or upper(p.branch_code)=upper(p_branch_code))
    and (i.real_name ilike '%'||q||'%' or p.enrollment_number ilike '%'||q||'%'
      or right(split_part(lower(u.email),'@',1),3) ilike '%'||q||'%')
  order by i.real_name limit 20;
end;
$$;

create or replace function public.list_moderation_rooms(p_mode text)
returns table(room_id text,room_name text)
language plpgsql stable security definer set search_path='' as $$
begin
  if p_mode not in ('official','unofficial') then raise exception 'Unknown campus mode'; end if;
  if not (public.is_super_admin(auth.uid()) or (p_mode='official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator management access required' using errcode='42501';
  end if;
  return query select r.id,r.name from public.rooms r
    where (p_mode='official' and public.is_official_room(r.id))
      or (p_mode='unofficial' and r.id not in ('official-live') and r.id not like 'dept-%')
    order by r.name;
end;
$$;

drop function if exists public.assign_room_moderator(text,uuid,timestamptz);
drop function if exists public.assign_room_moderator(text,uuid,timestamptz,text);
create function public.assign_room_moderator(p_room_id text,p_student_id uuid,p_ends_at timestamptz default null,p_mode text default 'official')
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (public.is_super_admin(auth.uid()) or (p_mode='official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator assignment access required' using errcode='42501';
  end if;
  if p_mode not in ('official','unofficial') or not exists(select 1 from public.rooms r where r.id=p_room_id) then raise exception 'Invalid room'; end if;
  if p_mode='official' and not public.is_official_room(p_room_id) then raise exception 'Choose an Official room'; end if;
  if p_mode='unofficial' and (p_room_id='official-live' or p_room_id like 'dept-%') then raise exception 'Choose an Unofficial room'; end if;
  if not exists(select 1 from public.profiles p where p.id=p_student_id and p.role='student') then raise exception 'Only students can moderate'; end if;
  if p_ends_at is not null and p_ends_at<=now() then raise exception 'End date must be in the future'; end if;
  insert into public.room_moderators(room_id,room_mode,student_id,assigned_by,ends_at)
    values(p_room_id,p_mode,p_student_id,auth.uid(),p_ends_at)
  on conflict(room_id,room_mode,student_id) do update set assigned_by=excluded.assigned_by,starts_at=now(),ends_at=excluded.ends_at,active=true;
  insert into public.room_moderator_audit(room_id,room_mode,student_id,changed_by,action,ends_at)
    values(p_room_id,p_mode,p_student_id,auth.uid(),'assigned',p_ends_at);
end;
$$;

drop function if exists public.remove_room_moderator(text,uuid);
drop function if exists public.remove_room_moderator(text,uuid,text);
create function public.remove_room_moderator(p_room_id text,p_student_id uuid,p_mode text default 'official')
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (public.is_super_admin(auth.uid()) or (p_mode='official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator removal access required' using errcode='42501';
  end if;
  update public.room_moderators set active=false where room_id=p_room_id and room_mode=p_mode and student_id=p_student_id and active;
  if found then
    insert into public.room_moderator_audit(room_id,room_mode,student_id,changed_by,action)
      values(p_room_id,p_mode,p_student_id,auth.uid(),'removed');
  end if;
end;
$$;

drop function if exists public.list_room_moderators(text);
drop function if exists public.list_room_moderators(text,text);
create function public.list_room_moderators(p_room_id text,p_mode text default 'official')
returns table(student_id uuid,student_name text,branch_code text,branch_name text,study_year int,enrollment_number text,roll_number text,ends_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not (public.is_super_admin(auth.uid()) or (p_mode='official' and public.is_faculty(auth.uid()))) then
    raise exception 'Moderator list access required' using errcode='42501';
  end if;
  return query select p.id,coalesce(nullif(btrim(i.real_name),''),'Student')::text,p.branch_code,p.department,p.academic_year,
    p.enrollment_number,right(split_part(lower(u.email),'@',1),3)::text,m.ends_at
  from public.room_moderators m join public.profiles p on p.id=m.student_id
  join auth.users u on u.id=p.id left join public.identity_records i on i.user_id=p.id
  where m.room_id=p_room_id and m.room_mode=p_mode and m.active and m.starts_at<=now() and (m.ends_at is null or m.ends_at>now())
  order by i.real_name;
end;
$$;

-- Identity data is returned only from this explicitly Official-only RPC.
drop function if exists public.get_official_profile_card(uuid);
create function public.get_official_profile_card(p_user_id uuid)
returns table(real_name text,branch_code text,branch_name text,study_year int,role text,enrollment_number text)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles me on me.id=u.id
    where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
      and (lower(u.email) ~ '^[^@]+@mitsgwl[.]ac[.]in$' or lower(u.email) ~ '^[^@]+@mitsgwalior[.]in$'
        or lower(u.email)='25mc1pr108@mitsgwl.ac.in') and me.role in ('student','faculty','super_admin')) then
    raise exception 'Official MITS profile access required' using errcode='42501';
  end if;
  return query select i.real_name,p.branch_code,p.department,p.academic_year,p.role,
    case when p.role in ('student','faculty','super_admin') then p.enrollment_number else null end
  from public.profiles p join public.identity_records i on i.user_id=p.id where p.id=p_user_id;
end;
$$;

-- Room mode is checked in the database; the legacy two-argument helper means
-- Official so older Official-only callers keep their existing behavior.
alter table public.posts add column if not exists approval_status text not null default 'approved';
alter table public.posts drop constraint if exists posts_approval_status_check;
alter table public.posts add constraint posts_approval_status_check check(approval_status in ('pending','approved','rejected'));
create index if not exists posts_room_approved_recent_idx on public.posts(room_id,created_at desc) where approval_status='approved';

create or replace function public.set_unofficial_post_approval_status()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if public.is_faculty_account(auth.uid()) then new.approval_status:='pending';
  else new.approval_status:='approved'; end if;
  return new;
end;
$$;
drop trigger if exists posts_set_approval_status on public.posts;
create trigger posts_set_approval_status before insert on public.posts
  for each row execute function public.set_unofficial_post_approval_status();

drop policy if exists "Faculty cannot use anonymous posts" on public.posts;
drop policy if exists "Faculty cannot use anonymous likes" on public.post_likes;
drop policy if exists "Faculty cannot use anonymous replies" on public.post_replies;
drop policy if exists "Faculty cannot access anonymous post images" on storage.objects;
drop policy if exists "Faculty cannot upload anonymous post images" on storage.objects;
drop policy if exists "Faculty cannot delete anonymous post images" on storage.objects;
drop policy if exists "Faculty cannot use Unofficial room chat" on public.room_messages;
drop policy if exists "Faculty receive only Official room broadcasts" on realtime.messages;

-- Faculty and students may use the anonymous experience. Direct table access
-- still exposes no author or identity columns to clients.
create or replace function public.is_approved_unofficial_post(p_post_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.posts p where p.id=p_post_id and p.approval_status='approved');
$$;
drop policy if exists "Users can insert their own anonymous likes" on public.post_likes;
create policy "Users can insert their own anonymous likes"
  on public.post_likes for insert to authenticated
  with check(user_id=auth.uid() and public.is_approved_unofficial_post(post_id));
drop policy if exists "Users can insert their own anonymous replies" on public.post_replies;
create policy "Users can insert their own anonymous replies"
  on public.post_replies as restrictive for insert to authenticated
  with check(author_id=auth.uid() and public.is_approved_unofficial_post(post_id));
drop policy if exists "Only synced MITS roles can write anonymous content" on public.posts;
create policy "Only synced MITS roles can write anonymous content"
  on public.posts as restrictive for insert to authenticated
  with check(exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')));
drop policy if exists "Only synced MITS roles can interact anonymously" on public.post_likes;
create policy "Only synced MITS roles can interact anonymously"
  on public.post_likes as restrictive for insert to authenticated
  with check(user_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin'))
    and public.is_approved_unofficial_post(post_id));
drop policy if exists "Only synced MITS roles can reply anonymously" on public.post_replies;
create policy "Only synced MITS roles can reply anonymously"
  on public.post_replies as restrictive for insert to authenticated
  with check(author_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')));
drop policy if exists "Faculty can upload owned anonymous post images" on storage.objects;
create policy "Faculty can upload owned anonymous post images"
  on storage.objects for insert to authenticated
  with check(bucket_id='campus-post-images' and owner_id=auth.uid()::text
    and name ~ '^posts/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$');

create or replace function public.get_room_feed_with_media_v3(p_room_id text)
returns table(post_id uuid,room_id text,author_username text,content text,created_at timestamptz,
  like_count bigint,liked_by_me boolean,image_path text,reply_count bigint,is_mine boolean,avatar_seed text)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')) then
    raise exception 'Unofficial account required' using errcode='42501';
  end if;
  return query select post.id,post.room_id,
    coalesce(nullif(btrim(profile.anon_username),''),'Anonymous')||case when public.is_active_room_moderator(post.room_id,'unofficial',post.author_id) then ' (Moderator)' else '' end,
    post.content,post.created_at,coalesce(ls.cnt,0)::bigint,coalesce(ls.mine,false),post.image_path,
    coalesce(rs.cnt,0)::bigint,post.author_id=auth.uid(),profile.avatar_seed::text
  from public.posts post left join public.profiles profile on profile.id=post.author_id
  left join lateral(select count(*)::bigint cnt,coalesce(bool_or(l.user_id=auth.uid()),false) mine from public.post_likes l where l.post_id=post.id) ls on true
  left join lateral(select count(*)::bigint cnt from public.post_replies r where r.post_id=post.id) rs on true
  where post.room_id=p_room_id and post.approval_status='approved' order by post.created_at desc;
end;
$$;

create or replace function public.get_post_replies_with_avatars(p_post_id uuid)
returns table(author_username text,content text,created_at timestamptz,avatar_seed text)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not exists(select 1 from public.posts p where p.id=p_post_id and p.approval_status='approved') then
    raise exception 'Post is not available' using errcode='42501';
  end if;
  return query select coalesce(nullif(btrim(profile.anon_username),''),'Anonymous')||
    case when public.is_active_room_moderator(reply.room_id,'unofficial',reply.author_id) then ' (Moderator)' else '' end,
    reply.content,reply.created_at,profile.avatar_seed::text
  from public.post_replies reply left join public.profiles profile on profile.id=reply.author_id
  where reply.post_id=p_post_id order by reply.created_at asc;
end;
$$;

create or replace function public.get_anonymous_feed()
returns table(author_username text,content text,created_at timestamptz)
language sql stable security definer set search_path='' as $$
  select coalesce(nullif(btrim(p.anon_username),''),'Anonymous'),post.content,post.created_at
  from public.posts post left join public.profiles p on p.id=post.author_id
  where auth.uid() is not null and post.approval_status='approved' order by post.created_at desc;
$$;
create or replace function public.get_anonymous_feed_with_likes()
returns table(post_id uuid,author_username text,content text,created_at timestamptz,like_count bigint,liked_by_me boolean)
language sql stable security definer set search_path='' as $$
  select post.id,coalesce(nullif(btrim(p.anon_username),''),'Anonymous'),post.content,post.created_at,
    count(l.user_id)::bigint,coalesce(bool_or(l.user_id=auth.uid()),false)
  from public.posts post left join public.profiles p on p.id=post.author_id left join public.post_likes l on l.post_id=post.id
  where auth.uid() is not null and post.approval_status='approved'
  group by post.id,p.anon_username order by post.created_at desc;
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

-- Official profile number is only returned by the Official profile-card RPC.
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
  order by post.created_at desc limit greatest(1,least(coalesce(p_limit,50),100));
end;
$$;

create or replace function public.create_official_post(p_post_id uuid,p_content text,p_image_path text,p_department_code text,p_room_id text)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); clean text:=btrim(coalesce(p_content,''));
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_room_id='official-live' or not public.is_official_room(p_room_id) then raise exception 'Choose an Official posting room'; end if;
  if p_room_id like 'dept-%' and lower(coalesce(p_department_code,''))<>substring(p_room_id from 6) then raise exception 'Department and room do not match'; end if;
  if p_room_id='general' and p_department_code is not null then raise exception 'Campus-wide posts cannot select a department'; end if;
  if not (public.is_faculty(uid) or public.is_super_admin(uid) or public.is_active_room_moderator(p_room_id,'official',uid)) then
    raise exception 'Only faculty, Super Admin or this room moderator can publish' using errcode='42501';
  end if;
  if char_length(clean)>2000 or (clean='' and p_image_path is null) then raise exception 'Add a caption or image'; end if;
  if p_image_path is not null and p_image_path !~ ('^'||uid::text||'/'||p_room_id||'/posts/'||p_post_id::text||'/'||p_post_id::text||'[.](jpg|jpeg|png|webp)$') then raise exception 'Invalid official image path'; end if;
  insert into public.official_posts(id,author_id,department_code,content,image_path,room_id)
    values(p_post_id,uid,p_department_code,clean,p_image_path,p_room_id);
end;
$$;

-- Profile history RPCs were previously wrapped to deny faculty. They now read
-- only the caller's own anonymous activity, matching the faculty Unofficial profile.
do $$
declare fn record; definition text; changed text;
begin
  for fn in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('get_my_unofficial_profile_stats','get_my_unofficial_profile_activity')
  loop
    definition:=pg_get_functiondef(fn.oid);
    changed:=replace(definition,'if caller_id is null or public.is_faculty_account(caller_id) then','if caller_id is null then');
    changed:=replace(changed,'if auth.uid() is null or public.is_faculty_account(auth.uid()) then','if auth.uid() is null then');
    changed:=replace(changed,'where auth.uid() is not null and not public.is_faculty_account(auth.uid())','where auth.uid() is not null');
    if changed<>definition then execute changed; end if;
  end loop;
end;
$$;

do $$
declare fn record; definition text; changed text;
begin
  for fn in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('get_room_feed_with_media','get_room_feed_with_media_v2','get_post_replies','delete_my_post')
  loop
    definition:=pg_get_functiondef(fn.oid);
    changed:=replace(definition,'if caller_id is null or public.is_faculty_account(caller_id) then','if caller_id is null then');
    changed:=replace(changed,'if auth.uid() is null or public.is_faculty_account(auth.uid()) then','if auth.uid() is null then');
    changed:=replace(changed,'where auth.uid() is not null and not public.is_faculty_account(auth.uid())','where auth.uid() is not null');
    if changed<>definition then execute changed; end if;
  end loop;
end;
$$;

-- This app's per-room live-chat RPCs and realtime payloads use the same mode
-- aware moderator check. Anonymous messages still carry no user ID.
create or replace function public.get_room_chat_messages(p_room_id text,p_mode text,p_limit integer default 100)
returns table(message_id uuid,room_id text,author_id uuid,author_username text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.can_use_room_chat(p_room_id,p_mode,auth.uid()) then raise exception 'You cannot read this room chat' using errcode='42501'; end if;
  if not exists(select 1 from public.room_sessions s where s.room_id=p_room_id and s.room_mode=p_mode and s.user_id=auth.uid() and s.left_at is null) then raise exception 'Join the room chat first' using errcode='42501'; end if;
  if exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now()) then raise exception 'You are blocked from this room' using errcode='42501'; end if;
  return query select m.id,m.room_id,case when p_mode='official' then m.sender_id else null::uuid end,
    (case when p_mode='official' then coalesce(nullif(btrim(i.real_name),''),'Student')||' · '||
      case when p.role='faculty' then 'Faculty'||case when p.branch_code is null then '' else ' · '||p.branch_code end
      else coalesce(p.branch_code,'')||' · '||case when p.academic_year>4 then 'Alumni' when p.academic_year=1 then '1st' when p.academic_year=2 then '2nd' when p.academic_year=3 then '3rd' when p.academic_year=4 then '4th' else 'Year unavailable' end end
     else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end||
     case when public.is_active_room_moderator(p_room_id,p_mode,m.sender_id) then ' (Moderator)' else '' end)::text,
    m.content,m.created_at
  from (select x.id,x.room_id,x.sender_id,x.content,x.created_at from public.room_messages x
    where x.room_id=p_room_id and x.room_mode=p_mode and x.room_id not in ('general','official-live') and x.created_at>=now()-interval '7 days'
    order by x.created_at desc limit greatest(1,least(coalesce(p_limit,100),200))) m
  join public.profiles p on p.id=m.sender_id left join public.identity_records i on i.user_id=m.sender_id order by m.created_at asc;
end;
$$;

create or replace function public.can_use_room_chat(p_room_id text,p_mode text,p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select case when p_user_id is null or p_mode not in ('official','unofficial') then false
    when p_mode='official' then public.is_official_room(p_room_id) and exists(select 1 from public.profiles p where p.id=p_user_id and p.role in ('student','faculty','super_admin'))
    else p_room_id<>'official-live' and p_room_id not like 'dept-%' and exists(select 1 from public.profiles p where p.id=p_user_id and p.role in ('student','faculty','super_admin')) end;
$$;

-- Faculty have anonymous access to the Unofficial always-on stream as well.
create or replace function public.can_receive_room_chat_broadcast(p_topic text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); v_mode text:=split_part(p_topic,':',2); v_room text:=split_part(p_topic,':',3);
begin
  if uid is null then return false; end if;
  if p_topic='room:official-live' then
    return public.can_use_room_chat('official-live','official',uid)
      and exists(select 1 from public.room_sessions s where s.room_id='official-live' and s.room_mode='official' and s.user_id=uid and s.left_at is null)
      and not exists(select 1 from public.room_blocks b where b.room_id='official-live' and b.user_id=uid and b.ends_at>now());
  end if;
  if p_topic='room:general' then
    return exists(select 1 from public.profiles p where p.id=uid and p.role in ('student','faculty','super_admin'));
  end if;
  if split_part(p_topic,':',1)<>'room' or v_mode not in ('official','unofficial') or v_room='' then return false; end if;
  return public.can_use_room_chat(v_room,v_mode,uid)
    and exists(select 1 from public.room_sessions s where s.room_id=v_room and s.room_mode=v_mode and s.user_id=uid and s.left_at is null)
    and not exists(select 1 from public.room_blocks b where b.room_id=v_room and b.user_id=uid and b.ends_at>now());
end;
$$;
drop policy if exists "Authenticated users can receive room broadcasts" on realtime.messages;
create policy "Authenticated users can receive room broadcasts"
  on realtime.messages for select to authenticated
  using(extension='broadcast' and public.can_receive_room_chat_broadcast(realtime.topic()));

create or replace function public.get_room_messages(p_room_id text,p_limit integer default 50)
returns table(message_id uuid,room_id text,author_id uuid,author_username text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare joined timestamptz; mode_value text:=case when p_room_id='official-live' then 'official' else 'unofficial' end;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')) then
    raise exception 'MITS account required' using errcode='42501';
  end if;
  if p_room_id='official-live' then
    select s.joined_at into joined from public.room_sessions s where s.room_id=p_room_id and s.room_mode='official' and s.user_id=auth.uid() and s.left_at is null order by s.joined_at desc limit 1;
    if joined is null or exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now()) then
      raise exception 'Join room to read messages' using errcode='42501';
    end if;
  end if;
  return query select m.id,m.room_id,case when mode_value='official' then m.sender_id else null::uuid end,
    (case when mode_value='official' then
      coalesce(nullif(btrim(i.real_name),''),'Student')||' · '||case when p.role='faculty' then 'Faculty'||case when p.branch_code is null then '' else ' · '||p.branch_code end
        else coalesce(p.branch_code,'')||' · '||case when p.academic_year>4 then 'Alumni' when p.academic_year=1 then '1st' when p.academic_year=2 then '2nd' when p.academic_year=3 then '3rd' when p.academic_year=4 then '4th' else 'Year unavailable' end end
      else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end||
      case when public.is_active_room_moderator(p_room_id,mode_value,m.sender_id) then ' (Moderator)' else '' end)::text,
    m.content,m.created_at
  from (select x.id,x.room_id,x.sender_id,x.content,x.created_at from public.room_messages x where x.room_id=p_room_id and x.room_mode=mode_value
    and (p_room_id<>'official-live' or (x.created_at>=joined and x.created_at<=now())) order by x.created_at desc limit greatest(1,least(coalesce(p_limit,50),100))) m
  left join public.profiles p on p.id=m.sender_id left join public.identity_records i on i.user_id=m.sender_id order by m.created_at asc;
end;
$$;

drop policy if exists "Users can send messages as themselves" on public.room_messages;
create policy "Users can send messages as themselves" on public.room_messages for insert to authenticated
with check(sender_id=auth.uid() and ((room_id='official-live' and room_mode='official' and exists(select 1 from public.room_sessions s where s.room_id=room_messages.room_id and s.room_mode=room_messages.room_mode and s.user_id=auth.uid() and s.left_at is null))
  or (room_id='general' and room_mode='unofficial' and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin')))
  or (room_id not in ('general','official-live') and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('student','faculty','super_admin'))
    and exists(select 1 from public.room_sessions s where s.room_id=room_messages.room_id and s.room_mode=room_messages.room_mode and s.user_id=auth.uid() and s.left_at is null))));

create or replace function public.broadcast_room_message()
returns trigger language plpgsql security definer set search_path='' as $$
declare display_name text; branch text; year_no int; member_role text; payload jsonb; topic text;
begin
  if new.room_id in ('general','official-live') then
    topic:='room:'||new.room_id; new.room_mode:=case when new.room_id='official-live' then 'official' else 'unofficial' end;
  else topic:='room:'||new.room_mode||':'||new.room_id; end if;
  if new.room_mode='official' then
    select coalesce(nullif(btrim(i.real_name),''),'Student'),p.branch_code,p.academic_year,p.role into display_name,branch,year_no,member_role
      from public.profiles p left join public.identity_records i on i.user_id=p.id where p.id=new.sender_id;
    display_name:=display_name||' · '||case when member_role='faculty' then 'Faculty'||case when branch is null then '' else ' · '||branch end
      else coalesce(branch,'')||' · '||case when year_no>4 then 'Alumni' when year_no=1 then '1st' when year_no=2 then '2nd' when year_no=3 then '3rd' when year_no=4 then '4th' else 'Year unavailable' end end;
  else select coalesce(nullif(btrim(p.anon_username),''),'Anonymous') into display_name from public.profiles p where p.id=new.sender_id; end if;
  if public.is_active_room_moderator(new.room_id,new.room_mode,new.sender_id) then display_name:=display_name||' (Moderator)'; end if;
  payload:=jsonb_build_object('message_id',new.id,'room_id',new.room_id,'room_mode',new.room_mode,'author_username',coalesce(display_name,'Anonymous'),'content',new.content,'created_at',new.created_at);
  if new.room_mode='official' then payload:=payload||jsonb_build_object('author_id',new.sender_id); end if;
  perform realtime.send(payload,'new_message',topic,true); return new;
end;
$$;

revoke all on function public.sync_my_college_profile(),public.is_super_admin(uuid),public.is_active_room_moderator(text,text,uuid),
  public.search_students(text,text,text),public.list_moderation_rooms(text),public.assign_room_moderator(text,uuid,timestamptz,text),
  public.remove_room_moderator(text,uuid,text),public.list_room_moderators(text,text),public.get_official_profile_card(uuid),
  public.get_room_feed_with_media_v3(text),public.get_post_replies_with_avatars(uuid),public.get_pending_unofficial_room_posts(text),
  public.review_unofficial_room_post(uuid,text),public.get_room_chat_messages(text,text,integer),public.can_receive_room_chat_broadcast(text),public.get_room_messages(text,integer),public.create_official_post(uuid,text,text,text,text),public.is_approved_unofficial_post(uuid)
  from public,anon,authenticated;
grant execute on function public.sync_my_college_profile(),public.is_active_room_moderator(text,text,uuid),
  public.search_students(text,text,text),public.list_moderation_rooms(text),public.assign_room_moderator(text,uuid,timestamptz,text),
  public.remove_room_moderator(text,uuid,text),public.list_room_moderators(text,text),public.get_official_profile_card(uuid),
  public.get_room_feed_with_media_v3(text),public.get_post_replies_with_avatars(uuid),public.get_pending_unofficial_room_posts(text),
  public.review_unofficial_room_post(uuid,text),public.get_room_chat_messages(text,text,integer),public.can_receive_room_chat_broadcast(text),public.get_room_messages(text,integer),public.create_official_post(uuid,text,text,text,text),public.is_approved_unofficial_post(uuid)
  to authenticated;

notify pgrst,'reload schema';
commit;
