// Runs web/push_sw.js inside a simulated service worker scope and checks what it
// does with a push and with a tap on the notification.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../web/push_sw.js', import.meta.url), 'utf8');
const ORIGIN = 'https://campus.example';

function makeWorker({ openWindows = [] } = {}) {
  const handlers = {};
  const shown = [];
  const opened = [];
  const focused = [];
  const self = {
    location: { origin: ORIGIN, href: `${ORIGIN}/push_sw.js` },
    addEventListener: (type, fn) => { handlers[type] = fn; },
    skipWaiting: () => 'skipped',
    clients: {
      claim: async () => 'claimed',
      matchAll: async () => openWindows.map((url) => ({
        url,
        focus: async () => { focused.push(url); },
      })),
      openWindow: async (url) => { opened.push(url); },
    },
    registration: {
      showNotification: async (title, options) => { shown.push({ title, options }); },
    },
  };
  vm.runInNewContext(source, { self, URL, console });
  return { handlers, shown, opened, focused };
}

/** Runs a handler and waits for whatever it passed to event.waitUntil. */
async function fire(handler, event) {
  let pending;
  handler({ ...event, waitUntil: (p) => { pending = p; } });
  await pending;
}

const pushEvent = (data) => ({ data: { json: () => JSON.parse(data), text: () => data } });

test('registers the three handlers', () => {
  const { handlers } = makeWorker();
  assert.deepEqual(Object.keys(handlers).sort(), ['activate', 'install', 'notificationclick', 'push']);
});

test('a push shows a notification with title, body, tag and target', async () => {
  const { handlers, shown } = makeWorker();
  await fire(handlers.push, pushEvent(JSON.stringify({
    title: 'New reply in Clubs', body: 'Someone replied to your message.', tag: 'chat-reply-1', url: '/clubs',
  })));

  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, 'New reply in Clubs');
  assert.equal(shown[0].options.body, 'Someone replied to your message.');
  assert.equal(shown[0].options.tag, 'chat-reply-1');
  assert.equal(shown[0].options.data.url, '/clubs');
  assert.match(shown[0].options.icon, /icons\/Icon-192\.png$/);
});

test('a push without a title still shows something sensible', async () => {
  const { handlers, shown } = makeWorker();
  await fire(handlers.push, pushEvent('{}'));

  assert.equal(shown[0].title, 'Whisper Campus');
  assert.equal(shown[0].options.body, '');
  assert.equal(shown[0].options.data.url, '/');
});

test('a push with plain text (not JSON) is shown as text', async () => {
  const { handlers, shown } = makeWorker();
  await fire(handlers.push, { data: { json: () => { throw new Error('not json'); }, text: () => 'hello there' } });

  assert.equal(shown[0].options.body, 'hello there');
});

test('a push with no data does not crash', async () => {
  const { handlers, shown } = makeWorker();
  await fire(handlers.push, { data: null });

  assert.equal(shown.length, 1);
});

test('tapping opens the site when it is not open yet', async () => {
  const { handlers, opened } = makeWorker();
  let closed = false;
  await fire(handlers.notificationclick, { notification: { close: () => { closed = true; }, data: { url: '/events' } } });

  assert.equal(closed, true);
  assert.deepEqual(opened, [`${ORIGIN}/events`]);
});

test('tapping focuses an open window instead of opening another', async () => {
  const { handlers, opened, focused } = makeWorker({ openWindows: [`${ORIGIN}/`] });
  await fire(handlers.notificationclick, { notification: { close() {}, data: { url: '/' } } });

  assert.deepEqual(focused, [`${ORIGIN}/`]);
  assert.deepEqual(opened, []);
});

test('tapping never opens another site', async () => {
  for (const evil of ['https://evil.example/x', '//evil.example', 'javascript:alert(1)']) {
    const { handlers, opened } = makeWorker();
    await fire(handlers.notificationclick, { notification: { close() {}, data: { url: evil } } });

    assert.equal(opened.length, 1, evil);
    assert.ok(opened[0].startsWith(`${ORIGIN}/`), `${evil} -> ${opened[0]}`);
  }
});

test('tapping a notification with no data opens the home page', async () => {
  const { handlers, opened } = makeWorker();
  await fire(handlers.notificationclick, { notification: { close() {}, data: null } });

  assert.deepEqual(opened, [`${ORIGIN}/`]);
});

test('ignores windows of other sites', async () => {
  const { handlers, opened, focused } = makeWorker({ openWindows: ['https://other.example/'] });
  await fire(handlers.notificationclick, { notification: { close() {}, data: { url: '/' } } });

  assert.deepEqual(focused, []);
  assert.deepEqual(opened, [`${ORIGIN}/`]);
});
