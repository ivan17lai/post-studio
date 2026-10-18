// scripts/build_web.ps1 replaces these markers after Flutter builds its assets.
const CACHE = 'post-studio-__BUILD_VERSION__';
const PRECACHE = /*__PRECACHE__*/ [];
const ROOT = new URL('./', self.location.href);
const shell = new URL('index.html', ROOT).href;
const appURLs = new Set(PRECACHE.map(path => new URL(path, ROOT).href));

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    if (!PRECACHE.length) throw new Error('Build PWA assets with scripts/build_web.ps1');
    const cache = await caches.open(CACHE);
    // Bounded parallelism avoids flooding a mobile connection or holding every
    // WASM response in memory at once. Installation is atomic: no partial worker.
    for (let i = 0; i < PRECACHE.length; i += 4) {
      await cache.addAll(PRECACHE.slice(i, i + 4).map(path => new Request(new URL(path, ROOT), {cache:'reload'})));
    }
  })());
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith('post-studio-') && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const request = event.request, url = new URL(request.url);
  if (request.method !== 'GET') return;
  const navigation = request.mode === 'navigate' && url.origin === ROOT.origin && url.pathname.startsWith(ROOT.pathname);
  const font = url.protocol === 'https:' && url.hostname === 'fonts.gstatic.com';
  if (!navigation && !appURLs.has(url.href) && !font) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const key = navigation ? shell : request;
    const cached = await cache.match(key);
    if (cached) return cached;
    const response = await fetch(request);
    // Only visited font subsets are cached; photo blobs, IndexedDB records,
    // API requests and unrelated sites are never intercepted.
    if (font && (response.ok || response.type === 'opaque')) {
      await cache.put(request, response.clone());
    }
    return response;
  })());
});
