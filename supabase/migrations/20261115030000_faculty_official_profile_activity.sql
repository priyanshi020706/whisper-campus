begin;

create or replace function public.get_my_official_profile_stats()
returns table(post_count bigint,like_count bigint,comment_count bigint)
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
 if uid is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS account required' using errcode='42501';
 end if;
 return query select
  (select count(*)::bigint from public.official_posts p where p.author_id=uid),
  (select count(*)::bigint from public.official_post_likes l join public.official_posts p on p.id=l.post_id where p.author_id=uid),
  (select count(*)::bigint from public.official_post_replies r where r.author_id=uid);
end $$;

create or replace function public.get_my_official_profile_activity(p_section text,p_limit integer default 100)
returns table(activity_type text,activity_id uuid,post_id uuid,department_code text,scope_name text,
 activity_content text,post_content text,post_author_name text,created_at timestamptz,
 like_count bigint,liked_by_me boolean,comment_count bigint,image_path text)
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); row_limit integer:=greatest(1,least(coalesce(p_limit,100),100));
begin
 if uid is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS account required' using errcode='42501';
 end if;
 if p_section not in('posts','comments') then raise exception 'Unknown profile section'; end if;
 if p_section='posts' then
  return query select 'post'::text,p.id,p.id,p.department_code,
   coalesce(nullif(r.name,''),'Campus-wide'),p.content,p.content,
   coalesce(nullif(i.real_name,''),'Student'),p.created_at,
   (select count(*)::bigint from public.official_post_likes l where l.post_id=p.id),
   exists(select 1 from public.official_post_likes l where l.post_id=p.id and l.user_id=uid),
   (select count(*)::bigint from public.official_post_replies x where x.post_id=p.id),p.image_path
  from public.official_posts p left join public.identity_records i on i.user_id=p.author_id
  left join public.rooms r on r.id=p.room_id
  where p.author_id=uid order by p.created_at desc limit row_limit;
 else
  return query select 'comment'::text,c.id,p.id,p.department_code,
   coalesce(nullif(r.name,''),'Campus-wide'),c.content,p.content,
   coalesce(nullif(i.real_name,''),'Student'),c.created_at,
   (select count(*)::bigint from public.official_post_likes l where l.post_id=p.id),
   exists(select 1 from public.official_post_likes l where l.post_id=p.id and l.user_id=uid),
   (select count(*)::bigint from public.official_post_replies x where x.post_id=p.id),p.image_path
  from public.official_post_replies c join public.official_posts p on p.id=c.post_id
  left join public.identity_records i on i.user_id=p.author_id left join public.rooms r on r.id=p.room_id
  where c.author_id=uid order by c.created_at desc limit row_limit;
 end if;
end $$;

create or replace function public.get_official_post_replies(p_post_id uuid)
returns table(author_name text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS account required' using errcode='42501';
 end if;
 return query select coalesce(nullif(btrim(i.real_name),''),'Student')::text,r.content,r.created_at
  from public.official_post_replies r join public.identity_records i on i.user_id=r.author_id
  where r.post_id=p_post_id order by r.created_at;
end $$;

create or replace function public.toggle_official_post_like(p_post_id uuid)
returns table(like_count bigint,liked_by_me boolean)
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
 if uid is null or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=uid and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')) then
  raise exception 'Official MITS account required' using errcode='42501';
 end if;
 if not exists(select 1 from public.official_posts where id=p_post_id) then raise exception 'Official post not found'; end if;
 if exists(select 1 from public.official_post_likes where post_id=p_post_id and user_id=uid) then
  delete from public.official_post_likes where post_id=p_post_id and user_id=uid;
 else
  insert into public.official_post_likes(post_id,user_id) values(p_post_id,uid) on conflict do nothing;
 end if;
 return query select count(*)::bigint,exists(select 1 from public.official_post_likes where post_id=p_post_id and user_id=uid)
  from public.official_post_likes where post_id=p_post_id;
end $$;

drop policy if exists "MITS students can like Official posts as themselves" on public.official_post_likes;
create policy "Official users can like posts as themselves" on public.official_post_likes for insert to authenticated
 with check(user_id=auth.uid() and exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')));
drop policy if exists "MITS students can remove their Official likes" on public.official_post_likes;
create policy "Official users can remove their likes" on public.official_post_likes for delete to authenticated
 using(user_id=auth.uid() and exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')));

drop policy if exists "MITS students can reply to Official posts as themselves" on public.official_post_replies;
create policy "Official users can reply as themselves" on public.official_post_replies for insert to authenticated
 with check(author_id=auth.uid() and exists(select 1 from auth.users u join public.profiles p on p.id=u.id
  where u.id=auth.uid() and u.email_confirmed_at is not null and (u.raw_app_meta_data->'providers') ? 'google'
  and lower(u.email)~'(^priyanshisoni2706@gmail[.]com$|^[^@]+@(mitsgwl[.]ac[.]in|mitsgwalior[.]in)$)' and p.role in('student','faculty','super_admin')));

revoke all on function public.get_my_official_profile_stats(),public.get_my_official_profile_activity(text,integer),public.get_official_post_replies(uuid),public.toggle_official_post_like(uuid) from public,anon,authenticated;
grant execute on function public.get_my_official_profile_stats(),public.get_my_official_profile_activity(text,integer),public.get_official_post_replies(uuid),public.toggle_official_post_like(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
