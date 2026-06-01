# Live Transcript (AssemblyAI Streaming) — Design

**Date:** 2026-06-01
**Status:** Approved (design), pending implementation plan
**Scope:** Optional real-time transcript preview during a call, streamed from the **system audio** to **AssemblyAI's streaming API**, toggled per call. The saved transcript is unchanged (batch pipeline, on stop). Live streaming cost is added to the session's cost.

---

## 1. Goal

While a call is recording, optionally show a live, scrolling transcript of the
**remote side** (system audio). It is a **disposable preview** — the authoritative
transcript is still produced by the existing batch pipeline when recording stops.

The user turns live on/off **per call** (defaulting to a Settings preference).

---

## 2. Core principle — isolation

**Live is best-effort and fully isolated from the critical path.** Any live error
(no/invalid AssemblyAI key, network drop, socket error, API change) must **never**
affect audio capture or the batch transcription/analysis pipeline. If live fails,
the recording and the final transcript are unaffected; the user just loses the
on-screen preview. No live retry may block or stall the capture IO proc.

---

## 3. Scope decisions (resolved)

- **Preview only.** Batch still runs on stop and is authoritative (full accuracy +
  diarization + speaker attribution + LLM notes). Live text is not persisted as the
  transcript.
- **System audio only.** Stream just the remote side (one socket). The user's own
  mic is not streamed.
- **Per-call toggle + Settings default.** A switch shown before starting a call,
  pre-set from a `liveTranscriptEnabled` default in Settings.
- **Cost is surfaced.** Live streaming bills on top of batch; the streaming cost is
  added to the session's transcription cost (see §7).

---

## 4. Architecture

```
record start (live ON)
  AudioCaptureManager IO proc ── tee 16 kHz mono SYSTEM buffers ──► LiveTranscriber
        │ (unchanged: still writes WAV + stems)                       │ URLSessionWebSocketTask
        ▼                                                             ▼ wss://streaming.assemblyai.com/v3/ws
   (batch pipeline runs on stop, unchanged)                     AssemblyAI streaming
                                                                      │ partial + final "Turn" msgs
                                                                      ▼
                                                             LiveTranscriptView (SwiftUI window)
record stop → LiveTranscriber sends Terminate, closes socket, finalizes live
             duration → batch pipeline runs as today → live cost added to session
```

All live code is **Swift-only**; the Python worker is not involved (it is batch /
per-job). The audio tap already produces 16 kHz mono buffers — live reuses them.

---

## 5. Components

### 5.1 `LiveTranscriber` (new, Swift)
Owns one `URLSessionWebSocketTask` to AssemblyAI streaming.

- **Connect:** `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le`
  (+ `&language=<code>` when not English). Auth via the `Authorization: <API_KEY>`
  header on the WebSocket upgrade request (key from Keychain).
- **Send:** binary frames of **PCM16 little-endian mono @ 16 kHz**. The capture
  buffers are float32 mono 16 kHz → convert to `Int16` before sending.
- **Receive:** JSON messages. AssemblyAI v3 streaming emits `Begin`, `Turn`
  (with `transcript`, `end_of_turn`, `words`), and `Termination`. A `Turn` with
  `end_of_turn == false` is a **partial** (updating); `true` is a **final** turn.
- **Expose** via `@Observable`: `finalizedText: [String]` (committed turns),
  `partialText: String` (current in-progress turn), `state` (connecting / live /
  disconnected / error), and `streamedSeconds` (for cost).
- **Stop:** send `{"type":"Terminate"}`, close the socket, freeze `streamedSeconds`.
- **Best-effort:** all socket callbacks are wrapped; any failure sets
  `state = .error` and logs — it never throws into the capture path.

> The exact v3 streaming message shape / query params should be confirmed against
> AssemblyAI's current streaming docs (via Context7) at implementation time; the
> parsing is isolated in `LiveTranscriber` so a protocol tweak is a localized change.

### 5.2 `AudioCaptureManager` (modify)
Add an optional tee: `var onSystemPCM: ((AVAudioPCMBuffer) -> Void)?`. Inside the
IO proc, after the system-stem 16 kHz mono buffer is produced, if `onSystemPCM` is
set, call it with that buffer. When live is off the closure is `nil` → zero added
work. The tee must do no blocking I/O on the audio thread — it hands the buffer to
`LiveTranscriber`, which enqueues/sends asynchronously.

