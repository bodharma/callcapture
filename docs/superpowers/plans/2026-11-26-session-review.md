# Session Review (backlog group 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make every finished recording easy to check inside the app: the full
speaker-labelled transcript with click-to-seek playback, persistent speaker
names, and search across all sessions that opens the matching moment.

**Scope (FEATURES.md group 2):** readable transcript + rendered note, linked
playback with speed control, full-text search, rename speakers. Deferred:
waveform (no clear value yet), merge speakers, capture health/recovery (touches
`Capture/`, which awaits the user's real-capture check on the previous change).

## Design

- **Transcript source:** the session's DB paths (`transcriptRawPath`,
  `transcriptMarkdownPath`), never paths derived from the audio path. The raw
  file is the worker's JSON array of `{start, end, text, speaker}`.
- **Playback:** `AVAudioPlayer` on the mixed recording (`audioPath`). Clicking a
  line's timestamp seeks and plays; speed 0.75–2x (`enableRate` before
  `prepareToPlay`). The system tap excludes no process, so playback would bleed
  into a new recording: `AppModel` pauses every player and blocks playback just
  before capture starts, and unblocks only after a successful stop.
  Only the current-line index is observed by rows, so ticks do not redraw the list.
- **Speaker names:** per-session sidecar `<audio-base>_speakers.json`, a map
  from the original worker label to a user name. Worker output is untouched; names
  follow the label, which Re-process normally reproduces (a different engine or
  diarizer can renumber speakers). Applied on display (transcript, insights), in
  search, and in every export (Save to Vault, Markdown, text, JSON).
  Text replacement is single-pass (renaming A→B and B→C never chains) and
  whole-label (`Speaker 1` never rewrites `Speaker 10`). `Speaker …` labels are
  replaced anywhere; other labels (`You`) only in structural positions
  (`**You:**`, `| You |`, frontmatter `  - You`) so ordinary prose is safe.
  The sidecar is deleted with the session.
- **Search:** all sessions (the sidebar list is capped at 50), case- and
  diacritic-insensitive (Cyrillic included), over title, transcript lines (with
  time and speaker name) and note lines. Debounced, runs off the main thread,
  no index: a linear scan of a personal archive is fast enough (FTS5 is the
  upgrade path). Selecting a hit opens the session scrolled to that line with
  the player positioned there (no autoplay).

## Tasks

### Task 1: Pure logic (TDD)
- [x] Tests: transcript decoding + line lookup by time; speaker-name apply
      (whole label, no chaining, structural-only for `You`, save/load, blank
      name removes); search (Cyrillic case-insensitive, time + excerpt, title
      hit, speaker-name hit, caps).
- [x] Implement `TranscriptLine`/`TranscriptDocument`, `SpeakerNames`, `SessionSearch`.
- [x] Delete `_speakers.json` with the session; extend the delete test.

### Task 2: UI
- [x] `TranscriptPlayerView` (new file): player bar, lazy line list, rename.
- [x] `SessionDetailView`: replace the 1,000-character previews with the player
      view and a full rendered note; apply names to insights and exports.
- [x] `SessionListView`: search results with excerpt/time; open at time.

### Task 3: Verify and document
- [x] Full Swift + Python suites, build; review the diff.
- [x] Update FEATURES/PENDING; record what was not exercised (GUI, playback).

## Execution rulings

The user said "go step 1, then do features" after the strategy recommended
group 2. Work continues on `feat/session-review`, branched from the five
committed changes so they remain the fixed candidate for the user's checks.
No app launch, real recording or real session files are used for verification;
fixtures are synthetic.

## Verification receipts

- RED: the new suites failed to compile (types missing); GREEN after implementation.
- Swift: 123 tests / 31 suites passed. Python: 239 passed. `swift build` clean.
- Independent review: 1 medium (playback bleed before `state = .recording`), 5 low
  (search spinner race, same-session hit rebuilt detail state, non-idempotent player
  load, timer paused during scroll, lossy JSON export without renames) — all fixed;
  CRLF frontmatter gap fixed with a test. Rename alert uses `presenting:` so Save
  cannot lose the label on dismissal.
- Out-of-scope touches: `App/CallCaptureApp.swift` (playback block around capture
  start/stop, 5 lines) and `Live/SessionNoteExport.swift` (export helper only).
- Not exercised: GUI, playback/seek/speed, search UX, focus scrolling, the playback
  block during a real recording.
