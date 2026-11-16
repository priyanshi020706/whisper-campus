# Supabase

## Applying migrations

The newest migrations build on each other. Apply them in this order (filename
order), after everything older:

| Migration | Adds |
|---|---|
| `20261117000000` – `20261117050000` | admin allowlist, rate limits, reports, chat broadcast, live signals |
| `20261117060000_room_chat_recents_and_pins` | recent chats and pinned rooms |
| `20261118000000_notification_settings_saved_posts_and_edits` | notification settings, muted rooms, saved posts, editing |
| `20261118010000_chat_replies_reactions_and_polls` | chat replies, reactions, polls (chats and posts) |
| `20261118020000_search_events_and_announcements` | search, events, announcements |
| `20261118030000_push_notifications` | push queue and delivery (needs the setup below) |
| `20261118040000_mute_durations_and_short_edit_window` | mute for 1 hour / 8 hours / until unmuted; edits allowed for 10 minutes |

Apply files in `migrations/` in filename order. Try each new migration on a
Supabase branch (or a copy of the project) before production.

## Known gaps

- **No baseline schema.** The first tables (`profiles`, `posts`, `rooms`,
  `identity_records`, and a few more) were created in the dashboard and are not
  in these files, so the migrations cannot rebuild the database from nothing.
  Export the current schema with `supabase db dump --schema public` and commit
  it as the first migration.
- **Migrations that patch deployed code.** `20261115050000_*` and
  `20261115060000_*` rewrite function bodies in place and depend on what is
  deployed. Do not replay them on an empty database.
- **Older migrations still contain test emails** (a personal Gmail address and
  one student address). They are history; `20261117000000_platform_admin_allowlist.sql`
  moves the current admin email into the `platform_admins` table.
- `20261115100000_*` and `20261116030000_*` contain a one-off fix for one
  student's profile. It runs only for that email.

## Live chat checklist

Live chat sends each new `room_messages` row through a private Realtime
broadcast. If users must refresh to see messages, check:

```sql
-- should list exactly one broadcast trigger
select t.tgname from pg_trigger t
where t.tgrelid = 'public.room_messages'::regclass and not t.tgisinternal;
```

`20261117040000_room_message_broadcast_trigger.sql` creates it if missing.

## Live updates checklist

Posts, likes, comments and notifications update live through
`20261117050000_live_activity_signals.sql`. It adds triggers that send small
id-only signals on the private topics `feed:unofficial`, `feed:official` and
`user:<id>`, plus a policy on `realtime.messages` that lets signed-in campus
members listen. If screens still need a refresh, check that this migration is
applied and look at the Realtime logs in the dashboard.

## Recent chats and pinned rooms

`20261117060000_room_chat_recents_and_pins.sql` adds `room_pins` (at most 3 per
user and mode, enforced in `pin_room`) and `get_my_room_activity(mode)`, which
the app uses to put pinned rooms first and then rooms by latest message. Until
it is applied, room lists keep their default order and pinning shows an error.

## Push notifications

Push uses standard Web Push (no Firebase account needed).
`20261118030000_push_notifications.sql` creates the queue, and the Edge Function
in `functions/send-push` delivers it. One-time setup:

1. Make a VAPID key pair (it identifies your server to browsers):

   ```bash
   npx web-push generate-vapid-keys
   ```

2. Give the function its secrets, then deploy it **without JWT checks** (the
   database authenticates with a shared secret instead):

   ```bash
   supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... \
     VAPID_SUBJECT=mailto:you@example.com PUSH_SHARED_SECRET=$(openssl rand -hex 24)
   supabase functions deploy send-push --no-verify-jwt
   ```

3. Tell the database where the function is (use the same shared secret):

   ```sql
   insert into public.push_settings (id, function_url, shared_secret)
   values (1, 'https://YOUR-PROJECT.supabase.co/functions/v1/send-push', 'THE-SAME-SECRET');
   ```

4. In Vercel, add the **public** key as an environment variable named
   `VAPID_PUBLIC_KEY` (the build passes it to the app) and redeploy.

Until step 4 the Notification settings page says push is not set up. Pushes
never contain names ("Someone liked your post"). Check `select * from
public.push_outbox order by id desc limit 20;` to see what was queued and any
`last_error`. pg_net and pg_cron are used when available; without pg_cron there
are no automatic retries or event reminders.

## Settings to check in the Supabase dashboard

- Authentication > Providers: only Google enabled. Turn **Email** sign-ups off
  so nobody can create an account without Google verification.
- Authentication > URL configuration: redirect URLs list only the real site.
- Storage: buckets `campus-post-images` and `official-post-images` are private.

## Adding or removing a Super Admin

```sql
insert into public.platform_admins (email) values ('name@mitsgwl.ac.in');
delete from public.platform_admins where email = 'name@mitsgwl.ac.in';
```