### 5.3 `LiveTranscriptView` (new, SwiftUI)
A window opened on record-start when live is enabled:

```
┌─ Live transcript ───────────────┐
│ …earlier finalized turns…       │
│ So the deadline is next Friday. │  ← final (solid)
│ and we should probably          │  ← partial (greyed / italic)
└──────────────────── ● recording ┘
```
Auto-scrolls to the latest. Finalized turns solid; the current partial greyed.
A small status chip shows connecting / live / **disconnected** on error. Closes
when recording stops (or the user closes it; closing it does not stop recording).

### 5.4 Settings (modify)
- `liveTranscriptEnabled: Bool = false` (the per-call default), persisted.
- `assemblyAIStreamingRatePerMin: Double = 0.0025` (≈$0.15/hr; **verify**),
  editable in the existing **Pricing** section.

### 5.5 Start-recording UI (modify)
The pre-call control (menu / start affordance) gains a **Live transcript** toggle,
initialized from `settings.liveTranscriptEnabled`. The toggle is **disabled with a
reason** when live can't run (see §6).

---

## 6. Guards — when live can run

Live is offered/enabled only when **both**:
1. The **AssemblyAI API key** is set (Keychain). Else: toggle disabled, reason
   "Add an AssemblyAI key in Settings."
2. The session language is **supported by AssemblyAI streaming** (en, es, de, fr,
   pt, it). `auto` is treated as **English** for the live preview. Any other
   language: toggle disabled, reason "Live transcript supports en/es/de/fr/pt/it."

Either way, **batch transcription is unaffected** — these guards gate only the live
preview, not the recording or the final transcript.

---

## 7. Cost

Live streaming bills on top of batch (≈2× STT for that session). The streaming cost
is folded into the session's **transcription** cost:

```
live_cost = (LiveTranscriber.streamedSeconds / 60) × settings.assemblyAIStreamingRatePerMin
```

On stop, after the batch `JobResult` returns and the session cost is written,
`CallCaptureApp` **adds** `live_cost` to the persisted `cost_transcription`:

```
costTranscription = (result.costTranscription ?? 0) + live_cost   // when live ran
```

So the detail-view breakdown and list badge already reflect it (no UI change). When
live didn't run, behavior is exactly as today. The streaming rate is editable in the
Pricing settings section.

---

## 8. Error handling

- No/invalid key, socket failure, network drop → `LiveTranscriber.state = .error`,
  a "disconnected" chip in the window, logged. **Capture + batch continue.**
- Capture stop always tears down the socket (even if already errored).
- The audio-thread tee never blocks: buffers are converted + enqueued off the
  realtime thread.

---

## 9. Testing

**Swift:**
- `LiveTranscriber` message parsing: feed mocked AssemblyAI frames (`Begin`,
  partial `Turn`, final `Turn`, `Termination`) → assert `finalizedText` /
  `partialText` / `state` transitions. (Inject a fake socket / parse function so no
  network is needed.)
- PCM float32→Int16 conversion correctness (sample values, byte order).
- Toggle gating logic: enabled only when key present AND language supported;
  `auto` → treated English. Default persists.
- Live cost math: `streamedSeconds × rate` folded into `cost_transcription`.

**Manual:**
- A real call with live ON shows scrolling partial→final text from the remote side.
- Killing wifi mid-call: the live window shows "disconnected"; the recording stops
  cleanly and the batch transcript + notes are produced normally.
- Live OFF behaves exactly as today.

---

## 10. YAGNI / Out of scope

- No live speaker labels (diarization is post-hoc; live shows raw remote text).
- No mic / "Me" side in the live stream.
- No live action items / live summary.
- No editing/saving the live text (it's a preview; batch is authoritative).
- No non-AssemblyAI live engines.
- No reconnect-with-backoff loop (a dropped socket stays disconnected for the
  rest of the call — capture is unaffected; keep v1 simple).

---

## 11. Open decisions resolved

- **Preview only**, batch authoritative. ✅
- **System audio only**, one socket. ✅
- **Per-call toggle + Settings default.** ✅
- **Streaming cost added** to the session's transcription cost. ✅
- **Live is best-effort + fully isolated** from capture/batch. ✅
