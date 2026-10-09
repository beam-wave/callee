// Callee call engine: signalling over a Phoenix Channel, audio over WebRTC
// (P2P when possible, relayed through coturn otherwise), tenant-side recording.
import {Socket} from "phoenix"
import {setVapidKey, setConnection, showCallNotification, closeNotifications} from "./pwa"
import {prepareForCall, routeElement, setSpeaker, isSpeakerOn, canSwitch, releaseAfterCall} from "./audio_route"

const SPEAKER_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6"><path d="M13.5 4.06c0-1.336-1.616-2.005-2.56-1.06l-4.5 4.5H4.508c-1.141 0-2.318.664-2.66 1.905A9.76 9.76 0 0 0 1.5 12c0 .898.121 1.768.35 2.595.341 1.24 1.518 1.905 2.659 1.905h1.93l4.5 4.5c.945.945 2.561.276 2.561-1.06V4.06ZM18.584 5.106a.75.75 0 0 1 1.06 0c3.808 3.807 3.808 9.98 0 13.788a.75.75 0 0 1-1.06-1.06 8.25 8.25 0 0 0 0-11.668.75.75 0 0 1 0-1.06Z"/><path d="M15.932 7.757a.75.75 0 0 1 1.061 0 6 6 0 0 1 0 8.486.75.75 0 0 1-1.06-1.061 4.5 4.5 0 0 0 0-6.364.75.75 0 0 1 0-1.06Z"/></svg>`

const RING_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-7"><path fill-rule="evenodd" d="M1.5 4.5a3 3 0 0 1 3-3h1.372c.86 0 1.61.586 1.819 1.42l1.105 4.423a1.875 1.875 0 0 1-.694 1.955l-1.293.97c-.135.101-.164.249-.126.352a11.285 11.285 0 0 0 6.697 6.697c.103.038.25.009.352-.126l.97-1.293a1.875 1.875 0 0 1 1.955-.694l4.423 1.105c.834.209 1.42.959 1.42 1.82V19.5a3 3 0 0 1-3 3h-2.25C8.552 22.5 1.5 15.448 1.5 6.75V4.5Z" clip-rule="evenodd"/></svg>`
const HANG_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-7 rotate-[135deg]"><path fill-rule="evenodd" d="M1.5 4.5a3 3 0 0 1 3-3h1.372c.86 0 1.61.586 1.819 1.42l1.105 4.423a1.875 1.875 0 0 1-.694 1.955l-1.293.97c-.135.101-.164.249-.126.352a11.285 11.285 0 0 0 6.697 6.697c.103.038.25.009.352-.126l.97-1.293a1.875 1.875 0 0 1 1.955-.694l4.423 1.105c.834.209 1.42.959 1.42 1.82V19.5a3 3 0 0 1-3 3h-2.25C8.552 22.5 1.5 15.448 1.5 6.75V4.5Z" clip-rule="evenodd"/></svg>`
const MIC_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6"><path d="M8.25 4.5a3.75 3.75 0 1 1 7.5 0v8.25a3.75 3.75 0 1 1-7.5 0V4.5Z"/><path d="M6 10.5a.75.75 0 0 1 .75.75v1.5a5.25 5.25 0 1 0 10.5 0v-1.5a.75.75 0 0 1 1.5 0v1.5a6.751 6.751 0 0 1-6 6.709v2.291h3a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1 0-1.5h3v-2.291a6.751 6.751 0 0 1-6-6.709v-1.5A.75.75 0 0 1 6 10.5Z"/></svg>`

const END_TEXT = {
  completed: "Call ended", missed: "No answer", rejected: "Call declined",
  cancelled: "Call cancelled", missed_in: "Missed call", unreachable: "Not reachable right now", busy: "User is busy", failed: "Call failed",
}

function deviceId() {
  try {
    let id = sessionStorage.getItem("callee:device")
    if (!id) { id = crypto.randomUUID(); sessionStorage.setItem("callee:device", id) }
    return id
  } catch (_) { return crypto.randomUUID() }
}

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]))

// Prefer narrowband-friendly Opus: mono, FEC for lossy links, DTX during silence.
function tuneOpus(sdp) {
  const m = sdp.match(/a=rtpmap:(\d+) opus\/48000\/2/)
  if (!m) return sdp
  const pt = m[1]
  const extra = "stereo=0;sprop-stereo=0;useinbandfec=1;usedtx=1;maxaveragebitrate=32000"
  const re = new RegExp(`a=fmtp:${pt} ([^\\r\\n]*)`)
  return re.test(sdp)
    ? sdp.replace(re, (_l, p) => `a=fmtp:${pt} ${p};${extra}`)
    : sdp.replace(m[0], `${m[0]}\r\na=fmtp:${pt} ${extra}`)
}

