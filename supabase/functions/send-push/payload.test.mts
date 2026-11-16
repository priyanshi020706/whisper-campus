import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildPayload,
  chunk,
  decideOutcome,
  isGone,
  safeUrl,
  secretsMatch,
  type OutboxRow,
} from './payload.mts';

const row = (over: Partial<OutboxRow> = {}): OutboxRow => ({
  id: 1,
  user_id: 'u',
  kind: 'like',
  title: 'Someone liked your post',
  body: 'Open Whisper Campus to see it.',
  url: '/',
  tag: 'like-1',
  attempts: 0,
  ...over,
});

test('safeUrl keeps same-site paths and rejects everything else', () => {
  assert.equal(safeUrl('/events'), '/events');
  assert.equal(safeUrl('/a?b=1#c'), '/a?b=1#c');
  assert.equal(safeUrl('https://evil.example/x'), '/');
  assert.equal(safeUrl('//evil.example'), '/');
  assert.equal(safeUrl('/\\evil.example'), '/');
  assert.equal(safeUrl('javascript:alert(1)'), '/');
  assert.equal(safeUrl(undefined), '/');
  assert.equal(safeUrl(42), '/');
  assert.equal(safeUrl(`/${'x'.repeat(500)}`).length, 300);
});

test('buildPayload copies the fields and trims long text', () => {
  const p = buildPayload(row({ title: 'T'.repeat(300), body: 'B'.repeat(500), tag: 'x'.repeat(300) }));
  assert.equal(p.title.length, 120);
  assert.equal(p.body.length, 200);
  assert.equal(p.tag?.length, 100);
  assert.equal(p.kind, 'like');
});

test('buildPayload falls back to a title and a safe url', () => {
  const p = buildPayload(row({ title: '', url: 'https://evil.example', tag: null }));
  assert.equal(p.title, 'Whisper Campus');
  assert.equal(p.url, '/');
  assert.equal('tag' in p, false);
});

test('isGone recognises dead subscriptions only', () => {
  assert.equal(isGone(404), true);
  assert.equal(isGone(410), true);
  assert.equal(isGone(500), false);
  assert.equal(isGone(429), false);
  assert.equal(isGone(undefined), false);
});

test('one device got it: done, nothing to retry', () => {
  const out = decideOutcome([{ endpoint: 'a', ok: true }, { endpoint: 'b', ok: false, statusCode: 500, error: 'boom' }], 0);
  assert.equal(out.done, true);
  assert.equal(out.lastError, null);
});

test('dead subscriptions are listed for removal', () => {
  const out = decideOutcome([{ endpoint: 'a', ok: true }, { endpoint: 'b', ok: false, statusCode: 410 }], 0);
  assert.deepEqual(out.goneEndpoints, ['b']);
  assert.equal(out.done, true);
});

test('no devices left: done without error', () => {
  const out = decideOutcome([], 0);
  assert.equal(out.done, true);
  assert.equal(out.lastError, null);
});

test('only dead devices: done (they were removed), not retried', () => {
  const out = decideOutcome([{ endpoint: 'a', ok: false, statusCode: 404 }], 0);
  assert.equal(out.done, true);
  assert.deepEqual(out.goneEndpoints, ['a']);
});

test('temporary failure: retry until the limit', () => {
  const failure = [{ endpoint: 'a', ok: false, statusCode: 503, error: 'unavailable' }];
  assert.equal(decideOutcome(failure, 0).done, false);
  assert.equal(decideOutcome(failure, 3).done, false);
  const last = decideOutcome(failure, 4);
  assert.equal(last.done, true);
  assert.match(last.lastError ?? '', /unavailable/);
});

test('chunk splits into groups', () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assert.deepEqual(chunk([], 3), []);
});

test('secretsMatch', () => {
  assert.equal(secretsMatch('abc', 'abc'), true);
  assert.equal(secretsMatch('abc', 'abd'), false);
  assert.equal(secretsMatch('abc', 'abcd'), false);
  assert.equal(secretsMatch('', ''), false);
  assert.equal(secretsMatch(null, 'x'), false);
  assert.equal(secretsMatch('x', undefined), false);
});
