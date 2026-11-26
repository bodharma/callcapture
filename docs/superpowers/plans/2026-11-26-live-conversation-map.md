# Live Conversation Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved live meeting workspace: local transcription of both capture sources, stable topic navigation, editable personal notes, catch-up and durable evidence.

**Architecture:** Reuse installed pywhispercpp in a persistent worker. A bounded audio buffer isolates capture from inference; NDJSON carries base64 PCM chunks and timestamped turns. Native Swift owns the saved conversation map, incremental optional LLM memos, and SwiftUI workspace. No new dependency is required.

**Tech Stack:** Swift/SwiftUI/Core Audio/URLSession, existing Python worker/pywhispercpp/numpy, Swift Testing/pytest.

**Spec:** ../specs/2026-11-26-live-conversation-map-design.md

## Global Constraints

- Keep macOS 14.2 compatibility and all pre-existing device/default/capture fixes.
- Speech processing stays local; automatic memos use the explicitly enabled existing LLM provider. Never silently switch language or provider.
- Capture must never wait for model work, network I/O or the live UI. Keep buffering bounded and expose gaps/lag.
- Preserve manual notes, topic identities, original live evidence and audio offsets through automatic updates and final batch processing.
- Use neutral synthetic fixtures; never read real recordings or send meeting content to a provider during verification.

## Shared Interfaces

### Persistent worker

Command: `live --model base --language auto` through the existing PythonBridge worker path.
stdin is NDJSON: `{id, source: "mic"|"system", start: seconds, sample_rate:16000, pcm_f32le:base64, final:bool}`. `{"type":"stop"}` gracefully exits after accepted chunks.
stdout events: `ready`; `turn` with `{id,source,start,end,text,language?,final:true}`; `partial` with `{source,text,start,end}`; `chunk_done` with `{id}`; `error` with `{message,request_id?}`. Logs go to stderr. IDs are stable and final turns are de-duplicated per source across overlapping windows. Invalid requests fail explicitly; no canned text.

### Native domain

Owned by the domain task under `macos-app/Sources/Live/ConversationMap.swift` and `ConversationTopicService.swift`.
`LiveAudioSource: String, Codable, Sendable { case mic, system }`.
`LiveTurn: Codable, Identifiable, Sendable { id:String, source:LiveAudioSource, start:Double, end:Double, text:String, language:String? }` with public-to-target memberwise initializer.
`LiveMemoKind: String, Codable, CaseIterable { case idea, question, decision, action, note }`.
`LiveNotesConfiguration` contains enabled:Bool, baseURL:URL, apiKey:String, model:String; credentials are runtime-only and never persisted.
`@MainActor @Observable LiveMeetingModel` has a `nonisolated init()` for the existing AppModel. It exposes a Codable `document`, selectedTopicID:String?, followsLive:Bool, catchUpText:String, status:String, error:String?, partials:[LiveAudioSource:String].
The document exposes sessionID:String, title:String, audioPath:String, turns:[LiveTurn], topics:[ConversationTopic], currentTopicID:String?, warnings:[String], isRecording:Bool. A topic exposes id:String, parentID:String?, title:String, summary:String, pinned:Bool, memos:[LiveMemo], turnIDs:[String]; a memo exposes id:String, kind:LiveMemoKind, text:String, manual:Bool, pinned:Bool, turnIDs:[String].
Methods: `begin(sessionID:String,title:String,audioPath:String,speechLanguage:String,notesLanguage:String,configuration:LiveNotesConfiguration) throws`; `ingest(_ turn:LiveTurn)`; `updatePartial(source:LiveAudioSource,text:String)`; `markGap(_ message:String)`; `addManualNote(_ text:String,kind:LiveMemoKind)`; `selectTopic(_ id:String)`; `backToLive()`; `catchUp()`; `renameTopic(_ id:String,title:String)`; `pinTopic(_ id:String)`; `moveTopic(_ id:String,parentID:String?)`; `mergeTopic(_ sourceID:String,into targetID:String)`; `end()`; `load(audioPath:String) throws`; `exportMarkdown(to directory:URL) throws -> URL`.
Persistence is beside source audio as `<audio-base>_live.json`; immutable turn IDs/time offsets remain available after final batch processing. Automatic updates coalesce and cannot overwrite manual/pinned content. Return-to-topic visits append evidence to the same node; unknown associations remain visible as Discussion until confirmed/edited.

