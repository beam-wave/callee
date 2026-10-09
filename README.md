# Callee: one-to-one audio calling (Phoenix + coturn + Postgres + S3)

Web app for voice calls between **tenants** and their **clients**, with tenant-side
call recording.

```
Admin ──creates──▶ Tenant (username/password, expiry)
Tenant ──adds────▶ Client (mobile/password)  ← same mobile can belong to many tenants
Tenant ⇄ Client    audio calls (either side can call)
Tenant             sees call history + recordings; client sees history only
```

## Quick start

```bash
cp .env.example .env          # set SECRET_KEY_BASE and ADMIN_PASSWORD
docker compose up -d --build
```

| URL | Who |
|-----|-----|
| http://localhost:4000/admin/login | Admin (ADMIN_USERNAME / ADMIN_PASSWORD from .env) |
| http://localhost:4000/tenant/login | Tenant |
| http://localhost:4000/login | Client (mobile number) |

One role per browser session. To try a call on one machine, use two browsers or
a normal + private window (or `localhost` for one and `127.0.0.1` for the other).

Services: `app` (Phoenix release, runs migrations on boot), `db` (Postgres 17),
`s3` (SeaweedFS, S3-compatible), `coturn` (STUN/TURN), and optional `caddy` (TLS).

## How a call works

1. Every open tab of a tenant/client joins the Phoenix channel `user:<role>:<id>`.
2. Caller sends `call:start`. The server checks the pair is in an address book,
   the tenant is active and neither side is busy, writes a `calls` row (`ringing`)
   and starts a `CallServer` process for the call.
3. The callee is notified two ways:
   - **App open (any tab, even backgrounded):** `call:incoming` over the websocket,
     which shows the ringing screen and plays a ringtone.
   - **App closed / phone locked:** a **Web Push** notification ("X is calling you")
     sent through the browser's push service, shown by the service worker
     (`priv/static/sw.js`). Tapping it opens the app, which re-joins the channel
     and gets the still-ringing call.
4. Callee accepts on one device. Other devices of the callee stop ringing. The
   caller creates the WebRTC offer, and SDP/ICE are relayed through the channel
   only between the two participating devices.
5. Audio flows peer-to-peer when possible, otherwise through coturn. TURN
   credentials are short-lived HMAC credentials (coturn `use-auth-secret`).
6. Hang up / disconnect ends the call. The state machine lives in
   `lib/callee/calls/call_server.ex`:

| From | Event | Result |
|------|-------|--------|
| ringing | callee accepts | `active` |
| ringing | callee declines | `rejected` |
| ringing | caller hangs up or caller tab dies | `cancelled` |
| ringing | 45 s timeout | `missed` (+ "Missed call" push) |
| start | callee already on a call | `busy` |
| active | either hangs up or either tab dies | `completed` |

On server restart, calls left `ringing`/`active` are marked `failed`.

### Push notification notes

- VAPID keys are generated on first boot and stored in Postgres, or set
  `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY`. Payloads use `aes128gcm` (RFC 8291).
- Users enable notifications with the bell icon in the header. Browsers require
  this to come from a tap.
- **iPhone/iPad:** Web Push works only after the user adds the site to the Home
  Screen (iOS 16.4+), and only over HTTPS. Android Chrome and desktop browsers
  work from a normal tab.
- A web app cannot show a full-screen native "incoming call" UI like a phone call
  app. It shows a notification. If ringing over a locked screen is a hard
  requirement, a native wrapper with CallKit / ConnectionService is needed.

## App experience and PWA

- **Paginated, searchable lists everywhere.** Tenants (admin), contacts, and call
  history all page server-side. Search, filter and page live in the URL, so back,
  refresh and shared links keep your place.
- **Mobile-first shell.** Bottom tab bar on phones (Contacts, Calls, Settings),
  top nav on desktop. Missed-call badge on Calls. Call history is grouped by day,
  with filters (All, Missed, Incoming, Outgoing, Recorded).
- **Friendly states.** Empty states with next steps, an offline banner, and an
  online/offline indicator for the calling connection. Toasts dismiss themselves.
