# Pending Work

Open threads / parked items. Last updated 2026-11-27 (final review fixes).

See [the prioritised feature backlog](FEATURES.md) for the competitive upgrade
roadmap, including the verified transcription, speaker-label, output-profile and
vault-export correctness gaps. Repair those as the foundation for the main
product priority: live transcription and conversation/topic navigation.

## Features

### Hybrid UI: native shell, local web UI (branch feat/hybrid-ui)
- **Status:** built and tested on branch feat/hybrid-ui (unreleased, not pushed). Sessions, Settings and the live view are the local web UI; the old SwiftUI windows are gone; the menu bar popover is restyled. Details: [FEATURES.md](FEATURES.md#implemented-locally-unreleased-2026-11-27-branch-feathybrid-ui) and [DEVELOPMENT.md](DEVELOPMENT.md#architecture-native-shell-local-web-ui).
- **Install:** use `Scripts/build-app.sh` (it rebuilds the frozen worker and the web UI). The bundle assembled during the Task 9 check reused an older frozen worker; don't install that one.

#### Manual checks (after installing)
Nothing below was run in the real app; the suites use fakes.
- No window opens at launch. Diagnostics is now the only window scene.
- Popover: the bundled fonts show, the switches and the progress bar use the signal-room tints (offscreen snapshots drew them grey), and Cyrillic titles fall back to the system font cleanly.
- Popover: the REC mark jitters now and then, and stays still with Reduce Motion on.
- Popover entries: Open archive shows `/sessions`; the gear shows Settings; a recent session opens its page; Open in browser signs in; Open live panel shows the compact view. All are disabled with "Local server isn't running." when the server didn't start.
- Start with the live map on opens the live panel, as the old Live Meeting window did.
- The archive window, the live panel and the browser all show the UI.
- Playback in the archive window: a seek before the audio has loaded lands on the right time; audio stops when you switch sessions.
- Export downloads go through a save panel in the archive window (WKDownload).
- Choose… for the output folder and the vault, from the archive window and from the browser: the panel comes to the front; hold it open for more than 60 s in the archive window.
- Download the speaker and emotion models from the web UI.
- Test connection with a real OpenRouter key; Refresh the model list online and offline.
- A setting changed in one host (browser) shows in the other (archive window) without a reload.
- The browser may offer to save an API key in its password manager. Decide whether that needs a change.
- Offline with a cloud session: Re-process is disabled with the reason, and comes back when the Mac is online, without a reload.
- The session header shows the cost split; "No API keys required…" shows for local transcription and local notes.
- A live meeting end to end, in the panel and in the browser.
- Dev loop: sign in with "Open in browser", then the Vite dev server at `http://127.0.0.1:5173` (checked against the fake app only).
- Restart the app with a browser tab open: the tab asks to sign in again (the app reuses its last port). With that port taken by another process, the app starts on another port and the old tab says "CallCapture isn't answering…" after a few seconds.
- Close the archive window during playback: the audio stops; reopening shows the page signed in again. Same for the live panel during a meeting.
- Force-quit during processing, then relaunch: the session shows Re-process or Transcribe with "Processing stopped when the app quit.", and can be deleted.
- Start a meeting from the web's Record button with the live map on: the floating panel opens once.

#### Known differences from the old windows
Accepted on purpose; listed so nobody "fixes" them by accident.
- Per-session duration and cost moved from the list rows to the session header. The list shows date, title and state, as the canvas does.
- Playback pauses on the app's `recording` event instead of at once. The delay is milliseconds.
- The "N speakers" count isn't shown; "Who spoke" lists every speaker.
- The end time isn't shown; the length is.

#### Known limitations
- More than about five browser tabs stall: each tab keeps one events stream, and HTTP/1.1 allows six connections per host.
- The live view's ⌘⇧N / ⌘⇧J / ⌘⇧L shortcuts work in the app's windows; browsers keep them for themselves.
- The floating panel sets `sharingType = .none`, but ScreenCaptureKit on macOS 15.4+ ignores it. Don't promise it is hidden from screen sharing.

#### Follow-ups (from the build log; not fixed)
- `PythonBridge.healthCheck()` calls `waitUntilExit()` on a Swift-concurrency thread; the Diagnostics probe could hang a pool thread (Low–Medium). The `which` fallback in `findPython3` has the same pattern (Low). The batch path uses a termination handler and is safe.
- `PythonBridge`: the heartbeat is dead code (stdin closes before heartbeats); a failed request write doesn't terminate the child; a worker death may call `fail()` twice (two gap entries).
- Stop is refused while the live speech model downloads (menu and web). The reason says "cancel it from the menu", but Cancel download is hidden while recording.
- Resolved by removing the SwiftUI detail view: it allowed re-processing during a recording, which took over the app state. The web API refuses that with 409.
- `ConversationAnalysis.hasContent` is now used only by its tests (it decided the old insights panel).
- `LiveWorkerProcess.transcribe` waits for its `chunk_done`; a worker that writes it and exits before the reader thread has parsed it is still reported as "exited before completing accepted audio". The `finish()` race is fixed; this one needs the reader to drain before the exit check.

#### Can wait (from the final review triage; not fixed)
Security and correctness, low:
- `ServerSecurity.constantTimeEquals` folds the length difference into a `UInt8` (truncating); lengths that differ by a multiple of 256 aren't flagged by that term alone.
- Keychain and settings write failures still answer 200/204.
- `access(2)` checks may not match what TCC lets the app read.
- Waveform peaks (`WaveformPeaks`, `GET …/peaks`): no single-flight (two requests compute the same peaks), an orphaned computation keeps running after its request ends, and `Blocking.run` is uncapped.
- Some file and database reads still block the Swift cooperative pool.
- Errors show raw codes in places (e.g. `busy`, `failed`) where a sentence would help.

Web:
- Refetch volume: `sessionChanged` and `recording` both invalidate open details and the list, and some changes post duplicate events.
- `TranscriptionPane` repeats the `RemoteProvider` set in its copy; it can drift from the Swift enum.
- Cyrillic (and other non-Latin) text falls back to system font glyphs: only Latin subsets of the fonts are bundled.

Native and tooling:
- The popover has no ScrollView; a tall state can exceed the screen.
- `NativeChangeEventsTests` waits with fixed sleeps.
- CI pins `Xcode_26.1.1`, and the Playwright browsers are not cached between runs.

### Live model catalog and offline behaviour
- **Status:** implemented on branch feat/live-model-catalog (unreleased). Details: [FEATURES.md](FEATURES.md#implemented-locally-unreleased-2026-11-26-branch-featlive-model-catalog).
- **Remaining:** capture one real `/api/v1/benchmarks?source=artificial-analysis` response with the user's key and use it as the test fixture; compare `ModelCostEstimate` constants with recorded live-notes spend after a few meetings; GUI check of the picker and offline captions.


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
