# Supabase

## Applying migrations

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
