// PWA plumbing: service worker, install prompt, Web Push subscription,
// friendly banners, and LiveView hooks for the Settings page.

const store = {
  get(k) { try { return localStorage.getItem(k) } catch (_) { return null } },
  set(k, v) { try { localStorage.setItem(k, v) } catch (_) {} },
}

const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
export const isStandalone = () => window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window

let swReg = null
let vapidKey = null
let deferredInstall = null
const listeners = new Set()
const notify = () => listeners.forEach(fn => { try { fn() } catch (_) {} })

export async function registerSW() {
  if (!("serviceWorker" in navigator)) return null
  try {
    swReg = await navigator.serviceWorker.register("/sw.js", {scope: "/"})
    // Pick up new versions promptly.
    swReg.update().catch(() => {})
  } catch (e) { console.warn("service worker failed", e) }
  notify()
  return swReg
}

window.addEventListener("beforeinstallprompt", e => { e.preventDefault(); deferredInstall = e; notify(); renderBanner() })
window.addEventListener("appinstalled", () => { deferredInstall = null; notify(); renderBanner() })

export function canInstall() { return !!deferredInstall }

export async function install() {
  if (!deferredInstall) return false
  deferredInstall.prompt()
  const {outcome} = await deferredInstall.userChoice
  deferredInstall = null; notify(); renderBanner()
  return outcome === "accepted"
}

// ---------- Web Push ----------
function b64ToBytes(b64) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4)
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from(raw, c => c.charCodeAt(0))
}

export function setVapidKey(key) {
  vapidKey = key
  if (pushSupported() && Notification.permission === "granted") subscribePush()
  notify(); renderBanner()
}

export function pushState() {
  if (!pushSupported()) return isIOS && !isStandalone() ? "needs-install" : "unsupported"
  return Notification.permission // default | granted | denied
}

export async function enablePush() {
  if (!pushSupported()) return pushState()
  const perm = await Notification.requestPermission()
  if (perm === "granted") await subscribePush()
  notify(); renderBanner()
  return perm
}

async function subscribePush() {
  if (!vapidKey) return
  const reg = swReg || (await registerSW())
  if (!reg) return
  try {
    let sub = await reg.pushManager.getSubscription()
    if (sub?.options?.applicationServerKey) {
      const cur = new Uint8Array(sub.options.applicationServerKey), want = b64ToBytes(vapidKey)
      if (cur.length !== want.length || cur.some((v, i) => v !== want[i])) { await sub.unsubscribe(); sub = null }
    }
    sub ||= await reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: b64ToBytes(vapidKey)})
    const csrf = document.querySelector("meta[name='csrf-token']").content
    await fetch("/push/subscribe", {
      method: "POST", credentials: "same-origin",
      headers: {"content-type": "application/json", "x-csrf-token": csrf},
      body: JSON.stringify({subscription: sub.toJSON()}),
    })
  } catch (e) { console.warn("push subscribe failed", e) }
}

export function showCallNotification(title, body, tag) {
  if (!swReg || !pushSupported() || Notification.permission !== "granted") return
  swReg.showNotification(title, {body, tag, renotify: true, requireInteraction: true, icon: "/images/icon-192.png", badge: "/images/badge-96.png", data: {url: "/"}})
}

export async function closeNotifications(tag) {
  if (!swReg) return
  try { (await swReg.getNotifications({tag})).forEach(n => n.close()) } catch (_) {}
}

// ---------- Banner (one friendly nudge at a time) ----------
function renderBanner() {
  const el = document.getElementById("pwa-banner")
  if (!el) return
  let html = ""
  const st = pushState()
  if (st === "needs-install" && store.get("callee:dismiss:ios") !== "1") {
    html = banner("ios", "hero-device-phone-mobile",
      "Get call alerts on your iPhone",
      `Tap <b>Share</b> <span aria-hidden="true">⎋</span> then <b>Add to Home Screen</b>, and open Callee from there.`, null)
  } else if (st === "default" && vapidKey && store.get("callee:dismiss:push") !== "1") {
    html = banner("push", "hero-bell-alert", "Don't miss calls", "Turn on alerts so your phone rings even when Callee is closed.", "Turn on")
  } else if (deferredInstall && !isStandalone() && store.get("callee:dismiss:install") !== "1") {
    html = banner("install", "hero-arrow-down-tray", "Install Callee", "Add it to your home screen for one-tap calling.", "Install")
  }
  el.innerHTML = html
  el.classList.toggle("hidden", !html)
  el.querySelector("[data-go]")?.addEventListener("click", async e => {
    const kind = e.currentTarget.dataset.go
    if (kind === "push") await enablePush()
    if (kind === "install") await install()
  })
  el.querySelector("[data-close]")?.addEventListener("click", e => {
    store.set(`callee:dismiss:${e.currentTarget.dataset.close}`, "1"); renderBanner()
  })
}

function banner(kind, icon, title, text, cta) {
  return `<div class="bg-primary text-primary-content">
    <div class="mx-auto max-w-3xl px-3 sm:px-6 py-2.5 flex items-center gap-3">
      <span class="${icon} size-6 shrink-0"></span>
      <div class="flex-1 min-w-0 text-sm leading-snug"><b>${title}.</b> ${text}</div>
      ${cta ? `<button data-go="${kind}" class="btn btn-sm bg-base-100 text-base-content border-0 shrink-0">${cta}</button>` : ""}
      <button data-close="${kind}" class="btn btn-sm btn-ghost btn-square shrink-0" aria-label="Dismiss"><span class="hero-x-mark size-5"></span></button>
    </div></div>`
}

