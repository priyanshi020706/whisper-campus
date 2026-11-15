begin;

alter table public.profiles add column if not exists branch_code text;
alter table public.profiles add column if not exists enrollment_number text;
create unique index if not exists profiles_enrollment_number_unique
  on public.profiles(enrollment_number) where enrollment_number is not null;
update public.profiles set role='faculty' where role='teacher';

create or replace function public.sync_my_college_profile()
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); mail text; lp text; yy int; bc text; dept text; start_year int; study_year int; existing_role text;
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select lower(u.email) into mail from auth.users u where u.id=uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google';
 if mail is null then raise exception 'Verified Google account required' using errcode='42501'; end if;
 select p.role into existing_role from public.profiles p where p.id=uid;
 if mail ~ '(^priyanshisoni2706@gmail[.]com$|^[^@]+@mitsgwalior[.]in$)' then
  update public.profiles set role=case when existing_role='super_admin' then existing_role else 'faculty' end,branch_code=null,department=null,academic_year=null,enrollment_number=null where id=uid;
  return;
 end if;
 if mail !~ '^[^@]+@mitsgwl[.]ac[.]in$' then raise exception 'Use a MITS student or faculty Google account' using errcode='42501'; end if;
 lp:=split_part(mail,'@',1);
 if lp !~ '^[0-9]{2}[a-z]{2}[0-9][a-z]{2}[0-9]{3}$' then
  update public.profiles set role=case when existing_role='super_admin' then existing_role else 'student' end,branch_code=null,department=null,academic_year=null,enrollment_number=null where id=uid;
  return;
 end if;
 yy:=substring(lp,1,2)::int; bc:=substring(lp,3,2);
 dept:=case bc
  when 'ad' then 'AI & Data Science' when 'ai' then 'Artificial Intelligence' when 'am' then 'AI & Machine Learning'
  when 'cb' then 'CS & Business Systems' when 'cd' then 'CS & Design' when 'ce' then 'Civil Engineering'
  when 'cm' then 'Chemical Engineering' when 'cs' then 'Computer Science & Engg' when 'ec' then 'Electronics & Communication'
  when 'ee' then 'Electrical Engineering' when 'el' then 'Electronics Engineering' when 'et' then 'Electronics & Telecommunication'
  when 'io' then 'Internet of Things (IoT)' when 'ir' then 'IT (AI & Robotics)' when 'it' then 'Information Technology'
  when 'mc' then 'Mathematics & Computing' when 'me' then 'Mechanical Engineering' when 'tc' then 'CS & Technology'
  when 'ar' then 'Architecture (B.Arch)' end;
 if dept is null then raise exception 'Unknown branch code in MITS email'; end if;
 start_year:=extract(year from current_date)::int - case when extract(month from current_date)<7 then 1 else 0 end;
 study_year:=start_year-(2000+yy)+1;
 update public.profiles set role=case when existing_role='super_admin' then existing_role else 'student' end,
  branch_code=upper(bc),department=dept,academic_year=study_year,
  enrollment_number='BT'||upper(bc)||lpad(yy::text,2,'0')||'O1'||right(lp,3) where id=uid;
exception when unique_violation then raise exception 'Enrollment number already assigned to another account';
end $$;

-- Only profile setup fields remain client-writable; identity and academic fields are server controlled.
revoke update on public.profiles from authenticated;
grant update(bio,avatar_seed,profile_completed) on public.profiles to authenticated;

