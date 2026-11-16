-- Reporting and moderation for anonymous content.
--
-- Students report content without learning who wrote it. Super Admins review a
-- queue that shows the content and the author's strike count but never the
-- author's identity. Every resolution is written to an audit log.
begin;

create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  target_type text not null
    check (target_type in ('post', 'reply', 'message', 'official_post', 'official_reply')),
  target_id uuid not null,
  reason text not null
    check (reason in ('harassment', 'hate', 'sexual', 'violence', 'self_harm', 'spam', 'other')),
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'open'
    check (status in ('open', 'dismissed', 'content_removed')),
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 500),
  created_at timestamptz not null default now(),
  unique (reporter_id, target_type, target_id)
);

create index if not exists content_reports_status_created_at_idx
  on public.content_reports (status, created_at desc);
create index if not exists content_reports_target_idx
  on public.content_reports (target_type, target_id);
create index if not exists content_reports_reporter_created_at_idx
  on public.content_reports (reporter_id, created_at desc);

create table if not exists public.user_strikes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  report_id uuid references public.content_reports(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists user_strikes_user_idx on public.user_strikes (user_id);

create table if not exists public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id uuid,
  report_id uuid,
  created_at timestamptz not null default now()
);

alter table public.content_reports enable row level security;
alter table public.user_strikes enable row level security;
alter table public.admin_audit_log enable row level security;
revoke all on table public.content_reports from public, anon, authenticated;
revoke all on table public.user_strikes from public, anon, authenticated;
revoke all on table public.admin_audit_log from public, anon, authenticated;

-- Students and faculty report content through this function only.
create or replace function public.report_content(
  p_target_type text,
  p_target_id uuid,
  p_reason text,
  p_details text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  author uuid;
  recent_reports integer;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.profiles as me
    where me.id = uid and me.role in ('student', 'faculty', 'super_admin')
  ) then
    raise exception 'Campus profile required' using errcode = '42501';
  end if;
  if p_reason not in ('harassment', 'hate', 'sexual', 'violence', 'self_harm', 'spam', 'other') then
    raise exception 'Choose a reason for the report.';
  end if;
  if char_length(coalesce(p_details, '')) > 500 then
    raise exception 'Report details must be 500 characters or fewer.';
  end if;

  author := case p_target_type
    when 'post' then (select x.author_id from public.posts as x where x.id = p_target_id)
    when 'reply' then (select x.author_id from public.post_replies as x where x.id = p_target_id)
    when 'message' then (select x.sender_id from public.room_messages as x where x.id = p_target_id)
    when 'official_post' then (select x.author_id from public.official_posts as x where x.id = p_target_id)
    when 'official_reply' then (select x.author_id from public.official_post_replies as x where x.id = p_target_id)
    else null
  end;
  if author is null then
    raise exception 'That content no longer exists.';
  end if;
  if author = uid then
    raise exception 'You cannot report your own content.';
  end if;

  select count(*) into recent_reports
  from public.content_reports as r
  where r.reporter_id = uid and r.created_at > now() - interval '24 hours';
  if recent_reports >= 20 then
    raise exception 'You have sent many reports today. Please try again tomorrow.';
  end if;

  insert into public.content_reports (reporter_id, target_type, target_id, reason, details)
  values (uid, p_target_type, p_target_id, p_reason, nullif(btrim(coalesce(p_details, '')), ''))
  on conflict (reporter_id, target_type, target_id) do nothing;
end;
$$;

-- Super Admin review queue. No author identity is returned.
create or replace function public.list_content_reports(
  p_status text default 'open',
  p_limit integer default 50
)
returns table (
  report_id uuid,
  target_type text,
  target_id uuid,
  reason text,
  details text,
  status text,
  created_at timestamptz,
  report_count integer,
  author_strikes integer,
  content_preview text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception 'Super Admin access required' using errcode = '42501';
  end if;

  return query
  with targets as (
    select 'post'::text as kind, p.id as item_id, p.author_id as owner_id, p.content as body from public.posts as p
    union all
    select 'reply', r.id, r.author_id, r.content from public.post_replies as r
    union all
    select 'message', m.id, m.sender_id, m.content from public.room_messages as m
    union all
    select 'official_post', o.id, o.author_id, o.content from public.official_posts as o
    union all
    select 'official_reply', q.id, q.author_id, q.content from public.official_post_replies as q
  )
  select
    rep.id,
    rep.target_type,
    rep.target_id,
    rep.reason,
    rep.details,
    rep.status,
    rep.created_at,
    (select count(*)::integer from public.content_reports as same
      where same.target_type = rep.target_type and same.target_id = rep.target_id),
    (select count(*)::integer from public.user_strikes as s where s.user_id = t.owner_id),
    left(t.body, 300)
  from public.content_reports as rep
  left join targets as t on t.kind = rep.target_type and t.item_id = rep.target_id
  where rep.status = p_status
  order by rep.created_at desc
  limit least(greatest(p_limit, 1), 200);
end;
$$;

-- Super Admin decision. Returns the removed post's image path (or null) so the
-- app can delete the storage object, matching admin_delete_post.
create or replace function public.resolve_content_report(
  p_report_id uuid,
  p_action text,
  p_note text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  rep public.content_reports%rowtype;
  owner uuid;
  image text;
begin
  if not public.is_super_admin(uid) then
    raise exception 'Super Admin access required' using errcode = '42501';
  end if;
  if p_action not in ('dismiss', 'remove_content', 'remove_and_strike') then
    raise exception 'Unknown moderation action';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'The note must be 500 characters or fewer.';
  end if;

  select * into rep from public.content_reports as r
  where r.id = p_report_id and r.status = 'open'
  for update;
  if not found then
    raise exception 'That report was already handled.';
  end if;

  if p_action = 'dismiss' then
    update public.content_reports
    set status = 'dismissed', resolved_by = uid, resolved_at = now(),
        resolution_note = nullif(btrim(coalesce(p_note, '')), '')
    where id = rep.id;
  else
    if rep.target_type = 'post' then
      delete from public.posts where id = rep.target_id
      returning author_id, image_path into owner, image;
    elsif rep.target_type = 'reply' then
      delete from public.post_replies where id = rep.target_id returning author_id into owner;
    elsif rep.target_type = 'message' then
      delete from public.room_messages where id = rep.target_id returning sender_id into owner;
    elsif rep.target_type = 'official_post' then
      delete from public.official_posts where id = rep.target_id
      returning author_id, image_path into owner, image;
    else
      delete from public.official_post_replies where id = rep.target_id returning author_id into owner;
    end if;

    if p_action = 'remove_and_strike' and owner is not null then
      insert into public.user_strikes (user_id, report_id, created_by)
      values (owner, rep.id, uid);
    end if;

    -- Close this report and any other open reports for the same content.
    update public.content_reports
    set status = 'content_removed', resolved_by = uid, resolved_at = now(),
        resolution_note = nullif(btrim(coalesce(p_note, '')), '')
    where target_type = rep.target_type and target_id = rep.target_id and status = 'open';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_type, target_id, report_id)
  values (uid, p_action, rep.target_type, rep.target_id, rep.id);

  return image;
end;
$$;

revoke all on function public.report_content(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.list_content_reports(text, integer) from public, anon, authenticated;
revoke all on function public.resolve_content_report(uuid, text, text) from public, anon, authenticated;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;
grant execute on function public.list_content_reports(text, integer) to authenticated;
grant execute on function public.resolve_content_report(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
commit;
