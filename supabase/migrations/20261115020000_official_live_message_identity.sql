begin;
drop function if exists public.get_room_messages(text,integer);
create function public.get_room_messages(p_room_id text,p_limit integer default 50)
returns table(message_id uuid,room_id text,author_id uuid,author_username text,content text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$

begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_room_id='official-live' and (not exists(select 1 from public.room_sessions s where s.room_id=p_room_id and s.user_id=auth.uid())
  or exists(select 1 from public.room_blocks b where b.room_id=p_room_id and b.user_id=auth.uid() and b.ends_at>now())) then
  raise exception 'Join room to read messages' using errcode='42501';
 end if;
 return query select m.id,m.room_id,m.sender_id,
  case when p_room_id='official-live' then coalesce(nullif(btrim(i.real_name),''),'Student')||case
    when p.branch_code is null then ' · Faculty' else ' · '||p.branch_code||' · '||case
     when p.academic_year>4 then 'Alumni' when p.academic_year=1 then '1st' when p.academic_year=2 then '2nd'
     when p.academic_year=3 then '3rd' else coalesce(p.academic_year::text,'') end end
   else coalesce(nullif(btrim(p.anon_username),''),'Anonymous') end::text,
  m.content,m.created_at
 from (select x.id,x.room_id,x.sender_id,x.content,x.created_at from public.room_messages x
   where x.room_id=p_room_id and (p_room_id<>'official-live' or exists(select 1 from public.room_sessions s where s.room_id=p_room_id and s.user_id=auth.uid() and x.created_at>=s.joined_at and x.created_at<=coalesce(s.left_at,now())))
   order by x.created_at desc limit greatest(1,least(coalesce(p_limit,50),100))) m
 left join public.profiles p on p.id=m.sender_id left join public.identity_records i on i.user_id=m.sender_id
 order by m.created_at asc;
end $$;
revoke all on function public.get_room_messages(text,integer) from public,anon,authenticated;
grant execute on function public.get_room_messages(text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
