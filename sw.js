/* =====================================================================
   매출 플래너 — Service Worker
   · 앱 셸 프리캐시 → 오프라인에서도 앱이 열림
   · 화면(HTML)        : 네트워크 우선 → 실패/지연 시 캐시
   · 정적 파일·아이콘   : 캐시 우선 + 백그라운드 갱신(SWR)
   · 폰트(CDN)         : 캐시 우선(장기 보관)
   · Supabase 조회(GET): 네트워크 우선 → 오프라인이면 마지막 응답(읽기 전용)
   · Supabase 쓰기     : 항상 네트워크(캐시하지 않음)
   배포할 때마다 VERSION 을 올리면 앱에 “새 버전” 알림이 뜹니다.
   ===================================================================== */
const VERSION = '1.0.0';
const SHELL = `spp-shell-${VERSION}`;
const RUNTIME = 'spp-runtime-v1';
const FONTS = 'spp-fonts-v1';
const DATA = 'spp-data-v1';
const KEEP = [SHELL, RUNTIME, FONTS, DATA];

const PRECACHE = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon.svg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/maskable-192.png',
  './icons/maskable-512.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32.png',
];
const OPTIONAL = ['./config.js']; // 없어도 설치 실패하지 않음

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    await c.addAll(PRECACHE.map(u => new Request(u, { cache: 'reload' })));
    await Promise.all(OPTIONAL.map(u => fetch(u, { cache: 'reload' }).then(r => r.ok && c.put(u, r)).catch(() => {})));
  })());
  // 첫 설치는 즉시 활성화, 업데이트는 사용자가 [업데이트]를 누를 때까지 대기
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(n => n.startsWith('spp-') && !KEEP.includes(n)).map(n => caches.delete(n)));
    if (self.registration.navigationPreload) await self.registration.navigationPreload.enable().catch(() => {});
    await self.clients.claim();
  })());
});

self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
  if (e.data?.type === 'GET_VERSION') e.source?.postMessage({ type: 'VERSION', version: VERSION });
  if (e.data?.type === 'CLEAR_DATA_CACHE') e.waitUntil(caches.delete(DATA));
});

const timeout = (ms) => new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));

async function networkFirst(req, cacheName, ms, preload) {
  const cache = await caches.open(cacheName);
  try {
    const res = await Promise.race([preload || fetch(req), timeout(ms)]);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, { ignoreSearch: req.mode === 'navigate' });
    if (hit) return hit;
    throw err;
  }
}

async function staleWhileRevalidate(e, req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  const net = fetch(req).then(res => { if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone()); return res; }).catch(() => null);
  if (hit) { e.waitUntil(net); return hit; }
  return (await net) || Response.error();
}

async function cacheFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
  return res;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);

  // Supabase REST — 쓰기는 통과, 조회만 오프라인 대비 저장
  if (url.pathname.includes('/rest/v1/')) {
    if (req.method !== 'GET') return;
    e.respondWith(networkFirst(req, DATA, 8000).catch(() => Response.error()));
    return;
  }
  if (req.method !== 'GET') return;

  // 화면 이동(HTML)
  if (req.mode === 'navigate') {
    e.respondWith((async () => {
      try { const pre = await Promise.resolve(e.preloadResponse).catch(() => null); return await networkFirst(req, SHELL, 4000, pre || null); }
      catch { return (await caches.match('./index.html')) || (await caches.match('./')) || Response.error(); }
    })());
    return;
  }

  // 웹폰트(Pretendard CDN)
  if (/cdn\.jsdelivr\.net|fonts\.(googleapis|gstatic)\.com/.test(url.hostname)) {
    e.respondWith(cacheFirst(req, FONTS).catch(() => Response.error()));
    return;
  }

  if (url.origin !== location.origin) return;

  // config.js 는 연결 정보가 바뀔 수 있으므로 네트워크 우선
  if (url.pathname.endsWith('/config.js')) {
    e.respondWith(networkFirst(req, SHELL, 3000).catch(() => new Response('window.SPP_CONFIG = window.SPP_CONFIG || {};', { headers: { 'Content-Type': 'text/javascript' } })));
    return;
  }

  e.respondWith(staleWhileRevalidate(e, req, url.pathname.match(/\.(png|svg|webmanifest|js|css|ico)$/) ? SHELL : RUNTIME));
});