// ---------------- Tones (WebAudio, no asset files) ----------------
class Tones {
  constructor() { this.ctx = null; this.timer = null; this.nodes = [] }
  _ctx() { this.ctx ||= new (window.AudioContext || window.webkitAudioContext)(); this.ctx.resume?.(); return this.ctx }
  _beep(freqs, dur, gain = 0.15) {
    const ctx = this._ctx(), g = ctx.createGain()
    g.gain.value = gain; g.connect(ctx.destination)
    const oscs = freqs.map(f => { const o = ctx.createOscillator(); o.frequency.value = f; o.connect(g); o.start(); o.stop(ctx.currentTime + dur); return o })
    this.nodes.push(g, ...oscs)
  }
  ringback() { this.stop(); const play = () => this._beep([440, 480], 2, 0.08); play(); this.timer = setInterval(play, 6000) }
  ringtone() {
    this.stop()
    const play = () => { this._beep([880, 660], 0.4); setTimeout(() => this._beep([880, 660], 0.4), 500); navigator.vibrate?.([400, 100, 400]) }
    play(); this.timer = setInterval(play, 3000)
  }
  busy() { this.stop(); let n = 0; const play = () => { if (n++ > 3) return this.stop(); this._beep([480, 620], 0.25, 0.08) }; play(); this.timer = setInterval(play, 500) }
  stop() {
    clearInterval(this.timer); this.timer = null; navigator.vibrate?.(0)
    this.nodes.forEach(n => { try { n.stop?.(); n.disconnect() } catch (_) {} }); this.nodes = []
  }
}

// ---------------- Tenant-side recorder ----------------
// RECORDING_MODE=client only. Mixes both voices and uploads 1-minute chunks
// DURING the call, so a crashed tab or dead battery loses at most ~1 minute and
// browser memory stays flat on long calls. Chunks of one MediaRecorder
// concatenate into a valid file; the server appends them in order.
class CallRecorder {
  constructor(callId, localStream, remoteStream) {
    this.callId = callId
    this.ctx = new (window.AudioContext || window.webkitAudioContext)()
    this.dest = this.ctx.createMediaStreamDestination()
    this.sources = [localStream, remoteStream].map(s => { const src = this.ctx.createMediaStreamSource(s); src.connect(this.dest); return src })
    const types = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4;codecs=mp4a.40.2", "audio/mp4", "audio/ogg;codecs=opus"]
    this.mimeType = types.find(t => window.MediaRecorder?.isTypeSupported?.(t)) || ""
    this.rec = new MediaRecorder(this.dest.stream, {...(this.mimeType && {mimeType: this.mimeType}), audioBitsPerSecond: 32000})
    this.pending = []
    this.seq = 0
    this.queue = Promise.resolve()
    this.rec.ondataavailable = e => e.data?.size && this.pending.push(e.data)
    this.startedAt = Date.now()
    this.rec.start(1000)
    this.flushTimer = setInterval(() => this.flush(false), 60_000)
  }

  get type() { return (this.rec.mimeType || this.mimeType || "audio/webm").split(";")[0] }

  flush(final) {
    const parts = this.pending; this.pending = []
    if (!parts.length && !final) return this.queue
    const blob = new Blob(parts, {type: this.type})
    const seq = this.seq++
    const duration = Math.round((Date.now() - this.startedAt) / 1000)
    this.queue = this.queue.then(() => this.send(blob, seq, final, duration))
    return this.queue
  }

  async send(blob, seq, final, duration, attempt = 1) {
    const csrf = document.querySelector("meta[name='csrf-token']").content
    const fd = new FormData()
    fd.append("file", blob, `part-${seq}`)
    fd.append("seq", seq); fd.append("duration", duration)
    if (final) fd.append("final", "1")
    try {
      const res = await fetch(`/tenant/calls/${this.callId}/recording`, {method: "POST", body: fd, headers: {"x-csrf-token": csrf}, credentials: "same-origin"})
      if (res.status === 409) {
        const {expected} = await res.json()
        if (expected > seq) return // server already has it
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
    } catch (err) {
      if (attempt >= 8) { console.error("recording chunk lost", seq, err); return }
      await new Promise(r => setTimeout(r, Math.min(30_000, 1000 * 2 ** attempt)))
      return this.send(blob, seq, final, duration, attempt + 1)
    }
  }

  stop() {
    clearInterval(this.flushTimer)
    return new Promise(resolve => {
      const done = () => {
        this.sources.forEach(s => s.disconnect()); this.ctx.close()
        this.flush(true).then(resolve)
      }
      if (this.rec.state === "inactive") return done()
      this.rec.onstop = done
      this.rec.stop()
    })
  }
}

// ---------------- Call manager ----------------
export class CallManager {
  constructor({token, role}) {
    this.role = role
    this.device = deviceId()
    this.tones = new Tones()
    this.call = null        // {id, direction, peer:{name}, state, startedAt}
    this.pc = null
    this.localStream = null
    this.remoteStream = null
    this.pendingIce = []
    this.recorder = null
    this.uploads = 0
    this.iceServers = []
    this.root = document.getElementById("call-root")
    this.uid = document.querySelector("meta[name='call-uid']")?.content
    this.joinable = new Map()

    this.socket = new Socket("/socket", {params: {token, device_id: this.device}})
    setConnection("connecting")
    this.socket.onOpen(() => setConnection("online"))
    this.socket.onError(() => setConnection("offline"))
    this.socket.onClose(() => setConnection("offline"))
    this.socket.connect()
    this.channel = null
    this.joinChannel()

    document.addEventListener("click", e => {
      const btn = e.target.closest("[data-call-peer]")
      if (btn) { e.preventDefault(); this.startCall(btn.dataset.callPeer, btn.dataset.callName) }
      const grp = e.target.closest("[data-group-call]")
      if (grp) { e.preventDefault(); this.startGroup(grp.dataset.groupCall.split(",").filter(Boolean), JSON.parse(grp.dataset.groupNames || "[]"), grp.dataset.savedGroup, grp.dataset.groupName) }
      const join = e.target.closest("[data-join-live]")
      if (join) { e.preventDefault(); this.joinLive(join.dataset.joinLive) }
      const ring = e.target.closest("[data-ring-again]")
      if (ring && this.call?.group?.host) {
        e.preventDefault()
        this.channel.push("group:ring", {call_id: this.call.id, client_id: ring.dataset.ringAgain})
          .receive("error", ({reason}) => this.flash(reason === "busy" ? "They're on another call" : "Couldn't ring them"))
      }
    })
    window.addEventListener("beforeunload", e => {
      if (this.call?.state === "active" || this.uploads > 0) { e.preventDefault(); e.returnValue = "" }
    })
    // P2P media dies with the page, so hang up. Server-mode calls survive a
    // reload (the tab resumes its leg); a closed tab ends after the grace period.
    window.addEventListener("pagehide", () => {
      if (this.call?.id && this.call.media !== "server") this.channel?.push("call:hangup", {call_id: this.call.id})
    })
  }