- **Settings** lets users turn on call alerts, test their microphone, install
  the app, switch theme and change password. Tenants can reset a client's
  password only if no other tenant shares that client.
- **Installable PWA.** It has a web app manifest with standard and maskable icons
  and shortcuts. The service worker precaches an offline page and caches static
  assets, and it handles push. An install prompt shows on Android and desktop.
  iPhone users get "Add to Home Screen" instructions, which iOS needs for call alerts.

## Group calls

- **Saved groups:** tenants create named groups on the **Groups** tab, such as
  "Morning team", and call everyone in one tap. They can also pick people ad hoc
  on Contacts with **Group call**, then **Call** or **Save** the selection as a
  group. A group holds 2 to `GROUP_MAX - 1` people (default `GROUP_MAX=50`,
  counting the tenant).
- **Media and scale (host-led, 20 to 50+ people):** calls go through the
  server's group room (`Callee.Media.Room`), an audio SFU with **active-speaker
  forwarding**.
  - Each phone keeps **one** connection with `SPEAKER_SLOTS` incoming lines
    (default 4), however big the group. Join, leave and speaker changes never
    renegotiate.
  - The **tenant is pinned**: every client always hears the host on its own
    line. The other lines carry the loudest clients, which fits "host talks,
    2–3 callers at a time". The host's lines carry the 4 loudest clients.
  - Loudness comes from the browsers' RFC 6464 audio-level tag on each packet,
    so the server never decodes audio. When a line switches speaker, the server
    rewrites RTP sequence numbers and timestamps so playback stays smooth.
  - Bandwidth per phone is about 1 stream up and 4 down, whatever the group size.
  - Measured with 25 participants and 3 talking: about 10% of 8 cores,
    including the 25 simulated browsers. Run it with
    `mix test --only load test/callee/media_room_speakers_test.exs`.
  - Every participant is still recorded on their own track and mixed into the
    file, not only the forwarded speakers. Skipped when `RECORDING_MODE=off`.
  - One process handles each room. Past about 100 people, or for many large
    rooms at once, split rooms across nodes or move to a Membrane or LiveKit
    based mixer.
- **Each person rings independently.** They can accept, decline, or let it ring
  out. Anyone who missed it, declined, was busy or left sees a green **"Group
  call in progress · Join"** bar while the call is live, even after reopening the
  app. The host can tap **Ring again** on anyone's tile.
- **Ending:** the host's **End for all** ends it for everyone. Clients only
  **Leave**. While the host stays on, the call stays open for late joiners. It
  ends after the host has been alone for `GROUP_IDLE_MINUTES` (default 10).
- Clients see other participants' **names only**, never their phone numbers.

## Recording modes and long calls

Set `RECORDING_MODE` in `.env`:

| Mode | Media path | Who records | Best for |
|------|-----------|-------------|----------|
| `server` (default) | Each phone ⇄ Phoenix (tiny 2-party SFU in `Callee.Media.Session`, built on `ex_webrtc`) | Server writes each side to disk *as the call runs*, mixes at hang-up | Reliability, long calls |
| `client` | Phone ⇄ phone (P2P) | Tenant browser, uploading **1-minute chunks during the call** | Lowest server bandwidth |
| `off` | Phone ⇄ phone | Nobody | |

**Long calls (6 h+):** no per-call limit except `MAX_CALL_HOURS` (default 8, a
safety cap). TURN credentials last 24 h. If a phone's connection drops (sleep,
Wi-Fi to 4G) the call is kept for 45 s; the other side sees "Waiting for
connection…" and the timer resumes when it comes back. In server mode even a page
reload resumes the call. Server mode memory is constant; disk is about 15 MB per
side per hour in `RECORDING_DIR` (a docker volume) until the mixed .m4a is uploaded.

**Server mode networking:** browsers reach the media server directly on UDP
`MEDIA_PORT_RANGE` or, failing that, through coturn, which is allowed to relay only
to the app's docker subnet (`allowed-peer-ip` in `deploy/turnserver.conf`). On a
Linux VPS, `network_mode: host` for the app gives the most direct path.

