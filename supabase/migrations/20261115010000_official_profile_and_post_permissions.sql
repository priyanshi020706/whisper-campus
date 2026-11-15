begin;

-- The enrollment number is reachable only through the official profile RPC.
revoke select on public.profiles from authenticated;
grant select(id,anon_username,avatar_seed,role,department,academic_year,bio,profile_completed)
 on public.profiles to authenticated;

create or replace function public.get_official_profile_card(p_user_id uuid)
returns table(real_name text,branch_code text,branch_name text,study_year int,enrollment_number text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS profile access required' using errcode='42501';
 end if;
 return query select i.real_name,p.branch_code,p.department,p.academic_year,p.enrollment_number
  from public.profiles p join public.identity_records i on i.user_id=p.id where p.id=p_user_id;
end $$;
revoke all on function public.get_official_profile_card(uuid) from public,anon,authenticated;
grant execute on function public.get_official_profile_card(uuid) to authenticated;

alter table public.official_posts add column if not exists room_id text not null default 'general';
create index if not exists official_posts_room_created_idx on public.official_posts(room_id,created_at desc);

drop function if exists public.create_official_post(uuid,text,text,text);
create function public.create_official_post(p_post_id uuid,p_content text,p_image_path text,p_department_code text,p_room_id text)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); clean text:=btrim(coalesce(p_content,''));
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_room_id !~ '^[a-z0-9-]{2,40}$' or not exists(select 1 from public.rooms r where r.id=p_room_id) then raise exception 'Unknown room'; end if;
 if not(public.is_faculty(uid) or public.is_active_room_moderator(p_room_id,uid)) then raise exception 'Only faculty or this room moderator can publish' using errcode='42501'; end if;
 if char_length(clean)>2000 or (clean='' and p_image_path is null) then raise exception 'Add a caption or image'; end if;
 if p_image_path is not null and p_image_path !~ ('^'||uid::text||'/'||p_room_id||'/posts/'||p_post_id::text||'/'||p_post_id::text||'[.](jpg|jpeg|png|webp)$') then raise exception 'Invalid official image path'; end if;
 insert into public.official_posts(id,author_id,department_code,content,image_path,room_id)
 values(p_post_id,uid,p_department_code,clean,p_image_path,p_room_id);
end $$;
revoke all on function public.create_official_post(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.create_official_post(uuid,text,text,text,text) to authenticated;

create or replace function public.get_official_posts_with_activity(p_department_code text,p_limit integer,p_room_id text)
returns table(post_id uuid,department_code text,author_name text,author_branch text,author_year integer,content text,created_at timestamptz,image_path text,is_mine boolean,like_count bigint,liked_by_me boolean,comment_count bigint)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS account required' using errcode='42501';
 end if;
 return query
 select post.id,post.department_code,coalesce(nullif(btrim(i.real_name),''),'Student')::text,
  coalesce(p.branch_code,''),p.academic_year,post.content,post.created_at,post.image_path,post.author_id=auth.uid(),
  (select count(*)::bigint from public.official_post_likes l where l.post_id=post.id),
  exists(select 1 from public.official_post_likes l where l.post_id=post.id and l.user_id=auth.uid()),
  (select count(*)::bigint from public.official_post_replies r where r.post_id=post.id)
 from public.official_posts post join public.identity_records i on i.user_id=post.author_id
 join public.profiles p on p.id=post.author_id
 where post.room_id=p_room_id and post.department_code is not distinct from p_department_code
 order by post.created_at desc limit greatest(1,least(coalesce(p_limit,50),100));
end $$;
revoke all on function public.get_official_posts_with_activity(text,integer,text) from public,anon,authenticated;
grant execute on function public.get_official_posts_with_activity(text,integer,text) to authenticated;

drop policy if exists "MITS users can upload their official post images" on storage.objects;
drop policy if exists "MITS users can read official post images" on storage.objects;
drop policy if exists "Users can remove their official post images" on storage.objects;
create policy "Official room posters can upload official post images" on storage.objects for insert to authenticated
with check(bucket_id='official-post-images' and (storage.foldername(name))[1]=(select auth.uid())::text
 and ((public.is_faculty(auth.uid())) or public.is_active_room_moderator((storage.foldername(name))[2],auth.uid())));
create policy "Official accounts can read official post images" on storage.objects for select to authenticated
using(bucket_id='official-post-images' and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('student','faculty','super_admin')));
create policy "Owners can remove their official post images" on storage.objects for delete to authenticated
using(bucket_id='official-post-images' and (storage.foldername(name))[1]=(select auth.uid())::text);

notify pgrst,'reload schema';
commit;