  joinChannel() {
    // Topic id comes from the server-rendered meta; the server rejects other topics.
    const uid = document.querySelector("meta[name='call-uid']")?.content
    this.channel = this.socket.channel(`user:${this.role}:${uid}`, {})
    this.channel.join()
      .receive("ok", reply => this.onJoined(reply))
      .receive("error", err => console.error("join failed", err))

    this.channel.on("call:incoming", p => this.onIncoming(p))
    this.channel.on("call:ringing", p => this.onRinging(p))
    this.channel.on("call:reach", p => { if (this.call?.id === p.call_id) this.applyReach(p.reach) })
    this.channel.on("call:accepted", p => this.onAccepted(p))
    this.channel.on("call:ended", p => this.onEnded(p))
    this.channel.on("signal", p => this.onSignal(p))
    this.channel.on("media", p => this.onSignal(p))
    this.channel.on("group:roster", p => this.onRoster(p))
    // Live group calls this client was invited to and can still join.
    this.channel.on("group:live", p => { this.joinable.set(p.call_id, p); this.renderLiveBar() })
    this.channel.on("group:gone", p => { this.joinable.delete(p.call_id); this.renderLiveBar() })
    this.channel.on("group:slots", p => {
      if (this.call?.group && this.call.id === p.call_id && p.to_device === this.device) { this.call.group.mids = p.slots; this.renderGrid() }
    })
    this.channel.on("call:peer", p => {
      if (this.call?.id !== p.call_id) return
      this.call.peerReconnecting = p.state === "reconnecting"; this.render()
    })
  }

  onJoined({ice_servers, active_call, vapid_public_key, media_mode, browser_records, joinable}) {
    this.joinable = new Map((joinable || []).map(j => [j.call_id, j]))
    this.renderLiveBar()
    this.iceServers = ice_servers || []
    this.mediaMode = media_mode
    this.browserRecords = browser_records
    this.vapidKey = vapid_public_key
    setVapidKey(vapid_public_key)

    // Re-join after reload or after opening from a push notification.
    if (!active_call) {
      if (this.call && this.call.state !== "ended") this.finishLocal("failed")
      return
    }
    const meCaller = active_call.caller.type === this.role
    if (active_call.status === "ringing" && !meCaller && !this.call) {
      const others = active_call.kind === "group" ? {others: active_call.participants.length - 2} : null
      this.onIncoming({call_id: active_call.call_id, from: active_call.caller_view, group: others})
    } else if (!this.call) {
      const mine = meCaller ? active_call.caller_device : active_call.callee_device
      if (active_call.status === "active" && mine === this.device && media_mode === "server") {
        // Page was reloaded mid-call: media goes via the server, so just reconnect our leg.
        this.resumeServerCall(active_call, meCaller)
      } else if (mine === this.device || mine == null) {
        // P2P media lived in the tab that's gone; end it cleanly.
        this.channel.push("call:hangup", {call_id: active_call.call_id})
      }
    }
  }

  async resumeServerCall(ac, meCaller) {
    this.call = {id: ac.call_id, direction: meCaller ? "out" : "in", peer: meCaller ? ac.callee_view : ac.caller_view, state: "connecting", media: "server"}
    if (ac.kind === "group") this.call.group = {slots: ac.slots, participants: ac.participants, mids: {}, host: meCaller}
    this.render()
    try { await this.getMic() } catch (_) { return this.hangup() }
    this.createPeer(); this.makeOffer()
  }

  // ---------- group (tenant host) ----------
  async startGroup(ids, names, savedGroupId, groupName) {
    if (this.call) return this.flash("You are already in a call")
    if (ids.length < 2) return this.flash("Pick at least 2 people for a group call")
    const participants = names.map((n, i) => ({key: `c${ids[i]}`, name: n, status: "ringing"}))
    this.call = {id: null, direction: "out", peer: {name: "Group call"}, state: "starting", media: "server",
                 group: {host: true, name: groupName, slots: 0, participants, mids: {}}}
    this.render()
    try { await this.getMic() } catch (_) {
      this.call = null; this.render(); return this.flash("Microphone access is needed to make calls")
    }
    this.channel.push("group:start", savedGroupId ? {group_id: savedGroupId} : {client_ids: ids})
      .receive("ok", ({call_id, slots}) => {
        if (!this.call) return
        Object.assign(this.call, {id: call_id, state: "ringing", reach: "ringing"})
        this.call.group.slots = slots
        this.tones.ringback()
        // The host joins the room right away; others are added as they answer.
        this.createPeer(); this.makeOffer()
        this.render()
      })
      .receive("error", ({reason}) => {
        this.stopMedia(); this.call = null; this.render()
        this.flash({all_busy: "Everyone you picked is on another call", bad_group_size: "Pick between 2 and 7 people", busy: "You're already in a call"}[reason] || `Group call failed: ${reason}`)
      })
  }

