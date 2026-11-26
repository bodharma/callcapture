# Pending Work

Open threads / parked items. Last updated 2026-11-26.

See [the prioritised feature backlog](FEATURES.md) for the competitive upgrade
roadmap, including the verified transcription, speaker-label, output-profile and
vault-export correctness gaps. Repair those as the foundation for the main
product priority: live transcription and conversation/topic navigation.

## Features

### Session review (backlog group 2)
- **Status:** transcript + click-to-seek playback, rename speakers and search across all sessions merged to `main` (unreleased); used in the user's local test build on 2026-11-26. Details: [FEATURES.md](FEATURES.md#implemented-locally-unreleased-2026-11-26-branch-featsession-review).
- **Open in this group:** waveform, merge speakers, capture health/interruption recovery (e.g. warn before transcribing when a stem is silent).

### Live conversation navigation (main product priority)
- **Status:** merged to `main`, unreleased, Experimental and off by default. Exact behaviour, test counts and limits: [FEATURES.md](FEATURES.md#implemented-locally-unreleased-2026-11-26-branch-featsmart-audio-defaults).
- **Design:** [Live conversation map](superpowers/specs/2026-11-26-live-conversation-map-design.md).
- **Remaining before release:** live-mode GUI check (history sheet, notes-language menu; plain mic + system recording and remote transcription were verified on the user's Mac on 2026-11-26), provider note quality/cost check, bilingual quality evaluation, frozen release build/notarization containing pywhispercpp. Live audio admission still allocates on the real-time IO thread (`LiveAudioBuffer.offer`); replace with a preallocated ring before dropping the Experimental label. Reconcile bookmarks during final processing is not implemented.

## Bugs / cleanups

### Cost: OpenAI/Groq STT rates not exercised by `.auto`
- The `.auto` provider router only picks AssemblyAI/Deepgram, so the editable OpenAI/Groq `$/min` rates only matter if the user explicitly selects those providers. By design; noted so it isn't "fixed" by mistake.

## Ideas (not committed to)
- **Speaker identity** (biggest product gap): calendar (EventKit) attendee names → map `Speaker N → Name`; manual speaker rename in the detail view; voiceprint enrollment for auto-naming. See [`memory: fathom-attribution-analysis`].
- Audio playback synced to transcript (click a line → jump); full-text search across sessions; export to Notion/Slack/Reminders; cost spend dashboard + budget alerts.

## Recently shipped (for context)
- **Recordings no longer come out empty (2026-11-26).** The aggregate used `tapautostart`, which makes `AudioDeviceStart` wait until a tapped process plays audio; with the mic as clock master, a recording made while nothing played captured 0 frames (mic lost too). That was the real cause of the old "intermittent second-recording failure". Mic recordings now start immediately. The worker also skips digitally silent stems and treats AssemblyAI's "no spoken audio" as an empty stem, so one speechless stem no longer fails the job.
- **Local installs:** `Scripts/build-app.sh release`, then re-sign with `SIGN_IDENTITY="Developer ID Application: …" Scripts/sign-app.sh .build/CallCapture.app` so macOS keeps mic/system-audio permissions across rebuilds (ad-hoc signatures change every build and reset them; the first recording after a reset is silent). Ad-hoc signing no longer hardens the nested worker, which could not load its own libpython.
- **Cost actually records now.** `build-app.sh` only rebuilt the PyInstaller worker when it was *missing*, so the cost-tracking worker (merged after the worker was first frozen) never got bundled — every session stored NULL costs. The script now rebuilds the worker whenever its source is newer than the frozen binary (or `FORCE_WORKER_REBUILD=1`).
- **Re-process keeps the original engine.** `JobRequest.transcribe` now reuses the session's persisted `engineUsed` (surfaced onto the `Session` model) instead of always using `defaultEngine`; the remote-key env gate keys off the effective engine. Re-processing a remote session no longer falls back to local Whisper / `$0.00` cost. The dead `engine:` param on `SessionDetailView.transcribeButton` was removed.
- v0.2.1 — **notarized** brew release + **per-session cost tracking** (merged to main).
- `run-dev.sh` re-signs the bundle after copying the binary (fixed "failed to create audiotap" — the dev bundle was losing its `audio-input` entitlement). (The "intermittent second-recording failure" noted here was actually `tapautostart`; see above.)
- Release CI (`.github/workflows/release.yml`) is **enabled**; tagged releases auto build → sign → notarize → upload (cask bump runs only if `HOMEBREW_TAP_TOKEN` is set — currently bumped manually).
- Signing material lives in `signing/` (git-ignored) with a `README.txt` index.
