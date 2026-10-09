// Bridge to the Callee Android app (Capacitor shell). In a normal browser every
// function here is a no-op.

const cap = () => window.Capacitor

export const isNative = () => !!cap()?.isNativePlatform?.()

let plugin = null
export function native() {
  if (!isNative()) return null
  plugin ||= cap().Plugins?.CalleeNative || cap().registerPlugin?.("CalleeNative")
  return plugin
}

// Hand the logged-in session to the app's background calling service, or clear
// it when signed out (login pages have no call-token).
export function syncSession() {
  const n = native()
  if (!n) return
  const token = document.querySelector("meta[name='call-token']")?.content
  if (token) {
    n.setSession({
      url: location.origin,
      token,
      role: document.querySelector("meta[name='call-role']")?.content,
      uid: document.querySelector("meta[name='call-uid']")?.content,
    }).catch(() => {})
  } else if (/\/(login|tenant\/login|admin\/login)$/.test(location.pathname)) {
    n.clearSession().catch(() => {})
  }
}
