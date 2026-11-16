// Pure helpers for the send-push Edge Function. They have no Deno or network
// dependencies, so they can be tested with plain Node (see payload.test.ts).

export interface OutboxRow {
  id: number;
  user_id: string;
  kind: string;
  title: string;
  body: string;
  url: string;
  tag: string | null;
  attempts: number;
}

export interface PushPayload {
  title: string;
  body: string;
  url: string;
  tag?: string;
  kind: string;
}

/** Only same-site paths are allowed as the page a notification opens. */
export function safeUrl(url: unknown): string {
  if (typeof url !== 'string') return '/';
  const trimmed = url.trim();
  // "//evil.example" and "/\evil.example" are protocol-relative: reject them.
  if (!trimmed.startsWith('/') || trimmed.startsWith('//') || trimmed.startsWith('/\\')) {
    return '/';
  }
  return trimmed.slice(0, 300);
}

export function buildPayload(row: OutboxRow): PushPayload {
  const payload: PushPayload = {
    title: String(row.title ?? '').slice(0, 120) || 'Whisper Campus',
    body: String(row.body ?? '').slice(0, 200),
    url: safeUrl(row.url),
    kind: String(row.kind ?? ''),
  };
  if (row.tag) payload.tag = String(row.tag).slice(0, 100);
  return payload;
}

/** A subscription the push service says no longer exists. Remove it. */
export function isGone(statusCode: number | undefined): boolean {
  return statusCode === 404 || statusCode === 410;
}

export interface DeliveryResult {
  endpoint: string;
  ok: boolean;
  statusCode?: number;
  error?: string;
}

export interface Outcome {
  /** Mark the row as sent (it will not be retried). */
  done: boolean;
  /** Subscriptions to delete because they are gone. */
  goneEndpoints: string[];
  lastError: string | null;
}

/**
 * Decides what to do with one queued push after trying every device of the
 * person. It is done when at least one device got it, when the person has no
 * device any more, or after too many attempts.
 */
export function decideOutcome(
  results: DeliveryResult[],
  attempts: number,
  maxAttempts = 5,
): Outcome {
  const goneEndpoints = results.filter((r) => !r.ok && isGone(r.statusCode)).map((r) => r.endpoint);
  const delivered = results.some((r) => r.ok);
  const remainingFailures = results.filter((r) => !r.ok && !isGone(r.statusCode));
  const lastError = remainingFailures.length
    ? remainingFailures.map((r) => r.error ?? `status ${r.statusCode ?? '?'}`).join('; ').slice(0, 300)
    : null;

  if (delivered || results.length === 0 || remainingFailures.length === 0) {
    return { done: true, goneEndpoints, lastError: delivered ? null : lastError };
  }
  // Only temporary failures are left: try again later, up to a limit.
  return { done: attempts + 1 >= maxAttempts, goneEndpoints, lastError };
}

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/** Compares secrets without stopping at the first different character. */
export function secretsMatch(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  const length = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < length; i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}