  // Client: join a live group call they missed / declined / left.
  joinLive(callId) {
    const j = this.joinable.get(callId)
    if (!j || this.call) return
    this.joinable.delete(callId); this.renderLiveBar()
    this.onIncoming({call_id: callId, from: j.from, group: {others: j.others, name: j.name}, silent: true})
    this.accept()
  }

  renderLiveBar() {
    let el = document.getElementById("group-live-bar")
    const items = [...this.joinable.values()]
    if (this.call || !items.length || this.role !== "client") { el?.remove(); return }
    if (!el) { el = document.createElement("div"); el.id = "group-live-bar"; document.body.appendChild(el) }
    el.className = "fixed inset-x-0 bottom-16 sm:bottom-4 z-40 px-3 flex flex-col gap-2 pointer-events-none"
    el.innerHTML = items.map(j => `
      <div class="pointer-events-auto mx-auto w-full max-w-3xl rounded-2xl shadow-xl bg-emerald-600 text-white p-3 flex items-center gap-3" role="status">
        <span class="relative flex size-3 shrink-0"><span class="absolute inline-flex size-full rounded-full bg-white/70 animate-ping"></span><span class="relative inline-flex size-3 rounded-full bg-white"></span></span>
        <div class="flex-1 min-w-0">
          <div class="font-semibold truncate">${esc(j.from?.name || "")}${j.name ? " · " + esc(j.name) : ""}</div>
          <div class="text-sm text-white/85">Group call in progress · ${j.count} in call</div>
        </div>
        <button data-join-live="${esc(j.call_id)}" class="btn btn-sm bg-white text-emerald-700 border-0 rounded-full px-5">Join</button>
      </div>`).join("")
  }

  onRoster({call_id, participants}) {
    if (!this.call?.group || this.call.id !== call_id) return
    this.call.group.participants = participants
    // Host: stop ringback once somebody joins.
    if (this.call.group.host && participants.some(p => !p.host && p.status === "joined")) {
      this.tones.stop()
      if (!this.call.group.anyoneJoined) { this.call.group.anyoneJoined = true; this.call.startedAt = Date.now() }
    }
    this.render()
  }

  // ---------- outgoing ----------
  async startCall(peerId, name) {
    if (this.call) return this.flash("You are already in a call")
    this.call = {id: null, direction: "out", peer: {name}, state: "starting"}
    this.render()
    try {
      await this.getMic()
    } catch (err) {
      this.call = null; this.render()
      return this.flash("Microphone access is needed to make calls")
    }
    this.channel.push("call:start", {peer_id: peerId})
      .receive("ok", ({call_id}) => {
        if (!this.call) return
        this.call.id = call_id; this.call.state = "ringing"
        this.applyReach(this.call.reach || "calling")
      })
      .receive("error", ({reason}) => {
        this.stopMedia()
        if (reason === "busy") { this.tones.busy(); this.call.state = "ended"; this.call.endText = END_TEXT.busy; this.render(); setTimeout(() => this.clear(), 2500) }
        else { this.call = null; this.render(); this.flash(reason === "tenant_inactive" ? "This account is not active" : `Call failed: ${reason}`) }
      })
      .receive("timeout", () => { this.stopMedia(); this.call = null; this.render(); this.flash("Network problem, try again") })
  }

  onRinging(p) {
    // Another of my tabs placed the call; nothing to do here.
    if (p.device !== this.device || !this.call || this.call.direction !== "out") return
    // May arrive before the call:start reply; remember it either way.
    this.call.reach = p.reach
    if (this.call.state === "ringing") this.applyReach(p.reach)
  }

  // "calling": nothing has reached the other person yet (offline, no push).
  // "ringing": a device of theirs is alerting. Ringback only plays when ringing.
  applyReach(reach) {
    if (!this.call || this.call.direction !== "out") return
    const was = this.call.reach
    this.call.reach = reach
    if (this.call.state === "ringing" && (reach !== was || !this.tones.timer)) {
      if (reach === "ringing") this.tones.ringback(); else this.tones.stop()
    }
    this.render()
  }

  // ---------- incoming ----------
  onIncoming({call_id, from, group, silent}) {
    // A new call may arrive while the previous "Call ended" screen is still showing.
    if (this.call?.state === "ended") { clearTimeout(this.clearTimer); this.call = null }
    if (this.call) return // server already blocks double calls; ignore stale
    this.call = {id: call_id, direction: "in", peer: from, state: "incoming"}
    if (group) this.call.group = {host: false, others: group.others, name: group.name, slots: 0, participants: [], mids: {}}
    this.renderLiveBar()
    if (silent) return
    this.tones.ringtone()
    this.render()
    if (document.hidden) showCallNotification("Incoming call", `${from?.name || "Someone"} is calling you`, `call-${call_id}`)
  }