**Why not full Membrane?** `ex_webrtc` is Membrane's own WebRTC core (same
team). For forwarding Opus between two people and writing it to disk, a Membrane
pipeline adds layers but no reliability. Reach for Membrane when you need live
mixing/transcoding, group calls, or streaming out. `Media.Session` is the one module
to swap.

## Recording (client mode details)

- Done in the **tenant's browser**: local mic + remote audio are mixed with
  WebAudio and captured by `MediaRecorder` (WebM/Opus on Chrome/Firefox, MP4/AAC on
  Safari).
- Uploaded in sequenced 1-minute chunks to `POST /tenant/calls/:id/recording`
  (idempotent, retried with backoff). If the tab dies, what arrived is finalized
  90 s after the call ends.
- Server converts to `.m4a` with ffmpeg, uploads to S3 under
  `recordings/tenant-<id>/<call_id>.m4a`, and the tenant's Calls page updates live.
- Playback goes through `GET /tenant/recordings/:id`, which checks ownership and
  redirects to a 10-minute presigned S3 URL. Clients never see recordings.
- The client's call screen shows "This call may be recorded". Check the consent
  rules where you operate.

## Production deploy (single VPS)

1. Point `call.example.com` and `s3.example.com` at the server.
2. In `.env`:
   ```
   PHX_HOST=call.example.com
   PHX_URL_SCHEME=https
   PHX_URL_PORT=443
   CHECK_ORIGIN=//call.example.com
   APP_DOMAIN=call.example.com
   S3_DOMAIN=s3.example.com
   S3_PUBLIC_ENDPOINT=https://s3.example.com
   TURN_EXTERNAL_IP=<server public IP>
   STUN_URLS=stun:call.example.com:3478
   TURN_URLS=turn:call.example.com:3478?transport=udp,turn:call.example.com:3478?transport=tcp
   TURN_SECRET=<long random>
   ```
   For AWS S3 instead of SeaweedFS, set real AWS keys and region, leave
   `S3_ENDPOINT` and `S3_PUBLIC_ENDPOINT` empty, and remove the `s3` service.
3. Open firewall: 80, 443 TCP; 3478 TCP+UDP; 49160-49250 UDP.
4. Start with TLS:
   ```bash
   docker compose --profile tls up -d --build
   ```
   HTTPS is required: browsers block the microphone on plain HTTP except on localhost.
5. On Linux, `network_mode: host` for coturn (commented in compose) gives better
   UDP relay performance than port mapping.

## Development

```bash
docker compose up -d db s3 coturn
mix setup              # deps, DB, seeds (admin/admin1234, tenant1/tenant1234, 9990001111/client123)
mix phx.server
mix test               # needs Postgres on localhost (PGPORT to override)
```

## Layout

| Path | What |
|------|------|
| `lib/callee/accounts.ex` | admins, tenants (expiry), clients, address book |
| `lib/callee/calls.ex`, `calls/call_server.ex` | call history + live call state machine |
| `lib/callee/push.ex` | Web Push (VAPID + aes128gcm) |
| `lib/callee/turn.ex` | coturn REST credentials |
| `lib/callee/storage.ex`, `calls/recording_processor.ex` | S3 + ffmpeg |
| `lib/callee_web/channels/` | signalling socket + channel |
| `lib/callee_web/live/` | admin, tenant, client pages |
| `assets/js/call.js` | WebRTC, ringing UI, tones, recorder, push subscribe |
| `deploy/` | coturn, SeaweedFS, Caddy configs |

## Limits and known gaps

- Single node: live call state is in-process (`Registry`). Clustering would need
  `:global`/Horde or a Postgres-based lock.
- If a tab drops mid-call the call ends immediately. There is no reconnection
  grace period yet; ICE restarts handle short network changes while the tab stays up.
- Recording is lost if the tenant's tab is closed before the upload finishes. The
  page warns on close while an upload is pending.
- **Earpiece vs loudspeaker:** calls start on the earpiece where the browser
  allows it, and the call screen has a **Speaker** toggle that is remembered.
  iPhone uses the Audio Session API (Safari 16.4+). Android and desktop use
  `setSinkId` when the browser exposes earpiece/speaker outputs. Where neither is
  available the toggle is hidden and the phone's default routing applies.
