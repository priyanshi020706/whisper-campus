// Edge Function: delivers queued push notifications.
//
// Called by the database (pg_net) whenever rows are added to push_outbox, and
// once a minute as a retry. It sends every unsent row to the person's devices
// with Web Push, removes devices the push service reports as gone, and marks the
// rows sent.
//
// Secrets (supabase secrets set ...): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
// VAPID_SUBJECT (a mailto: address), PUSH_SHARED_SECRET. SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// Deploy without JWT verification: the database authenticates with the shared
// secret header instead.  supabase functions deploy send-push --no-verify-jwt

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import {
  buildPayload,
  chunk,
  decideOutcome,
  secretsMatch,
  type DeliveryResult,
  type OutboxRow,
} from './payload.mts';

const BATCH = 100;

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const expected = Deno.env.get('PUSH_SHARED_SECRET');
  if (!secretsMatch(request.headers.get('x-push-secret'), expected)) {
    return new Response('Unauthorized', { status: 401 });
  }

  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com';
  if (!publicKey || !privateKey) {
    return new Response('VAPID keys are not set', { status: 500 });
  }
  webpush.setVapidDetails(subject, publicKey, privateKey);

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // Claim a batch: count the attempt first so a crash cannot loop forever.
  const { data: waiting, error: readError } = await db
    .from('push_outbox')
    .select('id, user_id, kind, title, body, url, tag, attempts')
    .is('sent_at', null)
    .lt('attempts', 5)
    .order('id', { ascending: true })
    .limit(BATCH);
  if (readError) return new Response(readError.message, { status: 500 });
  const rows = (waiting ?? []) as OutboxRow[];
  if (rows.length === 0) return Response.json({ sent: 0, waiting: 0 });

  const userIds = [...new Set(rows.map((r) => r.user_id))];
  const { data: subs, error: subError } = await db
    .from('push_subscriptions')
    .select('endpoint, p256dh, auth, user_id')
    .in('user_id', userIds);
  if (subError) return new Response(subError.message, { status: 500 });
  const byUser = new Map<string, { endpoint: string; p256dh: string; auth: string }[]>();
  for (const sub of subs ?? []) {
    const list = byUser.get(sub.user_id) ?? [];
    list.push(sub);
    byUser.set(sub.user_id, list);
  }

  let sent = 0;
  const goneEndpoints = new Set<string>();

  for (const group of chunk(rows, 20)) {
    await Promise.all(group.map(async (row) => {
      const body = JSON.stringify(buildPayload(row));
      const devices = byUser.get(row.user_id) ?? [];
      const results: DeliveryResult[] = [];
      for (const device of devices) {
        try {
          await webpush.sendNotification(
            { endpoint: device.endpoint, keys: { p256dh: device.p256dh, auth: device.auth } },
            body,
            { TTL: 3600, urgency: 'normal' },
          );
          results.push({ endpoint: device.endpoint, ok: true });
        } catch (error) {
          const status = (error as { statusCode?: number }).statusCode;
          results.push({
            endpoint: device.endpoint,
            ok: false,
            statusCode: status,
            error: (error as Error).message?.slice(0, 120),
          });
        }
      }
      const outcome = decideOutcome(results, row.attempts);
      outcome.goneEndpoints.forEach((e) => goneEndpoints.add(e));
      if (results.some((r) => r.ok)) sent++;
      await db
        .from('push_outbox')
        .update({
          attempts: row.attempts + 1,
          last_error: outcome.lastError,
          sent_at: outcome.done ? new Date().toISOString() : null,
        })
        .eq('id', row.id);
    }));
  }

  if (goneEndpoints.size > 0) {
    await db.from('push_subscriptions').delete().in('endpoint', [...goneEndpoints]);
  }

  return Response.json({ sent, waiting: rows.length, removed: goneEndpoints.size });
});