  async accept() {
    if (!this.call || this.call.state !== "incoming") return
    this.tones.stop()
    this.call.state = "connecting"; this.render()
    try { await this.getMic() } catch (_) {
      this.flash("Microphone access is needed to answer"); return this.reject()
    }
    this.channel.push("call:accept", {call_id: this.call.id})
      .receive("ok", p => {
        if (!this.call) return
        this.call.media = p.media
        if (p.group && this.call.group) this.call.group.slots = p.slots
        this.createPeer()
        // Server mode: each side offers to the server. P2P: wait for the caller's offer.
        if (p.media === "server") this.makeOffer()
      })
      .receive("error", () => { this.stopMedia(); this.clear() })
  }

  reject() {
    if (!this.call) return
    this.tones.stop()
    this.channel.push("call:reject", {call_id: this.call.id})
    this.stopMedia(); this.clear()
  }

  hangup() {
    if (!this.call) return
    if (this.call.id) this.channel.push("call:hangup", {call_id: this.call.id})
    else { this.stopMedia(); this.clear() }
  }

  // ---------- server state events ----------
  onAccepted({call_id, caller_device, callee_device, media}) {
    if (!this.call || this.call.id !== call_id) return
    if (this.call.direction === "in" && callee_device !== this.device) {
      // Answered on another device/tab.
      this.tones.stop(); this.stopMedia(); this.clear(); return
    }
    if (this.call.direction === "out" && caller_device === this.device) {
      this.tones.stop()
      this.call.state = "connecting"; this.call.media = media; this.render()
      this.createPeer(); this.makeOffer()
    }
  }

  onEnded({call_id, status, duration}) {
    if (!this.call || this.call.id !== call_id) return
    let s = status
    if (status === "missed" && this.call.direction === "in") s = "missed_in"
    else if (status === "missed" && this.call.reach === "calling") s = "unreachable"
    this.finishLocal(s)
    closeNotifications(`call-${call_id}`)
  }

  async finishLocal(status) {
    this.tones.stop()
    const callId = this.call.id
    const rec = this.recorder; this.recorder = null
    this.stopMedia()
    this.call.state = "ended"; this.call.endText = END_TEXT[status] || "Call ended"
    this.render()
    clearTimeout(this.clearTimer)
    this.clearTimer = setTimeout(() => { if (this.call?.state === "ended") this.clear() }, 1800)
    if (rec && callId) {
      this.uploads++
      try { await rec.stop() } finally { this.uploads-- }
    }
  }

  // ---------- WebRTC ----------
  async getMic() {
    if (this.localStream) return this.localStream
    this.localStream = await navigator.mediaDevices.getUserMedia({
      audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1},
      video: false,
    })
    // Earpiece by default where the device allows it (user can switch to speaker).
    await prepareForCall()
    return this.localStream
  }

  async toggleSpeaker() {
    await setSpeaker(!isSpeakerOn())
    this.render()
  }

  createPeer() {
    const pc = new RTCPeerConnection({iceServers: this.iceServers, bundlePolicy: "max-bundle"})
    this.pc = pc
    this.remoteStream = new MediaStream()
    this.localStream.getTracks().forEach(t => pc.addTrack(t, this.localStream))
    // Group: fixed receive lines, one per possible other participant (server fills them).
    if (this.call?.group) for (let i = 1; i < this.call.group.slots; i++) pc.addTransceiver("audio", {direction: "recvonly"})

    pc.onicecandidate = e => e.candidate && this.sendSignal({type: "candidate", candidate: e.candidate.toJSON()})
    pc.ontrack = e => {
      if (this.call?.group) return this.playGroupTrack(e)
      this.remoteStream.addTrack(e.track)
      const audio = this.audioEl()
      audio.srcObject = this.remoteStream
      audio.play().catch(() => {})
    }
    pc.onconnectionstatechange = () => {
      const s = pc.connectionState
      if (!this.call) return
      if (s === "connected") {
        if (this.call.state !== "active") {
          this.call.state = "active"; this.call.startedAt = Date.now(); this.startTimer()
          if (this.call.group) this.startSpeakingMeter()
          if (this.role === "tenant" && this.browserRecords && !this.recorder && !this.call.group) {
            try { this.recorder = new CallRecorder(this.call.id, this.localStream, this.remoteStream) } catch (err) { console.error("recorder", err) }
          }
          requestWakeLock(this)
        }
        this.call.reconnecting = false; this.render()
      } else if (s === "disconnected") {
        this.call.reconnecting = true; this.render()
      } else if (s === "failed") {
        // ICE restart from the caller side; the server ends the call if a tab dies.
        // Server mode: each leg is ours to restart. P2P: the caller restarts.
        if (this.call.media === "server" || this.call.direction === "out") this.makeOffer(true)
        this.call.reconnecting = true; this.render()
      }
    }
  }

  async makeOffer(iceRestart = false) {
    const offer = await this.pc.createOffer({iceRestart})
    offer.sdp = tuneOpus(offer.sdp)
    await this.pc.setLocalDescription(offer)
    this.sendSignal({type: "offer", sdp: offer.sdp})
  }

