// Service worker do Ponto iMarket.
// ESTRATÉGIA: network-first para tudo que é nosso (mesma origem).
// Isso é deliberado: o deploy é automático (Cloudflare) e um cache agressivo
// deixaria os celulares presos numa versão antiga. O cache aqui serve APENAS
// como rede de segurança para a casca do app abrir sem sinal — a batida de
// ponto sempre exige conexão (a hora é carimbada pelo servidor, é o que
// sustenta o anti-fraude). Nunca cacheamos POST nem chamadas ao Supabase.

const VERSION = "imk-v1";
const SHELL = ["./index.html", "./config.js", "./manifest.json", "./logo.png", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).catch(() => {}));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;                    // batidas (POST) nunca passam por cache
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;          // Supabase e CDNs vão direto pra rede

  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.status === 200 && res.type === "basic") {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(req).then((r) => r || caches.match("./index.html")))
  );
});
