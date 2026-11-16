// Whisper Campus push notifications.
//
// This worker only handles push messages and notification taps. It is
// registered under its own scope (see push_platform_web.dart), so it never
// interferes with Flutter's own service worker or with caching.

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = { body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Whisper Campus';
  const options = {
    body: data.body || '',
    icon: new URL('icons/Icon-192.png', self.location.href).href,
    badge: new URL('icons/Icon-192.png', self.location.href).href,
    // Same tag = the newer notification replaces the older one.
    tag: data.tag || undefined,
    data: { url: typeof data.url === 'string' ? data.url : '/' },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const requested = (event.notification.data && event.notification.data.url) || '/';

  // Only ever open pages of this site.
  let target;
  try {
    const url = new URL(requested, self.location.origin);
    target = url.origin === self.location.origin ? url.href : self.location.origin + '/';
  } catch (_) {
    target = self.location.origin + '/';
  }

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    for (const client of windows) {
      if (client.url.startsWith(self.location.origin) && 'focus' in client) {
        await client.focus();
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});