  async onSignal({call_id, to_device, data}) {
    if (to_device !== this.device || !this.call || this.call.id !== call_id || !this.pc) return
    const pc = this.pc
    try {
      if (data.type === "offer") {
        await pc.setRemoteDescription({type: "offer", sdp: data.sdp})
        await this.flushIce()
        const answer = await pc.createAnswer()
        answer.sdp = tuneOpus(answer.sdp)
        await pc.setLocalDescription(answer)
        this.sendSignal({type: "answer", sdp: answer.sdp})
      } else if (data.type === "answer") {
        await pc.setRemoteDescription({type: "answer", sdp: data.sdp})
        await this.flushIce()
      } else if (data.type === "candidate") {
        if (pc.remoteDescription) await pc.addIceCandidate(data.candidate)
        else this.pendingIce.push(data.candidate)
      }
    } catch (err) { console.error("signal error", err) }
  }

  async flushIce() {
    const q = this.pendingIce; this.pendingIce = []
    for (const c of q) { try { await this.pc.addIceCandidate(c) } catch (_) {} }
  }

  sendSignal(data) {
    if (!this.call?.id) return
    this.channel.push(this.call.media === "server" ? "media" : "signal", {call_id: this.call.id, data})
  }

  stopMedia() {
    clearInterval(this.timer)
    releaseAfterCall()
    this.pc?.close(); this.pc = null
    this.localStream?.getTracks().forEach(t => t.stop()); this.localStream = null
    this.remoteStream = null; this.pendingIce = []
    const a = document.getElementById("call-audio"); if (a) a.srcObject = null
    clearInterval(this.meter); this.meter = null
    this.analysers = {}; this.meterCtx?.close?.().catch(() => {}); this.meterCtx = null
    document.querySelectorAll("audio[data-group-mid]").forEach(el => { el.srcObject = null; el.remove() })
    this.wakeLock?.release?.().catch(() => {}); this.wakeLock = null
  }

  toggleMute() {
    const t = this.localStream?.getAudioTracks()[0]
    if (!t) return
    t.enabled = !t.enabled; this.call.muted = !t.enabled; this.render()
  }

  clear() { this.call = null; this.render(); this.renderLiveBar() }

  audioEl() {
    let a = document.getElementById("call-audio")
    if (!a) { a = document.createElement("audio"); a.id = "call-audio"; a.autoplay = true; a.setAttribute("playsinline", ""); document.body.appendChild(a); routeElement(a) }
    return a
  }

  startTimer() {
    clearInterval(this.timer)
    this.timer = setInterval(() => {
      const el = document.getElementById("call-timer")
      if (el && this.call?.startedAt) el.textContent = fmt(Math.floor((Date.now() - this.call.startedAt) / 1000))
    }, 1000)
  }

  flash(msg) {
    const t = document.createElement("div")
    t.className = "toast toast-top toast-center z-[60]"
    t.innerHTML = `<div class="alert alert-warning">${esc(msg)}</div>`
    document.body.appendChild(t); setTimeout(() => t.remove(), 3500)
  }

  // ---------- group media ----------
  playGroupTrack(e) {
    const mid = e.transceiver?.mid
    let el = document.querySelector(`audio[data-group-mid="${mid}"]`)
    if (!el) { el = document.createElement("audio"); el.autoplay = true; el.setAttribute("playsinline", ""); el.dataset.groupMid = mid; document.body.appendChild(el); routeElement(el) }
    el.srcObject = new MediaStream([e.track])
    el.play().catch(() => {})
    // Level meter per receive line (RTP audio-level extensions aren't negotiated).
    try {
      this.meterCtx ||= new (window.AudioContext || window.webkitAudioContext)()
      const an = this.meterCtx.createAnalyser(); an.fftSize = 256
      this.meterCtx.createMediaStreamSource(new MediaStream([e.track])).connect(an)
      ;(this.analysers ||= {})[mid] = {an, buf: new Uint8Array(an.fftSize)}
    } catch (_) {}
  }

  // Who is talking: audio level per receive line, mapped to people via the server's slot map.
  startSpeakingMeter() {
    clearInterval(this.meter)
    this.meter = setInterval(() => {
      const g = this.call?.group
      if (!g || !this.pc) return
      const speaking = new Set()
      for (const [mid, {an, buf}] of Object.entries(this.analysers || {})) {
        an.getByteTimeDomainData(buf)
        let peak = 0
        for (const v of buf) peak = Math.max(peak, Math.abs(v - 128))
        const who = g.mids?.[mid]
        if (who && peak > 6) speaking.add(who)
      }
      const key = [...speaking].sort().join(",")
      if (key !== g.speakingKey) { g.speaking = speaking; g.speakingKey = key; this.renderGrid() }
    }, 350)
  }

