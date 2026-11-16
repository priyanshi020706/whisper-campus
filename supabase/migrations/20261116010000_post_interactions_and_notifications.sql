begin;

-- A server-checked reply endpoint keeps feed and detail-page comments consistent.
create or replace function public.submit_post_reply(
  p_post_id uuid,
  p_content text,
  p_mode text
)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  clean text := btrim(coalesce(p_content, ''));
begin
  if uid is null then raise exception 'Sign in to comment' using errcode = '42501'; end if;
  if p_mode not in ('official', 'unofficial') then raise exception 'Unknown campus side'; end if;
  if char_length(clean) not between 1 and 2000 then
    raise exception 'Comments must contain 1 to 2000 characters';
  end if;

  if p_mode = 'official' then
    if not public.is_eligible_official_user(uid) then
      raise exception 'Verified Official MITS Google account required' using errcode = '42501';
    end if;
    if not exists (select 1 from public.official_posts p where p.id = p_post_id) then
      raise exception 'Official post not found';
    end if;
    insert into public.official_post_replies(post_id, author_id, content)
    values (p_post_id, uid, clean);
  else
    if not exists (
      select 1 from public.profiles p
      where p.id = uid and p.role in ('student', 'faculty', 'super_admin')
    ) then raise exception 'Verified campus profile required' using errcode = '42501'; end if;
    if not public.is_approved_unofficial_post(p_post_id) then
      raise exception 'This post is not available for comments';
    end if;
    insert into public.post_replies(post_id, author_id, content)
    values (p_post_id, uid, clean);
  end if;
end;
$$;

create table if not exists public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  campus_mode text not null check (campus_mode in ('official', 'unofficial')),
  activity_type text not null check (activity_type in ('like', 'comment')),
  post_id uuid not null,
  preview text not null default '',
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists app_notifications_recipient_recent_idx
  on public.app_notifications(recipient_id, created_at desc);
alter table public.app_notifications enable row level security;
revoke all on public.app_notifications from public, anon, authenticated;
grant all on public.app_notifications to service_role;

create or replace function public.capture_post_activity_notification()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target_post uuid := new.post_id;
  actor uuid;
  recipient uuid;
  mode_value text;
  type_value text;
  preview_value text := '';
begin
  if tg_table_name = 'post_likes' then
    actor := new.user_id; mode_value := 'unofficial'; type_value := 'like';
    select p.author_id, left(coalesce(p.content, ''), 140)
      into recipient, preview_value from public.posts p where p.id = target_post;
  elsif tg_table_name = 'post_replies' then
    actor := new.author_id; mode_value := 'unofficial'; type_value := 'comment';
    select p.author_id, left(coalesce(new.content, p.content, ''), 140)
      into recipient, preview_value from public.posts p where p.id = target_post;
  elsif tg_table_name = 'official_post_likes' then
    actor := new.user_id; mode_value := 'official'; type_value := 'like';
    select p.author_id, left(coalesce(p.content, ''), 140)
      into recipient, preview_value from public.official_posts p where p.id = target_post;
  elsif tg_table_name = 'official_post_replies' then
    actor := new.author_id; mode_value := 'official'; type_value := 'comment';
    select p.author_id, left(coalesce(new.content, p.content, ''), 140)
      into recipient, preview_value from public.official_posts p where p.id = target_post;
  else
    return new;
  end if;

  if recipient is not null and actor is not null and recipient <> actor then
    insert into public.app_notifications(
      recipient_id, actor_id, campus_mode, activity_type, post_id, preview
    ) values (recipient, actor, mode_value, type_value, target_post, preview_value);
  end if;
  return new;
end;
$$;

drop trigger if exists notify_post_like on public.post_likes;
create trigger notify_post_like after insert on public.post_likes
  for each row execute function public.capture_post_activity_notification();
drop trigger if exists notify_post_reply on public.post_replies;
create trigger notify_post_reply after insert on public.post_replies
  for each row execute function public.capture_post_activity_notification();
drop trigger if exists notify_official_post_like on public.official_post_likes;
create trigger notify_official_post_like after insert on public.official_post_likes
  for each row execute function public.capture_post_activity_notification();
drop trigger if exists notify_official_post_reply on public.official_post_replies;
create trigger notify_official_post_reply after insert on public.official_post_replies
  for each row execute function public.capture_post_activity_notification();

create or replace function public.get_my_notifications(p_limit integer default 50)
returns table(
  notification_id uuid,
  actor_name text,
  campus_mode text,
  activity_type text,
  post_id uuid,
  preview text,
  created_at timestamptz,
  read_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select n.id,
    case when n.campus_mode = 'official'
      then coalesce(nullif(btrim(identity.real_name), ''), 'MITS member')
      else coalesce(nullif(btrim(profile.anon_username), ''), 'Anonymous') end::text,
    n.campus_mode, n.activity_type, n.post_id, n.preview, n.created_at, n.read_at
  from public.app_notifications n
  left join public.identity_records identity on identity.user_id = n.actor_id
  left join public.profiles profile on profile.id = n.actor_id
  where auth.uid() is not null and n.recipient_id = auth.uid()
  order by n.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
$$;

create or replace function public.get_my_unread_notification_count()
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.app_notifications n
  where auth.uid() is not null and n.recipient_id = auth.uid() and n.read_at is null;
$$;

create or replace function public.mark_my_notifications_read(p_notification_id uuid default null)
returns void language sql security definer set search_path = '' as $$
  update public.app_notifications
  set read_at = now()
  where recipient_id = auth.uid() and read_at is null
    and (p_notification_id is null or id = p_notification_id);
$$;

revoke all on function public.submit_post_reply(uuid, text, text),
  public.get_my_notifications(integer), public.get_my_unread_notification_count(),
  public.mark_my_notifications_read(uuid), public.capture_post_activity_notification()
  from public, anon, authenticated;
grant execute on function public.submit_post_reply(uuid, text, text),
  public.get_my_notifications(integer), public.get_my_unread_notification_count(),
  public.mark_my_notifications_read(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
