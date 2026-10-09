// Earpiece vs loudspeaker for calls.
//
// Web pages have limited control over audio output on phones:
//  * iPhone / iPad (Safari 16.4+): the Audio Session API. "play-and-record" routes
//    call audio to the earpiece (receiver); "auto" gives Safari's default, which
//    for WebRTC is the loudspeaker.
//  * Android Chrome / desktop: HTMLMediaElement.setSinkId() with an output device
//    whose label looks like an earpiece or speaker (only when the browser lists them).
// If neither is available the speaker button stays hidden.

const PREF = "callee:speaker"
const pref = {
  get() { try { return localStorage.getItem(PREF) === "1" } catch (_) { return false } },
  set(on) { try { localStorage.setItem(PREF, on ? "1" : "0") } catch (_) {} },
}

const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
const hasAudioSession = () => isIOS && "audioSession" in navigator

let outputs = {earpiece: null, speaker: null}
let speakerOn = pref.get()

async function discoverOutputs() {
  outputs = {earpiece: null, speaker: null}
  if (!("setSinkId" in HTMLMediaElement.prototype) || !navigator.mediaDevices?.enumerateDevices) return
  try {
    const outs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === "audiooutput")
    outputs.earpiece = outs.find(d => /earpiece|receiver|handset|phone call|^phone$/i.test(d.label)) || null
    outputs.speaker = outs.find(d => /speaker/i.test(d.label)) || null
  } catch (_) {}
}

/** Can this device switch between earpiece and loudspeaker? */
export function canSwitch() {
  return hasAudioSession() || !!(outputs.earpiece && outputs.speaker)
}

export function isSpeakerOn() { return speakerOn }

function applySession() {
  if (hasAudioSession()) {
    try { navigator.audioSession.type = speakerOn ? "auto" : "play-and-record" } catch (_) {}
  }
}

/** Route one <audio> element to the current choice (Android / desktop). */
export async function routeElement(el) {
  if (!el?.setSinkId) return
  const dev = speakerOn ? outputs.speaker : outputs.earpiece
  if (!dev) return
  try { await el.setSinkId(dev.deviceId) } catch (_) {}
}

function routeAll() {
  document.querySelectorAll("audio#call-audio, audio[data-group-mid]").forEach(routeElement)
}

/** Call when the call's microphone is opened (device labels are visible then). */
export async function prepareForCall() {
  speakerOn = pref.get()
  applySession()
  await discoverOutputs()
  routeAll()
}

export async function setSpeaker(on) {
  speakerOn = on
  pref.set(on)
  applySession()
  routeAll()
}

/** Restore the browser default after a call so other media isn't affected. */
export function releaseAfterCall() {
  if (hasAudioSession()) { try { navigator.audioSession.type = "auto" } catch (_) {} }
}

navigator.mediaDevices?.addEventListener?.("devicechange", async () => { await discoverOutputs(); routeAll() })