  renderGrid() {
    const el = document.getElementById("group-grid")
    const g = this.call?.group
    if (!el || !g) return
    const label = {ringing: "Ringing…", joined: "In call", declined: "Declined", missed: "No answer", left: "Left", busy: "Busy"}
    const me = this.role === "tenant" ? "host" : `c${this.uid}`
    const order = {joined: 0, ringing: 1, left: 2, busy: 3, declined: 4, missed: 5}
    const people = (g.participants || [])
      .filter(p => p.key !== me)
      .sort((a, b) =>
        (b.host - a.host) ||
        ((g.speaking?.has(b.key) ? 1 : 0) - (g.speaking?.has(a.key) ? 1 : 0)) ||
        ((order[a.status] ?? 9) - (order[b.status] ?? 9)) ||
        a.name.localeCompare(b.name))
    // Big groups: compact tiles, cap what we draw, show "+N more".
    const big = people.length > 12
    const shown = big ? people.slice(0, 40) : people
    const more = people.length - shown.length
    el.className = big
      ? "mt-4 grid grid-cols-4 sm:grid-cols-5 gap-x-2 gap-y-4 w-full max-h-[50dvh] overflow-y-auto px-1"
      : "mt-6 flex flex-wrap justify-center gap-x-4 gap-y-6 w-full"
    el.innerHTML = shown.map(p => {
      const talking = g.speaking?.has(p.key)
      const faded = ["declined", "missed", "left", "busy"].includes(p.status)
      const canRing = g.host && faded
      const cid = p.key.slice(1)
      return `<div ${big && canRing ? `data-tile-ring="${esc(cid)}" title="Tap to ring again" role="button"` : ""} class="flex flex-col items-center gap-1.5 ${big ? "w-full" : "w-20"}">
        <div class="contents ${faded ? "[&>*:not(button)]:opacity-40" : ""}">
        <div class="relative">
          ${p.status === "ringing" ? `<span class="absolute inset-0 rounded-full bg-white/25 animate-ping"></span>` : ""}
          <div class="relative ${big ? "size-12 text-base" : "size-16 text-xl"} rounded-full bg-white/15 flex items-center justify-center font-semibold transition
                      ${talking ? "ring-4 ring-emerald-400 scale-105" : "ring-2 ring-white/20"}">${esc(p.name).charAt(0)}</div>
        </div>
        <div class="text-sm font-medium truncate max-w-full">${esc(p.host ? p.name + " (host)" : p.name)}</div>
        <div class="text-xs text-white/60">${talking ? "Speaking" : label[p.status] || ""}</div>
        </div>
        ${canRing && !big ? `<button data-ring-again="${esc(cid)}" class="btn btn-xs rounded-full bg-white/20 hover:bg-white/30 border-0 text-white">Ring again</button>` : ""}
      </div>`
    }).join("") + (more > 0 ? `<div class="col-span-full text-sm text-white/70 text-center">+${more} more</div>` : "")
    // In big groups, tapping a faded tile rings that person again (no button clutter).
    if (big && g.host) el.querySelectorAll("[data-tile-ring]").forEach(t => t.addEventListener("click", () => t.dataset.tileRing && this.channel.push("group:ring", {call_id: this.call.id, client_id: t.dataset.tileRing})))
  }

  // ---------- UI ----------
  render() {
    const c = this.call
    if (!c) { this.root.innerHTML = ""; return }
    if (c.group && c.state !== "incoming") return this.renderGroup()
    const name = esc(c.peer?.name || "Unknown")
    const sub = esc(c.peer?.subtitle || "")
    const status = c.reconnecting ? "Reconnecting…" : c.peerReconnecting ? "Waiting for connection…" : {
      starting: "Calling…", ringing: c.reach === "ringing" ? "Ringing…" : "Calling…",
      incoming: c.group ? `${c.group.name ? esc(c.group.name) + " · " : "Group call · "}you and ${c.group.others} other${c.group.others === 1 ? "" : "s"}` : "Audio call", connecting: "Connecting…",
      active: `<span id="call-timer">${fmt(Math.floor((Date.now() - (c.startedAt || Date.now())) / 1000))}</span>`,
      ended: esc(c.endText || "Call ended"),
    }[c.state]
    const notice = c.state === "ringing" && c.reach !== "ringing"
      ? `<span class="text-sm text-white/75 max-w-64 inline-block">${name.split(" ")[0]} isn't online right now. We'll keep trying for a little while.</span>`
      : c.state === "active"
      ? (this.role === "tenant" && (this.recorder || c.media === "server") ? `<span class="badge badge-error gap-1"><span class="size-2 rounded-full bg-white animate-pulse"></span>REC</span>` : `<span class="text-sm text-white/70">This call may be recorded</span>`)
      : ""
    const btn = (act, label, cls, icon, extra = "") =>
      `<div class="flex flex-col items-center gap-2">
         <button data-act="${act}" class="btn btn-circle size-[72px] border-0 shadow-lg active:scale-95 transition ${cls} ${extra}" aria-label="${label}">${icon}</button>
         <span class="text-sm text-white/80">${label}</span>
       </div>`
    let buttons = ""
    if (c.state === "incoming") {
      buttons = btn("reject", "Decline", "bg-red-500 hover:bg-red-600 text-white", HANG_ICON) +
                btn("accept", "Accept", "bg-emerald-500 hover:bg-emerald-600 text-white", RING_ICON, "animate-bounce")
    } else if (c.state !== "ended") {
      const mute = c.state === "active"
        ? btn("mute", c.muted ? "Unmute" : "Mute", c.muted ? "bg-white text-gray-900" : "bg-white/15 hover:bg-white/25 text-white", MIC_ICON) + speakerBtn(btn)
        : ""
      buttons = mute + btn("hangup", "End", "bg-red-500 hover:bg-red-600 text-white", HANG_ICON)
    }
    const alerting = c.state === "incoming" || (c.state === "ringing" && c.reach === "ringing")
    // Phones: full-screen like the native dialer. Larger screens: centred card.
    this.root.innerHTML = `
      <div class="fixed inset-0 z-50 sm:bg-black/50 sm:backdrop-blur-sm sm:flex sm:items-center sm:justify-center" role="dialog" aria-modal="true" aria-label="Call with ${name}">
        <div class="h-full sm:h-auto w-full sm:max-w-sm sm:rounded-3xl overflow-hidden bg-gradient-to-b from-indigo-600 via-violet-700 to-slate-900 text-white shadow-2xl
                    flex flex-col items-center justify-between text-center px-6
                    pt-[calc(env(safe-area-inset-top)+3rem)] pb-[calc(env(safe-area-inset-bottom)+2.5rem)] sm:py-12">
          <div class="flex flex-col items-center gap-3 mt-4">
            <div class="text-sm uppercase tracking-widest text-white/60">${c.direction === "in" ? "Incoming call" : "Outgoing call"}</div>
            <div class="relative my-6">
              ${alerting ? `<span class="absolute inset-0 rounded-full bg-white/25 animate-ping"></span>` : ""}
              <div class="relative size-32 rounded-full bg-white/15 ring-4 ring-white/20 flex items-center justify-center text-5xl font-semibold">${name.charAt(0)}</div>
            </div>
            <div class="text-3xl font-semibold leading-tight break-words max-w-full">${name}</div>
            ${sub ? `<div class="text-white/60">${sub}</div>` : ""}
            <div class="text-xl text-white/85 mt-1" aria-live="polite">${status}</div>
            <div>${notice}</div>
          </div>
          <div class="flex justify-center gap-14 w-full">${buttons}</div>
        </div>
      </div>`
    this.root.querySelectorAll("[data-act]").forEach(b => b.addEventListener("click", () => {
      ({accept: () => this.accept(), reject: () => this.reject(), hangup: () => this.hangup(), mute: () => this.toggleMute(), speaker: () => this.toggleSpeaker()})[b.dataset.act]()
    }))
  }
}

