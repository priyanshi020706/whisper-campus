begin;

-- The Unofficial home feed is a public campus-wide conversation. Posts there
-- publish immediately; room-specific Unofficial posts keep moderator review.
create or replace function public.set_unofficial_post_approval_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.room_id = 'general'
      or public.is_faculty_account(auth.uid())
      or public.is_super_admin(auth.uid())
      or public.is_active_room_moderator(new.room_id, 'unofficial', auth.uid()) then
    new.approval_status := 'approved';
  else
    new.approval_status := 'pending';
  end if;
  return new;
end;
$$;

-- Publish any existing pending homepage posts under the new rule too.
update public.posts
set approval_status = 'approved'
where room_id = 'general' and approval_status = 'pending';

-- One review queue per campus mode: Super Admin sees every room; a student
-- moderator sees only rooms where their current assignment is active.
create or replace function public.get_pending_room_reviews(p_mode text)
returns table(
  campus_mode text,
  post_id uuid,
  room_id text,
  room_name text,
  author_label text,
  content text,
  created_at timestamptz,
  image_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or p_mode is null or p_mode not in ('official', 'unofficial') then
    raise exception 'Sign in and choose a campus mode' using errcode = '42501';
  end if;

  if p_mode = 'official' then
    if not public.is_eligible_official_user(uid) then
      raise exception 'Verified Official MITS account required' using errcode = '42501';
    end if;
    return query
    select 'official'::text, post.id, post.room_id,
      coalesce(room.name, post.room_id),
      coalesce(nullif(btrim(identity.real_name), ''), 'Student')::text,
      post.content, post.created_at, post.image_path
    from public.official_posts post
    left join public.rooms room on room.id = post.room_id
    left join public.identity_records identity on identity.user_id = post.author_id
    where post.approval_status = 'pending'
      and (public.is_super_admin(uid)
        or public.is_active_room_moderator(post.room_id, 'official', uid))
    order by post.created_at;
  else
    return query
    select 'unofficial'::text, post.id, post.room_id,
      coalesce(room.name, post.room_id),
      coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous')::text,
      post.content, post.created_at, post.image_path
    from public.posts post
    left join public.rooms room on room.id = post.room_id
    left join public.profiles profile on profile.id = post.author_id
    where post.approval_status = 'pending'
      and post.room_id <> 'general'
      and (public.is_super_admin(uid)
        or public.is_active_room_moderator(post.room_id, 'unofficial', uid))
    order by post.created_at;
  end if;
end;
$$;

create or replace function public.get_pending_room_review_count(p_mode text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.get_pending_room_reviews(p_mode);
$$;

revoke all on function public.get_pending_room_reviews(text),
  public.get_pending_room_review_count(text)
  from public, anon, authenticated;
grant execute on function public.get_pending_room_reviews(text),
  public.get_pending_room_review_count(text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
