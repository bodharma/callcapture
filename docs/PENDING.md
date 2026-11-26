# Pending Work

Open threads / parked items. Last updated 2026-11-26.

See [the prioritised feature backlog](FEATURES.md) for the competitive upgrade
roadmap, including the verified transcription, speaker-label, output-profile and
vault-export correctness gaps. Repair those as the foundation for the main
product priority: live transcription and conversation/topic navigation.

## Features

### Live conversation navigation (main product priority)
- **Status:** implemented locally and unreleased on branch feat/smart-audio-defaults (uncommitted). Exact behaviour, test counts and limits: [FEATURES.md](FEATURES.md#implemented-locally-unreleased-2026-11-26-branch-featsmart-audio-defaults).
- **Design:** [Live conversation map](superpowers/specs/2026-11-26-live-conversation-map-design.md).
- **Remaining before release:** user-run GUI/real-capture check (mic + system, history sheet, notes-language menu), provider note quality/cost check, bilingual quality evaluation, frozen release build/notarization containing pywhispercpp, commit/review of this change. Reconcile bookmarks during final processing is not implemented.

## Bugs / cleanups

### Cost: OpenAI/Groq STT rates not exercised by `.auto`
- The `.auto` provider router only picks AssemblyAI/Deepgram, so the editable OpenAI/Groq `$/min` rates only matter if the user explicitly selects those providers. By design; noted so it isn't "fixed" by mistake.

## Ideas (not committed to)
- **Speaker identity** (biggest product gap): calendar (EventKit) attendee names → map `Speaker N → Name`; manual speaker rename in the detail view; voiceprint enrollment for auto-naming. See [`memory: fathom-attribution-analysis`].
- Audio playback synced to transcript (click a line → jump); full-text search across sessions; export to Notion/Slack/Reminders; cost spend dashboard + budget alerts.

## Recently shipped (for context)
- **Cost actually records now.** `build-app.sh` only rebuilt the PyInstaller worker when it was *missing*, so the cost-tracking worker (merged after the worker was first frozen) never got bundled — every session stored NULL costs. The script now rebuilds the worker whenever its source is newer than the frozen binary (or `FORCE_WORKER_REBUILD=1`).
- **Re-process keeps the original engine.** `JobRequest.transcribe` now reuses the session's persisted `engineUsed` (surfaced onto the `Session` model) instead of always using `defaultEngine`; the remote-key env gate keys off the effective engine. Re-processing a remote session no longer falls back to local Whisper / `$0.00` cost. The dead `engine:` param on `SessionDetailView.transcribeButton` was removed.
- v0.2.1 — **notarized** brew release + **per-session cost tracking** (merged to main).
- `run-dev.sh` re-signs the bundle after copying the binary (fixed "failed to create audiotap" — the dev bundle was losing its `audio-input` entitlement). The intermittent second-recording failure resolved with the properly-entitled build.
- Release CI (`.github/workflows/release.yml`) is **enabled**; tagged releases auto build → sign → notarize → upload (cask bump runs only if `HOMEBREW_TAP_TOKEN` is set — currently bumped manually).
- Signing material lives in `signing/` (git-ignored) with a `README.txt` index.