// ---------- Connection + offline indicators ----------
let lastConn = "connecting"
export function setConnection(state) {
  lastConn = state
  const el = document.getElementById("conn-status")
  if (el) {
    const map = {
      online: ["bg-success", "Online", "You're online and can receive calls"],
      connecting: ["bg-warning animate-pulse", "Connecting", "Connecting…"],
      offline: ["bg-error", "Offline", "Offline: reconnecting"],
    }
    const [cls, label, title] = map[state]
    el.querySelector(".dot").className = `dot size-2 rounded-full ${cls}`
    el.querySelector(".label").textContent = label
    el.title = title
  }
  document.getElementById("offline-banner")?.classList.toggle("hidden", state !== "offline" || navigator.onLine)
}

// LiveView navigation re-renders the layout; restore client-side UI state.
window.addEventListener("phx:page-loading-stop", () => { setConnection(lastConn); renderBanner() })

window.addEventListener("offline", () => document.getElementById("offline-banner")?.classList.remove("hidden"))
window.addEventListener("online", () => document.getElementById("offline-banner")?.classList.add("hidden"))

// ---------- Flash auto-dismiss ----------
function autoDismissFlashes() {
  document.querySelectorAll("#flash-group [role=alert]:not([data-timer])").forEach(el => {
    if (el.hidden || el.id === "client-error" || el.id === "server-error") return
    el.dataset.timer = "1"
    setTimeout(() => el.click(), 6000)
  })
}
new MutationObserver(autoDismissFlashes).observe(document.documentElement, {childList: true, subtree: true})
document.addEventListener("DOMContentLoaded", autoDismissFlashes)

// ---------- LiveView hooks ----------
export const Hooks = {
  PushSettings: {
    mounted() {
      this.render = () => {
        const s = this.el.querySelector("[data-status]"), b = this.el.querySelector("[data-action]")
        const st = pushState()
        const text = {
          granted: "On. Your device will ring even when Callee is closed.",
          default: "Off. Turn on to get alerted when Callee is closed.",
          denied: "Blocked in browser settings. Allow notifications for this site to turn on.",
          "needs-install": "On iPhone, add Callee to your Home Screen first (Share → Add to Home Screen).",
          unsupported: "This browser can't show call alerts while closed. Keep Callee open to receive calls.",
        }[st]
        s.textContent = text
        b.classList.toggle("hidden", st !== "default")
      }
      this.el.querySelector("[data-action]").addEventListener("click", () => enablePush())
      listeners.add(this.render); this.render()
    },
    destroyed() { listeners.delete(this.render) },
  },

  InstallApp: {
    mounted() {
      this.render = () => {
        const s = this.el.querySelector("[data-status]"), b = this.el.querySelector("[data-action]")
        if (isStandalone()) { this.el.classList.add("hidden"); return }
        this.el.classList.remove("hidden")
        if (canInstall()) { b.classList.remove("hidden"); s.textContent = "Open Callee from your home screen like a regular app." }
        else if (isIOS) { b.classList.add("hidden"); s.innerHTML = "Tap <b>Share</b>, then <b>Add to Home Screen</b>." }
        else { b.classList.add("hidden"); s.textContent = "Use your browser menu → Install app / Add to Home screen." }
      }
      this.el.querySelector("[data-action]").addEventListener("click", () => install())
      listeners.add(this.render); this.render()
    },
    destroyed() { listeners.delete(this.render) },
  },

  MicTest: {
    mounted() {
      const s = this.el.querySelector("[data-status]"), b = this.el.querySelector("[data-action]"), bar = this.el.querySelector("[data-level]")
      b.addEventListener("click", async () => {
        if (this.stop) return this.stop()
        try {
          const stream = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true}})
          const ctx = new (window.AudioContext || window.webkitAudioContext)()
          const an = ctx.createAnalyser(); an.fftSize = 512
          ctx.createMediaStreamSource(stream).connect(an)
          const data = new Uint8Array(an.fftSize)
          let peak = 0, raf
          bar.classList.remove("hidden"); b.textContent = "Stop"; s.textContent = "Say something…"
          const tick = () => {
            an.getByteTimeDomainData(data)
            const lvl = Math.min(100, Math.round(Math.max(...data.map(v => Math.abs(v - 128))) / 1.28))
            peak = Math.max(peak, lvl); bar.value = lvl
            raf = requestAnimationFrame(tick)
          }
          tick()
          const timer = setTimeout(() => this.stop(), 6000)
          this.stop = () => {
            cancelAnimationFrame(raf); clearTimeout(timer)
            stream.getTracks().forEach(t => t.stop()); ctx.close()
            bar.classList.add("hidden"); b.textContent = "Test again"; this.stop = null
            s.textContent = peak > 8 ? "Your microphone works. You're ready to call." : "We couldn't hear anything. Check the mic isn't muted."
          }
        } catch (_) {
          s.textContent = "Microphone access was blocked. Allow it in your browser's site settings."
        }
      })
    },
    destroyed() { this.stop?.() },
  },
}
