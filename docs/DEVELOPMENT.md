# Development Guide

Architecture, build, and test workflows for CallCapture. For the product overview see the [root README](../README.md).

## Repository layout

```
callcapture/
├── macos-app/            # Swift menu-bar app (SwiftUI + Core Audio + GRDB + Hummingbird)
│   ├── Sources/
│   │   ├── App/          # App entry, AppModel, menu bar popover, web windows (WKWebView)
│   │   ├── Server/       # Loopback HTTP server: security, /api routes, events (SSE), static web UI
│   │   ├── Capture/      # Core Audio process-tap capture, stem writers
│   │   ├── Bridge/       # PythonBridge: spawns worker, JobRequest/JobResult
│   │   ├── Live/         # Live meeting: local speech worker, conversation map
│   │   ├── Session/      # Session model, SessionManager (GRDB), search, export
│   │   ├── Settings/     # SettingsManager, Keychain, model catalog
│   │   └── Diagnostics/  # The native Diagnostics window
│   ├── Tests/            # Swift Testing (logic, API handlers, security)
│   ├── Scripts/          # build-app.sh, assemble-app.sh, sign-app.sh, entitlements
│   └── Package.swift     # SPM: GRDB, FluidAudio, Hummingbird
├── web/                  # The local web UI: React + Vite + TypeScript
│   ├── src/              # Sessions, Settings and Live screens (Vitest tests beside them)
│   └── e2e/              # Playwright smoke against a fake app (fixture-server.ts)
├── python-worker/        # Transcription + analysis pipeline
│   └── app/
│       ├── cli.py        # Click CLI; `transcribe` reads JobRequest on stdin
│       ├── transcribe/   # engine (local Whisper) + remote_engine (AssemblyAI/Deepgram/OpenAI)
│       ├── analyze/      # diarization load, attribution, metrics, sentiment, emotion, insights
│       ├── postprocess/  # llm_client, formatter, markdown rendering, pricing
│       ├── export/       # markdown + raw transcript writers
│       └── schemas/      # Pydantic models (JobRequest, JobResult, TranscriptSegment, ...)
├── docs/                 # design specs & implementation plans
└── run-dev.sh            # build Swift → bundle → launch in dev mode
```

## Architecture: native shell, local web UI

The app has two halves.

**Native (Swift).** The menu bar popover, recording, every macOS permission, the
worker processes and the windows that host the web UI. The popover is SwiftUI in the
signal-room style. It shows the channels, Record/Stop, this meeting's choices, the
live map setup, recent sessions and the entry points. Diagnostics is the only other
native window.

**Web (React).** Sessions, Settings and the live meeting view are one web app. A
loopback HTTP server inside the app (Hummingbird) serves it from
`Contents/Resources/web/` and answers its `/api` calls. The same build shows in three
places:
- the archive window (`WKWebView`, "Open archive"; the gear opens Settings);
- the floating live panel (`NSPanel` + `WKWebView` at `/live?compact=1`, "Open live panel");
- the user's browser ("Open in browser").

Swift stays the source of truth: sessions, settings, the model catalog, offline rules
and their wording. The web UI renders what the app reports. Live changes (recording
state, live turns, the map, spend, connectivity, session changes) arrive over one
server-sent events stream, `GET /api/events`.

**Security model.** The server binds `127.0.0.1`, on the port it had last time when that
port is free (else any free port), so a tab left open across a restart is told to sign in
again instead of failing to connect. Every
`/api` request needs an HttpOnly, SameSite=Strict session cookie. The app gets one by
opening `/login?token=…` with a single-use token that expires in 60 seconds; tokens and
sessions die with the app. Requests whose `Host` isn't `127.0.0.1:<port>` or
`localhost:<port>` are refused (DNS rebinding). Writes (POST, PUT, PATCH, DELETE) that
carry an `Origin` other than the app's own are refused; writes with no `Origin` header
are allowed, because browsers always send one on cross-origin requests (and the
SameSite=Strict cookie still has to be there). There are no CORS headers. Any server on 127.0.0.1 receives the session
cookie (cookies ignore ports), so HTML pages send `Content-Security-Policy: frame-ancestors
'none'` and `X-Frame-Options: DENY` to block framing, and every response sends
`X-Content-Type-Options: nosniff`. API keys are write-only: the web UI can save
or remove them but never reads them back. The web views only load the app's own
origin; other http(s) links open in the default browser and anything else is dropped.

## Data flow

```
User records → Capture (Core Audio process tap)
   writes <id>.wav, and when a mic is selected also <id>_mic.wav + <id>_system.wav
        │
        ▼
On-device diarization (FluidAudio) → <id>_system_diarization.json  (speaker turns)
        │
PythonBridge spawns:  python3 -m app.cli transcribe   (JobRequest as JSON on stdin)
        │
   Worker pipeline (app/cli.py _run_pipeline):
     1. transcribe stems (mic = "You", system = remote) or the single mix
     2. attribute system segments to speakers via the diarization sidecar
     3. analyze: sentiment, acoustic emotion, insights (LLM)
     4. render Markdown note + write <id>_transcript.json / <id>_notes.md
        │
   ProgressUpdate (stderr) + JobResult (stdout, JSON)
        ▼
SessionManager persists paths/status to the GRDB session database
        ▼
The local server's /api serves it; the web UI shows it (archive window or browser)
```

The worker is **stateless per job**: all configuration arrives in the `JobRequest`
(engine, language, notes language, remote provider, model, etc.). The app is the
source of truth for settings and the session database.

