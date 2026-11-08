// Sube este número cada vez que cambies archivos para que los usuarios reciban la versión nueva
const CACHE_NAME = 'hunyverso-v22';
const urlsToCache = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
  './manilla-amor.jpg',
  './manilla-abundancia.jpg',
  './manilla-proteccion.jpg',
  './cuarzo-rosado.jpg',
  './rodonita.jpg',
  './ojo-de-tigre.jpg',
  './citrino.jpg',
  './cuarzo-ahumado.jpg'
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(urlsToCache)));
  self.skipWaiting();
});

// Borra cachés de versiones anteriores
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);
  // Solo archivos propios con GET; Supabase, CDNs y WhatsApp van directo a la red
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;

  // Páginas: primero la red (siempre lo más nuevo), caché si no hay conexión
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then(c => c.put(req, copy));
        return res;
      }).catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
    );
    return;
  }

  // Imágenes y demás archivos: caché primero, red si no está
  event.respondWith(caches.match(req).then(r => r || fetch(req)));
});
