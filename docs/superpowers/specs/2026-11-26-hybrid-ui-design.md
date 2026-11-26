# Hybrid UI and signal-room redesign

Date: 2026-11-26. Status: approach chosen by the user ("hybrid"); builder-checked; design awaiting
approval (stack choice pending the user's confirmation). First of three projects; Topic map (graph) and Live context (fact cards)
follow as separate specs on top of this foundation.

## Intent

The user rejected the current UI as clinical and generic and approved a direction:
a tasteful hacker / cassette-futurist "signal room" (reference canvas:
https://claude.ai/artifact/H9iWzRFtm2f5K1qJVnYZWU). They want the app's main
screens usable both in a native app window and in their browser, opened from the
menu bar, without maintaining two interfaces.

## Goals

1. **One web UI, two hosts.** Sessions, Settings and the live meeting view are a
   single local web app, shown (a) inside native app windows via `WKWebView` and
   (b) in the user's browser at a local address. Both hosts render the same build.
2. **Native where macOS requires it.** The menu bar extra, recording, all TCC
   permissions (microphone, system audio, later camera and screen), the worker
   processes, and the always-on-top floating live panel (an `NSPanel` hosting the
   same web UI) stay native.
3. **Menu bar entry points.** The menu bar popover keeps quick actions (Record /
   Stop, devices, this-meeting settings, live map toggle, recent sessions) and adds
   "Open archive" (native window) and "Open in browser" (local URL with a fresh
   login token).
4. **Signal-room visual system,** taken from the canvas boards: oxide-dark ground
   with faint scanlines, pale phosphor text, rust (`#e0805f`) as the identity/record
   accent, phosphor green (`#8ee3a6`) only for live/decided state, amber
   (`#e2b45a`) for open/warning; Barlow Condensed (display, timecodes), Instrument
   Sans (reading), IBM Plex Mono (machine readouts: channels, timecodes, costs);
   glitch only on the REC indicator; segmented VU-style meters; the meeting tape
   with decision/question/note markers. Fonts are bundled (OFL), not fetched.
5. **Feature parity before removal.** Everything the current SwiftUI Sessions,
   Settings and live workspace do keeps working in the web UI: list/search,
   detail with full transcript and click-to-seek playback with speed, speaker
   rename, notes, insights, warnings, exports (Markdown/text/JSON, Save to vault),
   re-process, delete; Settings incl. the live model catalog table; the live map
   (topics, memos, manual notes, catch-up, back-to-live, rename/move/merge/pin)
   and live-notes spend; offline captions and disabled reasons.
6. **Live updates.** The live view and recording state update in real time in both
   hosts (server-sent events from the app).

## Non-goals (this project)

- The topic graph view and the live fact cards (next two specs).
- Access from other devices (LAN/phone). The server binds loopback only; a later
  opt-in can add it.
- Embedding Google Meet/Zoom (blocked by Google's embedded-webview sign-in policy;
  not needed for camera features, which capture windows natively).
- Camera / health metrics.

## Anti-goals

- Any other website, or any other machine, being able to read recordings, transcripts
  or settings through the local server.
- Two diverging UIs (native and web) for the same screen after migration.
- Regressing capture, transcription or the worker pipeline while moving UI.
- Exposing API keys to the web UI (keys are write-only from the UI).
- A "Matrix rain"/neon costume look; the canvas's restraint is the bar.

## Constraints

- macOS 14.2+, Swift 5.9 package, existing GRDB/FluidAudio dependencies; the
  Python worker stays a per-job CLI.
- Release pipeline (sign, notarize, cask) must keep working with the web assets
  bundled in `Contents/Resources/web/`.
- Tests: no real network, no real recordings, no live Keychain (existing rules);
  `memory: ci-test-constraints` applies.
- The existing offline-aware behaviour and the model catalog stay authoritative in
  Swift; the web UI renders what the app reports.

## Approaches considered

1. **Hybrid, one web UI in two hosts (chosen by the user).** Native shell and
   capture; web UI for windows; one codebase for both hosts.
2. **Native-only redesign (SwiftUI).** ~1.5–2 weeks, no browser access, harder to
   reach the canvas look.
3. **Two separate UIs (SwiftUI + web).** Rejected: every feature built twice.

## Design decisions (designer's calls, confirm or override)

- **Server inside the Swift app**, not the Python worker: sessions, settings, live
  state and the catalog already live in Swift. Library: **Hummingbird 2**
  (recommended; checked 2026-11-26: release 2.29.0, very active, SSE/WebSocket,
  in-process `HummingbirdTesting`). Its current release needs swift-tools 6.2, so
  CI and the release workflow move from Xcode 16 (Swift 6.0) to Xcode 26 (local
  toolchain is already Swift 6.2.1). Fallback if the user prefers minimal
  dependencies and no CI change: FlyingFox 0.27 (tools 6.0, pre-1.0, one maintainer).
- **Frontend: React + Vite + TypeScript** (recommended over the first draft's
  Svelte: the user's own work apps, ephra-web and ciba-admin-frontend, use React 18
  + Vite + TS, so they can read and change it; React Flow is available for the
  later topic graph). Built to static files bundled in the app; in dev, Vite's dev
  server proxies the API to the running app.
- **Security model:** bind `127.0.0.1` on a free port chosen at launch; every
  request needs a session cookie (HttpOnly, SameSite=Strict) obtained by exchanging
  a single-use random token passed in the URL the app opens; reject requests whose
  `Host` is not `127.0.0.1:<port>`/`localhost:<port>` (DNS rebinding) and
  state-changing requests whose `Origin` differs; no CORS headers; the `WKWebView`
  host gets its cookie injected; tokens rotate every launch.
- **API shape:** JSON over HTTP under `/api/` (sessions list/search/detail,
  transcript, notes, analysis, speaker names, exports, re-process, delete, settings
  read/write with secrets write-only, model catalog + refresh, connectivity, record
  start/stop), audio served with HTTP Range for playback, and one SSE stream
  `/api/events` for recording state, live transcript turns, live map changes,
  live-notes spend and connectivity.
- **Playback** moves to the browser `<audio>` element over the Range endpoint;
  the playback-blocked-while-recording rule is enforced in the UI from the events
  stream and by pausing on the `recording-starting` event.
- **Migration order:** server + auth + empty shell → Sessions → Settings → live
  view in the floating panel → remove the replaced SwiftUI views. The menu bar
  popover is restyled in SwiftUI to match.

## Clarifications after the builder check (designer's calls)

- **The canvas is a visual reference, not a behaviour spec.** Behaviour comes from
  this document; canvas-only behaviour is listed here as in or out.
- **Data stays as it is; `python-worker` is out of scope.** Summary shows the
  existing insights (summary, decisions, action items, open questions as untimed
  lists) and the Markdown note that goes to the vault. The meeting tape shows a
  waveform computed natively from the saved audio (read-only peaks, cached beside
  the audio; no capture-path change) and markers only where timed evidence exists:
  live-map memos (decision / question / manual note) for sessions recorded with the
  live map. Timed decisions from the worker are later work. Action items render as a
  list without tick boxes (tracking commitments is a later feature).
- **Live views: one responsive live web view.** Compact layout in the floating panel
  (≤ 480 px wide); full layout (all current live-workspace features: topic tree,
  evidence, add/rename/move/merge/pin, memo edit/pin, notes language, export,
  catch-up, back to live, spend) at `/live` in the archive window and the browser.
  Saved live maps of past sessions open in the same full view at
  `/sessions/<id>/live` instead of a sheet. The session "Topic map" tab shows this
  outline view until the graph spec lands.
- **Canvas-only behaviour:** the floating panel sets `NSWindow.sharingType = .none`
  so it never appears in screen shares or recordings (in scope; replaces "hidden
  while you share your screen"). Collapse-to-strip and real VU level meters are out
  of scope (meters need capture-path metering; they come with capture health). The
  recording view shows per-channel connection status text instead of meters.
- **Native-only actions from either host** go through the app, since both hosts run
  on the same Mac: exports are served as downloads (HTTP attachment; the `WKWebView`
  host handles them with `WKDownload` into the user's chosen folder via a save
  panel); Save to vault writes server-side to the configured vault; folder pickers
  (output directory, Obsidian vault) ask the app to show `NSOpenPanel` (the panel
  appears from the menu bar app even when the request came from the browser), with a
  typed-path field as fallback; Open in Finder / Open note ask the app to call
  `NSWorkspace`.

## Testing

- Swift: API handler tests in-process (no sockets) for each endpoint; security
  tests for Host/Origin/token/cookie rules; SSE event shape tests.
- Web: Vitest for view logic (formatting, state), one Playwright smoke against a
  fake API fixture server (no app, no network).
- Manual: both hosts render the same screens; browser login via menu bar; offline
  states; playback; live meeting end to end.

## Left to the builder

Component structure, routing, state management, exact endpoint names and payloads
within the shape above, port selection details, how the SwiftUI window hosts the
`WKWebView`, and visual details not specified by the canvas.