## Prerequisites

- macOS 14.2+ (Apple Silicon recommended)
- Xcode 26 / Swift 6.2 toolchain (Hummingbird 2.29 needs swift-tools 6.2)
- Node 22+ and npm (the web UI)
- Python 3.11+

## Python worker

```bash
cd python-worker
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# Run the test suite (pytest, with coverage per pyproject.toml)
pytest

# Invoke the CLI directly (JobRequest JSON on stdin)
echo '{"job_id":"x","command":"transcribe","audio_path":"/path/to.wav","engine":"local_whisper"}' \
  | python -m app.cli transcribe
```

Key worker modules:

- `transcribe/remote_engine.py` — cloud STT. AssemblyAI uses the `speech_models`
  priority list (`universal-3-pro` → `universal-2`); Deepgram uses Nova-3.
- `analyze/attribution.py` — merges mic ("You") + system segments using the
  diarization turns; falls back gracefully when stems/turns are absent.
- `postprocess/llm_client.py` — OpenAI-compatible client (OpenRouter or local).

## macOS app

```bash
cd macos-app
swift build                 # compile
swift test                  # run the Swift suite

# Or build + bundle + launch the whole thing in dev mode from repo root:
./run-dev.sh
```

`run-dev.sh` builds the Swift binary, copies it into `CallCapture.app`, builds the
web UI into `web/dist` if it isn't there yet (`npm ci && npm run build`, Node 22+),
kills any running instance, and launches with:

- `CALLCAPTURE_DEV_MODE=1`
- `CALLCAPTURE_WORKER_DIR=<repo>/python-worker` — so the app runs your live
  worker code (no reinstall needed for Python changes).
- `CALLCAPTURE_WEB_DIR=<repo>/web/dist` — so the app serves your web build. After
  web changes, run `npm run build` (or `npx vite build --watch`) in `web/` and reload.

`Scripts/build-app.sh` builds a full bundle: the Swift binary, the frozen worker
(rebuilt with PyInstaller when its sources changed) and the web UI (rebuilt with
`npm ci && npm run build` when `web/` changed), then signs it. The web build lands in
`Contents/Resources/web/`.

### Database

Sessions/jobs/settings live in a GRDB SQLite database at
`~/Library/Application Support/CallCapture/callcapture.db`. Schema changes are
applied via numbered migrations (see `Sources/Persistence/`); add a new migration
rather than mutating an existing one. Migration tests live in
`Tests/CallCaptureTests/DatabaseMigrationTests.swift`.

## Web UI

```bash
cd web
npm ci
npm run build       # tsc + vite build into web/dist
```

There are two dev loops. Both need the app running.

**Your build, served by the app.** Launch the app with `CALLCAPTURE_WEB_DIR` set to
`web/dist`, for example
`open macos-app/.build/CallCapture.app --env CALLCAPTURE_WEB_DIR="$PWD/web/dist"`.
Then run `npx vite build --watch` in `web/`. Reload the archive window or the browser
tab after each rebuild. Sign in as usual from the menu.

**The Vite dev server, with hot reload.** Find the app's port: it is in the address
bar after "Open in browser", and in the log line "Local server listening on
127.0.0.1:<port>". Then:

```bash
cd web
CALLCAPTURE_PORT=<port> npm run dev -- --host 127.0.0.1
```

The dev server proxies `/api` and `/login` to the app and rewrites `Host` and `Origin`
so the app's guard accepts them. To sign in, click "Open in browser" once, then open
`http://127.0.0.1:5173` in the same browser. Cookies are kept per host, not per port,
so the app's session cookie comes along. Use `127.0.0.1`, not `localhost`: they are
different hosts to the browser.

## Testing

Run each suite from its folder:

| Suite | Command | What it covers |
| --- | --- | --- |
| Swift | `cd macos-app && swift test` | Logic, API handlers in-process (no sockets), security rules, events, the popover's wording |
| Python | `cd python-worker && .venv/bin/pytest -q` | The worker pipeline |
| Web unit | `cd web && npm test` (Vitest) | Screens and view logic, with `fetch` and `EventSource` faked |
| Web smoke | `cd web && npm run build && npm run e2e` (Playwright, Chromium) | Sign-in, sessions → detail → transcript seek, settings key, a live turn |

The smoke runs against `web/e2e/fixture-server.ts`, a fake app that serves `web/dist`
with canned JSON, one events stream and ranged audio. It needs no app and no
network. The first run may need `npx playwright install chromium`.

Conventions:

- **Python:** pure functions (parsing, routing, attribution, pricing) are unit-tested;
  cloud HTTP flows are tested at the response-mapping layer. Prefer TDD — write the
  failing test first. Some tests need `numpy`/`openai` installed — run them inside the
  worker's `.venv`, not a bare system Python.
- **Swift:** Swift Testing under `macos-app/Tests/`. `AppModel` can't be built in
  tests, so API tests use a fake backend. Views are checked by hand.
- **Web:** Vitest beside each screen; the Playwright smoke is not part of `npm test`.
- No real network, no real recordings, no live Keychain in any suite.

## Design docs

`docs/superpowers/specs/` holds design specs and `docs/superpowers/plans/` holds
the phased implementation plans the project was built from. New features follow
the same flow: spec → plan → TDD implementation.

## Conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Small, focused files; immutable data where practical.
- Never commit secrets — API keys go in the macOS Keychain. Recordings and the
  session DB are git-ignored.