create or replace function public.is_faculty(p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p join auth.users u on u.id=p.id
  where p.id=p_uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
   and ((p.role='faculty' and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@mitsgwalior[.]in$)')
     or (p.role='super_admin' and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)')))
$$;
create or replace function public.is_active_room_moderator(p_room text,p_uid uuid default auth.uid())
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 return exists(select 1 from public.room_moderators m join public.profiles p on p.id=m.student_id
  where m.room_id=p_room and m.student_id=p_uid and p.role='student' and m.active and m.starts_at<=now()
  and (m.ends_at is null or m.ends_at>now()));
end $$;

create table public.room_moderators(
 room_id text not null references public.rooms(id) on delete cascade,
 student_id uuid not null references auth.users(id) on delete cascade,
 assigned_by uuid not null references auth.users(id),
 starts_at timestamptz not null default now(), ends_at timestamptz,
 active boolean not null default true, created_at timestamptz not null default now(),
 unique(room_id,student_id), check(ends_at is null or ends_at>starts_at));
create index room_moderators_active_idx on public.room_moderators(room_id,student_id,ends_at) where active;
alter table public.room_moderators enable row level security;
revoke all on public.room_moderators from public,anon,authenticated;

create table public.room_moderator_audit(
 id bigint generated always as identity primary key,room_id text not null,student_id uuid not null,
 changed_by uuid not null,action text not null check(action in('assigned','removed')),ends_at timestamptz,
 created_at timestamptz not null default now());
alter table public.room_moderator_audit enable row level security;
revoke all on public.room_moderator_audit from public,anon,authenticated;

create or replace function public.search_students(p_query text,p_branch_code text default null)
returns table(student_id uuid,student_name text,branch_code text,branch_name text,study_year int,enrollment_number text)
language plpgsql stable security definer set search_path='' as $$
declare q text:=btrim(coalesce(p_query,''));
begin
 if not public.is_faculty(auth.uid()) then raise exception 'Faculty access required' using errcode='42501'; end if;
 if char_length(q)<3 then raise exception 'Enter at least 3 characters'; end if;
 return query select p.id,coalesce(nullif(btrim(i.real_name),''),'Student'),p.branch_code,p.department,p.academic_year,p.enrollment_number
  from public.profiles p join public.identity_records i on i.user_id=p.id
  where p.role='student' and p.enrollment_number is not null
   and (p_branch_code is null or upper(p.branch_code)=upper(p_branch_code))
   and (i.real_name ilike '%'||q||'%' or p.enrollment_number ilike '%'||q||'%' or right(p.enrollment_number,3) ilike '%'||q||'%')
  order by i.real_name limit 20;
end $$;
create or replace function public.assign_room_moderator(p_room_id text,p_student_id uuid,p_ends_at timestamptz default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_faculty(auth.uid()) then raise exception 'Faculty access required' using errcode='42501'; end if;
 if not exists(select 1 from public.profiles where id=p_student_id and role='student') then raise exception 'Only students can moderate'; end if;
 if p_ends_at is not null and p_ends_at<=now() then raise exception 'End date must be in the future'; end if;
 insert into public.room_moderators(room_id,student_id,assigned_by,ends_at) values(p_room_id,p_student_id,auth.uid(),p_ends_at)
  on conflict(room_id,student_id) do update set assigned_by=excluded.assigned_by,starts_at=now(),ends_at=excluded.ends_at,active=true;
 insert into public.room_moderator_audit(room_id,student_id,changed_by,action,ends_at) values(p_room_id,p_student_id,auth.uid(),'assigned',p_ends_at);
end $$;
create or replace function public.remove_room_moderator(p_room_id text,p_student_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_faculty(auth.uid()) then raise exception 'Faculty access required' using errcode='42501'; end if;
 update public.room_moderators set active=false where room_id=p_room_id and student_id=p_student_id;
 insert into public.room_moderator_audit(room_id,student_id,changed_by,action) values(p_room_id,p_student_id,auth.uid(),'removed');
end $$;
create or replace function public.list_room_moderators(p_room_id text)
returns table(student_id uuid,student_name text,branch_code text,branch_name text,study_year int,enrollment_number text,ends_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_faculty(auth.uid()) then raise exception 'Faculty access required' using errcode='42501'; end if;
 return query select p.id,coalesce(nullif(btrim(i.real_name),''),'Student'),p.branch_code,p.department,p.academic_year,p.enrollment_number,m.ends_at
  from public.room_moderators m join public.profiles p on p.id=m.student_id join public.identity_records i on i.user_id=p.id
  where m.room_id=p_room_id and m.active and m.starts_at<=now() and (m.ends_at is null or m.ends_at>now()) order by i.real_name;
end $$;

create table public.room_sessions(id uuid primary key default gen_random_uuid(),room_id text not null references public.rooms(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,joined_at timestamptz not null default now(),left_at timestamptz);
create index room_sessions_lookup on public.room_sessions(room_id,user_id,joined_at desc);
create unique index room_sessions_one_active on public.room_sessions(user_id,room_id) where left_at is null;
alter table public.room_sessions enable row level security;
grant select on public.room_sessions to authenticated;
create policy "Users can read their room sessions" on public.room_sessions for select to authenticated using(user_id=auth.uid());

create table public.room_blocks(room_id text not null references public.rooms(id) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,
 blocked_by uuid not null references auth.users(id),reason text not null,ends_at timestamptz not null,created_at timestamptz not null default now(),primary key(room_id,user_id));
alter table public.room_blocks enable row level security;
grant select on public.room_blocks to authenticated;
create policy "Users can read their room blocks" on public.room_blocks for select to authenticated using(user_id=auth.uid());

insert into public.rooms(id,name) values('official-live','Official Campus Live') on conflict(id) do nothing;

create or replace function public.join_room(p_room_id text)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); joined timestamptz;
begin
 if uid is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_room_id='official-live' and not exists(select 1 from public.profiles where id=uid and role in('student','faculty','super_admin')) then raise exception 'Official MITS account required' using errcode='42501'; end if;
 if exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=uid and b.ends_at>now()) then raise exception 'Blocked from room' using errcode='42501'; end if;
 update public.room_sessions set left_at=now() where room_id=p_room_id and user_id=uid and left_at is null;
 insert into public.room_sessions(room_id,user_id) values(p_room_id,uid) returning room_sessions.joined_at into joined;
 return joined;
end $$;
create or replace function public.leave_room(p_room_id text)
returns void language plpgsql security definer set search_path='' as $$
begin update public.room_sessions set left_at=now() where room_id=p_room_id and user_id=auth.uid() and left_at is null; end $$;
create or replace function public.get_my_room_block(p_room_id text)
returns table(reason text,ends_at timestamptz) language sql stable security definer set search_path='' as $$
 select b.reason,b.ends_at from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now()
$$;
create or replace function public.block_room_user(p_room_id text,p_user_id uuid,p_reason text)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare ends timestamptz:=now()+interval '3 days';
begin
 if not(public.is_faculty(auth.uid()) or public.is_active_room_moderator(p_room_id,auth.uid())) then raise exception 'Room moderator access required' using errcode='42501'; end if;
 if char_length(btrim(coalesce(p_reason,'')))=0 then raise exception 'A warning reason is required'; end if;
 if p_user_id=auth.uid() or public.is_faculty(p_user_id) or public.is_active_room_moderator(p_room_id,p_user_id) then raise exception 'Cannot block faculty or moderators'; end if;
 if not exists(select 1 from public.profiles where id=p_user_id and role='student') then raise exception 'Only students can be blocked'; end if;
 insert into public.room_blocks(room_id,user_id,blocked_by,reason,ends_at) values(p_room_id,p_user_id,auth.uid(),left(btrim(p_reason),500),ends)
  on conflict(room_id,user_id) do update set blocked_by=excluded.blocked_by,reason=excluded.reason,ends_at=excluded.ends_at,created_at=now();
 update public.room_sessions set left_at=now() where room_id=p_room_id and user_id=p_user_id and left_at is null;
 return ends;
end $$;

create or replace function public.create_room(p_room_id text,p_name text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='super_admin') then raise exception 'Super Admin access required' using errcode='42501'; end if;
 if p_room_id !~ '^[a-z0-9-]{2,40}$' or char_length(btrim(p_name)) not between 2 and 60 then raise exception 'Invalid room'; end if;
 insert into public.rooms(id,name) values(p_room_id,btrim(p_name));
end $$;

create or replace function public.save_my_identity(p_first_name text,p_last_name text,p_bio text default null)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); mail text; first_name text:=btrim(coalesce(p_first_name,'')); last_name text:=btrim(coalesce(p_last_name,'')); current_role text;
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 select lower(u.email) into mail from auth.users u where u.id=uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google';
 if mail is null or mail !~ '(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' then raise exception 'Verified MITS Google account required'; end if;
 select role into current_role from public.profiles where id=uid;
 if char_length(first_name) not between 1 and 60 or char_length(last_name) not between 1 and 60 then raise exception 'Enter first and last name'; end if;
 if mail ~ '@mitsgwl[.]ac[.]in$' and (select department from public.profiles where id=uid) is null then raise exception 'Could not verify student branch from email'; end if;
 if mail ~ '@mitsgwalior[.]in$' and current_role not in('faculty','super_admin') then raise exception 'Faculty role sync required'; end if;
 insert into public.identity_records(user_id,real_name) values(uid,first_name||' '||last_name)
  on conflict(user_id) do update set real_name=excluded.real_name;
 update public.profiles set profile_completed=true,bio=nullif(btrim(coalesce(p_bio,'')),'') where id=uid;
end $$;
create or replace function public.get_my_identity()
returns table(real_name text) language sql stable security definer set search_path='' as $$
 select i.real_name from public.identity_records i join public.profiles p on p.id=i.user_id join auth.users u on u.id=i.user_id
 where i.user_id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
 and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')
$$;

drop policy if exists "Users can send messages as themselves" on public.room_messages;
create policy "Users can send messages as themselves" on public.room_messages for insert to authenticated
 with check(sender_id=auth.uid() and (room_id<>'official-live' or (
 exists(select 1 from public.room_sessions s where s.room_id=room_messages.room_id and s.user_id=auth.uid() and s.left_at is null)
 and not exists(select 1 from public.room_blocks b where b.room_id=room_messages.room_id and b.user_id=auth.uid() and b.ends_at>now()))));
create policy "Official live history only for active session" on public.room_messages for select to authenticated
 using(room_id='official-live' and exists(select 1 from public.room_sessions s where s.room_id=room_messages.room_id and s.user_id=auth.uid() and room_messages.created_at>=s.joined_at and room_messages.created_at<=coalesce(s.left_at,now()))
 and not exists(select 1 from public.room_blocks b where b.room_id=room_messages.room_id and b.user_id=auth.uid() and b.ends_at>now()));

drop policy if exists "Authenticated users can receive room broadcasts" on realtime.messages;
create policy "Authenticated users can receive room broadcasts" on realtime.messages for select to authenticated
 using(extension='broadcast' and exists(select 1 from public.rooms r where realtime.topic()='room:'||r.id)
 and (realtime.topic()<>'room:official-live' or (exists(select 1 from public.room_sessions s where s.room_id='official-live' and s.user_id=auth.uid() and s.left_at is null)
 and not exists(select 1 from public.room_blocks b where b.room_id='official-live' and b.user_id=auth.uid() and b.ends_at>now()))));

-- Return history only to an active Official Live participant; other (anonymous) rooms retain current behavior.
create or replace function public.get_room_messages(p_room_id text,p_limit integer default 50)
returns table(message_id uuid,room_id text,author_username text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare joined timestamptz;
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_room_id='official-live' then
  select s.joined_at into joined from public.room_sessions s where s.room_id=p_room_id and s.user_id=auth.uid() and s.left_at is null order by s.joined_at desc limit 1;
  if joined is null or exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now()) then raise exception 'Join room to read messages' using errcode='42501'; end if;
 end if;
 return query select m.id,m.room_id,
  case when p_room_id='official-live' then coalesce(nullif(btrim(i.real_name),''),'Student')||' · '||coalesce(p.branch_code,'')||' · '||coalesce(p.academic_year::text,'Alumni')
   else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end::text,m.content,m.created_at
 from (select x.id,x.room_id,x.sender_id,x.content,x.created_at from public.room_messages x where x.room_id=p_room_id and (p_room_id<>'official-live' or x.created_at>=joined) order by x.created_at desc limit greatest(1,least(coalesce(p_limit,50),100))) m
 left join public.profiles p on p.id=m.sender_id left join public.identity_records i on i.user_id=m.sender_id order by m.created_at asc;
end $$;

create or replace function public.broadcast_room_message()
returns trigger language plpgsql security definer set search_path='' as $$
declare display_name text; branch text; year_no int;
begin
 if new.room_id='official-live' then
  select coalesce(nullif(btrim(i.real_name),''),'Student'),p.branch_code,p.academic_year into display_name,branch,year_no
  from public.profiles p left join public.identity_records i on i.user_id=p.id where p.id=new.sender_id;
  display_name:=display_name||case when branch is null then ' · Faculty' else ' · '||branch||' · '||case
   when year_no>4 then 'Alumni' when year_no=1 then '1st' when year_no=2 then '2nd' when year_no=3 then '3rd' else coalesce(year_no::text,'') end end;
 else
  select coalesce(nullif(btrim(p.anon_username),''),'Anonymous') into display_name from public.profiles p where p.id=new.sender_id;
 end if;
 perform realtime.send(jsonb_build_object('message_id',new.id,'room_id',new.room_id,'author_id',new.sender_id,'author_username',coalesce(display_name,'Anonymous'),'content',new.content,'created_at',new.created_at),'new_message','room:'||new.room_id,true);
 return new;
end $$;

revoke all on function public.sync_my_college_profile(),public.save_my_identity(text,text,text),public.get_my_identity(),public.is_faculty(uuid),public.is_active_room_moderator(text,uuid),public.search_students(text,text),public.assign_room_moderator(text,uuid,timestamptz),public.remove_room_moderator(text,uuid),public.list_room_moderators(text),public.join_room(text),public.leave_room(text),public.get_my_room_block(text),public.block_room_user(text,uuid,text),public.create_room(text,text) from public,anon,authenticated;
grant execute on function public.sync_my_college_profile(),public.save_my_identity(text,text,text),public.get_my_identity(),public.is_faculty(uuid),public.is_active_room_moderator(text,uuid),public.search_students(text,text),public.assign_room_moderator(text,uuid,timestamptz),public.remove_room_moderator(text,uuid),public.list_room_moderators(text),public.join_room(text),public.leave_room(text),public.get_my_room_block(text),public.block_room_user(text,uuid,text),public.create_room(text,text),public.get_room_messages(text,integer) to authenticated;
-- Room creation is exclusively performed through the Super Admin RPC.
revoke insert,update,delete on public.rooms from public,anon,authenticated;
-- Explicit Data API privileges for newly created public tables. RLS still limits
-- authenticated reads to the rows explicitly allowed above; service_role is trusted.
grant select on public.room_moderators to authenticated;
grant all on public.room_moderators,public.room_moderator_audit,public.room_sessions,public.room_blocks to service_role;
notify pgrst,'reload schema';
commit;
