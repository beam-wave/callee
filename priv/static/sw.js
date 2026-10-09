// Callee service worker.
// - Precaches an offline page + icons so the installed app opens offline.
// - Network-first for pages (fresh data, offline fallback).
// - Cache-first for digested /assets/* and images.
// - Shows incoming / missed call notifications from Web Push.
const VERSION = "callee-v2"
const PRECACHE = ["/offline.html", "/manifest.json", "/images/icon-192.png", "/images/icon-512.png", "/images/icon.svg", "/images/badge-96.png"]

self.addEventListener("install", event => {
  event.waitUntil(caches.open(VERSION).then(c => c.addAll(PRECACHE)).then(() => self.skipWaiting()))
})

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys()
    await Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))
    if (self.registration.navigationPreload) await self.registration.navigationPreload.enable()
    await self.clients.claim()
  })())
})

self.addEventListener("fetch", event => {
  const req = event.request
  if (req.method !== "GET") return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return
  // Never touch realtime / auth / uploads / recordings.
  if (/^\/(socket|live|phoenix|push|logout|tenant\/recordings)/.test(url.pathname)) return

  if (req.mode === "navigate") {
    event.respondWith((async () => {
      try {
        return (await event.preloadResponse) || (await fetch(req))
      } catch (_) {
        return (await caches.match("/offline.html")) || Response.error()
      }
    })())
    return
  }

  if (url.pathname.startsWith("/assets/") || url.pathname.startsWith("/images/") || url.pathname.startsWith("/fonts/")) {
    event.respondWith((async () => {
      const cached = await caches.match(req)
      if (cached) return cached
      const res = await fetch(req)
      if (res.ok) (await caches.open(VERSION)).put(req, res.clone())
      return res
    })())
  }
})

self.addEventListener("push", event => {
  let data = {}
  try { data = event.data ? event.data.json() : {} } catch (_) {}
  const incoming = data.type === "incoming_call"
  event.waitUntil(
    self.registration.showNotification(data.title || "Callee", {
      body: data.body || "",
      tag: data.tag || "callee",
      renotify: true,
      requireInteraction: incoming,
      icon: "/images/icon-192.png",
      badge: "/images/badge-96.png",
      vibrate: incoming ? [500, 200, 500, 200, 500] : [200],
      actions: incoming ? [{action: "open", title: "Answer"}] : [],
      data: {url: incoming ? "/" : "/?tab=calls", type: data.type, call_id: data.call_id},
    })
  )
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = event.notification.data?.url || "/"
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const existing = all.find(c => new URL(c.url).origin === self.location.origin)
    if (existing) { await existing.focus(); return }
    return self.clients.openWindow(url)
  })())
})