// Speaker toggle, only where the device lets us switch output.
const speakerBtn = btn => canSwitch()
  ? btn("speaker", "Speaker", isSpeakerOn() ? "bg-white text-gray-900" : "bg-white/15 hover:bg-white/25 text-white", SPEAKER_ICON)
  : ""

const fmt = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`

CallManager.prototype.renderGroup = function () {
  const c = this.call, g = c.group
  const joined = (g.participants || []).filter(p => !p.host && p.status === "joined").length
  const invited = (g.participants || []).filter(p => !p.host).length
  let status
  if (c.state === "ended") status = esc(c.endText || "Call ended")
  else if (c.reconnecting) status = "Reconnecting…"
  else if (g.host && !g.anyoneJoined) status = c.state === "starting" ? "Starting…" : `Ringing ${invited} people…`
  else if (c.state === "active" || g.anyoneJoined) status = `<span id="call-timer">${fmt(Math.floor((Date.now() - (c.startedAt || Date.now())) / 1000))}</span> · ${joined + 1} in call`
  else status = "Connecting…"
  const title = g.host ? (g.name ? esc(g.name) : "Group call") : `${esc(c.peer?.name || "")} · ${g.name ? esc(g.name) : "Group call"}`
  const rec = c.state === "active" ? (this.role === "tenant" ? `<span class="badge badge-error gap-1"><span class="size-2 rounded-full bg-white animate-pulse"></span>REC</span>` : `<span class="text-sm text-white/70">This call may be recorded</span>`) : ""
  const btn = (act, label, cls, icon) =>
    `<div class="flex flex-col items-center gap-2">
       <button data-act="${act}" class="btn btn-circle size-[72px] border-0 shadow-lg active:scale-95 transition ${cls}" aria-label="${label}">${icon}</button>
       <span class="text-sm text-white/80">${label}</span></div>`
  const buttons = c.state === "ended" ? "" :
    (c.state === "active" ? btn("mute", c.muted ? "Unmute" : "Mute", c.muted ? "bg-white text-gray-900" : "bg-white/15 hover:bg-white/25 text-white", MIC_ICON) + speakerBtn(btn) : "") +
    btn("hangup", g.host ? "End for all" : "Leave", "bg-red-500 hover:bg-red-600 text-white", HANG_ICON)
  this.root.innerHTML = `
    <div class="fixed inset-0 z-50 sm:bg-black/50 sm:backdrop-blur-sm sm:flex sm:items-center sm:justify-center" role="dialog" aria-modal="true" aria-label="Group call">
      <div class="h-full sm:h-auto w-full sm:max-w-md sm:rounded-3xl overflow-y-auto bg-gradient-to-b from-indigo-600 via-violet-700 to-slate-900 text-white shadow-2xl
                  flex flex-col items-center justify-between text-center px-5
                  pt-[calc(env(safe-area-inset-top)+2.5rem)] pb-[calc(env(safe-area-inset-bottom)+2.5rem)] sm:py-10 gap-6">
        <div class="flex flex-col items-center gap-2 w-full">
          <div class="text-sm uppercase tracking-widest text-white/60">${title}</div>
          <div class="text-xl text-white/90" aria-live="polite">${status}</div>
          ${rec}
          <div id="group-grid" class="mt-6 flex flex-wrap justify-center gap-x-4 gap-y-6 w-full"></div>
        </div>
        <div class="flex justify-center gap-14 w-full">${buttons}</div>
      </div>
    </div>`
  this.renderGrid()
  this.root.querySelectorAll("[data-act]").forEach(b => b.addEventListener("click", () => {
    ({hangup: () => this.hangup(), mute: () => this.toggleMute(), speaker: () => this.toggleSpeaker()})[b.dataset.act]()
  }))
}

async function requestWakeLock(mgr) {
  try { mgr.wakeLock = await navigator.wakeLock?.request("screen") } catch (_) {}
}