## Review Focus

- Source mixing/offset gaps: distinguish enabled mic from system audio and never silently hide dropped live samples.
- Queue pressure, malformed worker frames and process failure: bounded memory; recording continues; partial text never becomes an invented final turn.
- Repeated topics and manual edits: stable identity/order, valid parent graph and preserved evidence.
- Browsing while new turns arrive: keep selection/scroll/focus, catch up from the point follow mode stopped, and return to live explicitly.
- Save/load/final processing: atomic internal persistence, collision-safe exports and no credentials in saved documents.

## Task 1: Persistent local speech worker and fail-closed transcription

**Ownership:** `python-worker/**` only; do not edit Swift or global docs.
- [ ] Write failing tests for NDJSON validation, partial/final routing, offsets/IDs, overlap de-duplication, malformed audio and absent dependencies.
- [ ] Add `app/transcribe/live.py` and the CLI `live` command; reuse one real model; keep logs separate from JSON.
- [ ] Remove the canned batch fallback; preserve native cloud speaker labels when no local sidecar overrides them.
- [ ] Include pywhispercpp in frozen packaging and document any build/runtime limitation precisely.
- [ ] Run full pytest and one synthetic real-model subprocess smoke with cached base; no microphone or cloud calls.

## Task 2: Conversation state, optional memos and evidence persistence

**Ownership:** the two domain files above and matching Swift domain tests only.
- [ ] Write failing tests for timing -> testing -> timing, dedup, manual/pinned notes, tree cycles/merges, catch-up cursor, save/load and safe export.
- [ ] Implement the shared types and model, plus coalesced optional URLSession LLM updates using existing provider configuration.
- [ ] Validate all suggested source IDs, types, parent references and output bounds. Preserve language/hand edits and expose model failures.
- [ ] Run focused tests and review the entire domain task.

## Task 3: Audio isolation, worker lifecycle and native live workspace

**Ownership:** remaining `Sources/Live/**`, App/CallCaptureApp.swift, App/ContentView.swift, Bridge/PythonBridge.swift, UI/SessionDetailView.swift, Session/SessionManager.swift, Capture/AudioCaptureManager.swift, matching integration/buffer tests. Coordinate any shared-interface change before editing domain files.
- [ ] Write failing checks for bounded PCM buffering, source offsets/gaps, worker event parsing/lifecycle and state routing.
- [ ] Add a bounded non-waiting audio tee after existing 16k conversion; keep capture file/stem handling intact.
- [ ] Run the persistent worker outside the capture thread; drain accepted tail chunks on stop with a bound and visible incomplete status.
- [ ] Add a native workspace with topic outline, selected memo/evidence, live cue, transcript, manual notes, catch-up/return controls and topic correction.
- [ ] Wire explicit live/memo choices and speech/notes languages before capture; open saved maps without replacing an active live model. Include new owned files in session deletion.
- [ ] Build and run focused tests, then complete integrated source/synthetic-worker checks.

## Task 4: Integrate, review and record the actual limits

**Ownership:** root coordinates review, docs and receipts; implementers fix their owned files.
- [x] Resolve the known SettingsManager Keychain test dependency through an injected credential store if required for full-suite verification; never alter the user's real credentials.
- [x] Run full Python/Swift suites and packaged-worker checks appropriate to the change.
- [x] Obtain independent code/security reviews; resolve material findings in one coordinated fix wave.
- [x] Update README, FEATURES and PENDING with implemented behaviour and unverified hardware/provider paths.
- [x] Clean synthetic task artifacts, preserve all pre-existing edits, and leave one coherent local change for this repository.

Status 2026-11-26 (final executor): done except where noted in FEATURES.md "Not verified".
Receipts: Python 239 passed/83%; Swift 107 tests in 28 suites passed; frozen worker rebuilt
in a temporary directory. Late fixes: single-writer model sharing, 7-day offset bound and total
timestamp formatter, independent backlog monitor, stderr handle ownership, setNotesLanguage.

## Execution rulings

The user's “y” approves implementation of the live conversation-map design.
Continue in the existing task branch, preserving the previous smart-defaults
change and the user's capture-format fix. Independent Python/domain/integration
ownership permits parallel implementation against the shared interfaces above.
No app launch, real microphone capture or cloud inference is authorised for
verification; use synthetic audio and test doubles at provider boundaries.
