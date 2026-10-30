// مصاريف — Service Worker: الإشعارات، وفتح التطبيق بدون إنترنت.
// الصفحة نفسها من الشبكة أولاً (فتوصلك التحديثات دائماً)، والنسخة المحفوظة فقط لما ينقطع الاتصال.
const CACHE = 'masareef-v1';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil((async () => {
  for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);
  await self.clients.claim();
})()));

async function store(req, res) {
  if (!res || !res.ok || res.type === 'opaque') return;
  const cache = await caches.open(CACHE);
  await cache.put(req, res);
  // ملفات الإصدارات القديمة: نخلي آخر 80 ملف بس
  const keys = await cache.keys();
  if (keys.length > 80) await Promise.all(keys.slice(0, keys.length - 80).map((k) => cache.delete(k)));
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // Supabase وغيره: مباشرة بدون تخزين
  if (req.mode === 'navigate') {
    event.respondWith(fetch(req)
      .then((res) => { event.waitUntil(store(new Request(self.registration.scope), res.clone())); return res; })
      .catch(async () => (await caches.match(self.registration.scope)) || Response.error()));
    return;
  }
  if (url.pathname.includes('/assets/')) {
    // ملفات بأسماء فريدة لكل إصدار: المحفوظ أولاً
    event.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      event.waitUntil(store(req, res.clone()));
      return res;
    })));
    return;
  }
  event.respondWith(fetch(req)
    .then((res) => { event.waitUntil(store(req, res.clone())); return res; })
    .catch(async () => (await caches.match(req)) || Response.error()));
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { body: event.data ? event.data.text() : '' };
  }
  event.waitUntil(
    self.registration.showNotification(data.title || 'مصاريف', {
      body: data.body || '',
      tag: data.tag || undefined,
      icon: 'icon-192.png',
      badge: 'icon-192.png',
      lang: 'ar',
      dir: 'rtl',
      data: { url: data.url || './' },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('focus' in client) {
        await client.focus();
        if ('navigate' in client) await client.navigate(url).catch(() => {});
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
