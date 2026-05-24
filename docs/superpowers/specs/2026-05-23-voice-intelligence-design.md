# Voice Intelligence & Recording Types — Design

**Date:** 2026-05-23
**Status:** Approved (pending written-spec review)
**Depends on:** baseline commit `64b13a5` (capture + transcription + notes working)

---

## 1. Goal

Turn Call Capture from a call recorder into a general **audio-notes recorder with
voice intelligence**. After a recording, the app:

- knows the **recording type** (Call/Meeting, Voice memo, Lecture) and processes accordingly,
- separates and counts **speakers** (diarization, where applicable),
- computes **talk metrics**, **sentiment** (text + acoustic emotion), and
  **conversation insights** (type-tailored, including psychological/negotiation
  advantage for calls),
- writes a structured Markdown note shaped per type.

LLM work runs through one **configurable OpenAI-compatible endpoint** — **OpenRouter**
by default, or a **local** model (Ollama/LM Studio) for fully-offline use. Heavy
analysis (diarization, emotion) runs **locally by default** (privacy), with a cloud
provider seam for later.

Built **post-call now**, with component seams that a future **live mode** can reuse.

## 2. Recording Types → Processing Profiles

Every type runs **metrics, sentiment, acoustic emotion, and insights**. Only two
things differ per type: whether **diarization** runs, and the **note shape / LLM
prompt template**.

| Type | Diarization | Note shape (sections) |
|---|---|---|
| **Call / Meeting** | yes | Participants, Sentiment, Conversation Insights (advantage + action items), Transcript |
| **Voice memo** | no (solo = "You") | Summary, Key points, Action items, Reflections |
| **Lecture / talk** | optional (separate main speaker / Q&A) | Outline, Key concepts, Summary, Q&A, Takeaways |

A profile is therefore: `{ diarization: Bool, note_template: String, insight_template: String }`.
The type set is an extensible enum (Interview etc. can be added later).

**Selection UX:**
- A **type picker in the menu popover before recording** (default: Call/Meeting).
- The type is **editable in Session Detail** before (re)processing, so a wrong
  type can be corrected and the analysis re-run.

## 3. Capture — Separate Stems

The IOProc already receives the mic and system-output streams as **separate
buffers** (today we sum them to mono). Change:

- **Mic selected:** write the mixed `<id>.wav` (playback master, unchanged) **plus**
  `<id>_mic.wav` ("You") and `<id>_system.wav` (remote) stems for analysis.
- **No mic:** write `<id>.wav` only — already output-only, so it doubles as the
  remote stem.

Each stem is 16 kHz mono (same converter path as today, applied per buffer instead
of summed). Stem writing is gated by "analysis enabled".

## 4. Worker Analysis Pipeline (new `analyze` stage)

Runs after transcription, orchestrated by the recording-type profile:

1. **Transcribe** (existing). With stems: transcribe `_mic` → "You" segments and
   `_system` → remote segments. Without stems: transcribe the single file.
2. **Diarize** (if profile.diarization): a swappable **DiarizationProvider** runs on
   the remote stem and writes a `<id>_diarization.json` **turns sidecar**
   (`[{speaker, start, end}]`). The worker reads the sidecar and assigns remote
   transcript segments to Speaker A/B/… by max time-overlap; if no sidecar exists,
   all remote segments collapse to a single "Speaker 1". "You" comes from the mic
   stem directly. Default provider is **FluidAudio** (native Swift / CoreML / Apple
   Neural Engine), which writes the sidecar before transcription; **pyannote**
   (Python) is an alternative provider writing the same sidecar. The worker is
   provider-agnostic — it only consumes the sidecar contract.
3. **Talk metrics** (always): per-speaker seconds, talk-ratio %, word count,
   words/min, turn count, interruptions (overlapping turn starts), longest monologue,
   silence/pause ratio.
4. **Acoustic emotion** (always): a local speech-emotion model over each speaker's
   segments → emotion label + valence/arousal, aggregated per speaker and as an arc.
5. **Sentiment** (always, LLM via OpenRouter): overall + per-speaker sentiment from
   the labeled transcript, reconciled with acoustic emotion.
6. **Insights** (always, LLM via OpenRouter): type-tailored. Call → dominance,
   momentum shifts, agreement/hesitation/objection signals, persuasion openings,
   recommended next moves. Memo → clarity, open loops, next actions. Lecture → key
   takeaways, gaps.
7. **Validate** (Pydantic) and write `<id>_analysis.json` + the type-shaped Markdown
   note. Atomic writes (temp + rename).

Failures degrade gracefully: if diarization or emotion fails, the note is still
produced from transcription + LLM with a warning; the job does not hard-fail.

## 5. LLM via configurable OpenAI-compatible endpoint

Replace the direct Anthropic SDK in post-processing with one **OpenAI-compatible
`LLMClient`** whose **base URL is configurable**. All LLM calls — note formatting,
sentiment, insights — go through it (with retry + JSON-mode parsing). Two providers:

- **`openrouter` (default):** base `https://openrouter.ai/api/v1`, key in Keychain.
- **`local`:** base `http://localhost:11434/v1` (Ollama; also LM Studio), no real key
  (placeholder). Enables **fully-offline** operation — combined with local whisper,
  pyannote, and the SER model, nothing leaves the machine.

The worker is provider-agnostic: it receives `LLM_BASE_URL`, `LLM_MODEL`, and
`LLM_API_KEY` in its environment and calls that endpoint. The Swift host resolves
these from the selected provider. If a cloud provider has no key (and the endpoint
isn't local), the worker falls back to rule-based extraction.

Local models (e.g. `qwen2.5:32b` on Apple Silicon) handle notes/sentiment well but
trail Gemini/Claude on multilingual nuance and complex insights — an accepted
trade-off for privacy.

**Model selection (researched 2026):**
- **Default `llm_model` = `google/gemini-2.5-flash`** (or `3.5-flash`). Chosen for
  multilingual transcript→notes: broadest language coverage (100+, strong on
  Ukrainian/Russian/English), ~20× cheaper than GPT/Claude (~$1/M words vs ~$23),
  fast, large context for long calls. Cost matters because every recording is
  processed.
- **Quality alternative (selectable): `anthropic/claude-sonnet-4.6`** — best
  instruction-following and structured output; recommended for the insights pass
  when reasoning/tone matter most.
- Avoid DeepSeek as default (only ~30-language coverage — unreliable for Cyrillic).
- Exact slugs are verified against `openrouter.ai/models` during implementation.
- Optional two-tier config: a cheap model for bulk formatting + a stronger model
  for insights. v1 ships a single configurable `llm_model` defaulting to Gemini
  Flash; the two-tier split is a documented seam.

Long transcripts (>~30 min) use hierarchical summarization (chunk → per-chunk
summary → synthesize), per the existing spec.

## 6. Diarization & Emotion — local, swappable

- **Diarization:** default provider is **FluidAudio** — a native Swift / CoreML SDK
  running on the Apple Neural Engine (macOS 14+, Apache-2.0, models auto-download
  from HF, no token). It runs in the **Swift app** on the remote stem and writes the
  `<id>_diarization.json` turns sidecar the worker consumes. A `DiarizationProvider`
  Swift protocol makes the engine swappable; **pyannote.audio** (Python/torch, gated
  HF model) is the documented fallback provider, writing the same sidecar. The worker
  never imports a diarizer — it only reads the sidecar (single-speaker fallback when
  absent). This keeps the Python worker lean (no torch) and uses ANE for speed.
- **Acoustic emotion:** local SER model behind an analyzer seam (Phase 4); engine TBD
  (a CoreML/ANE option preferred to avoid torch, mirroring the diarization choice).
- Models download on first use and cache locally; fully offline thereafter.

This choice keeps the app footprint small and Apple-Silicon-fast; the
sidecar/provider seam means switching to pyannote (or a cloud diarizer) later touches
only the provider, not the worker.

## 7. Data Model

New Pydantic models in the worker:

```
SpeakerStats { label, is_self, talk_seconds, talk_ratio, words, words_per_min,
               turns, interruptions, dominant_emotion, valence, arousal }
Sentiment    { overall, by_speaker: {label -> score/label}, arc: [ {t, score} ] }
Insights     { summary, dynamics, opportunities[], recommended_actions[],
               type_specific: {…} }
ConversationAnalysis { recording_type, num_speakers, speakers: [SpeakerStats],
                       sentiment: Sentiment, insights: Insights, warnings[] }
```

`TranscriptSegment` gains a reliable `speaker` label. `JobRequest` gains
`recording_type`. `JobResult` gains `analysis_path`.

SQLite: `session` gains `recording_type` and `analysis_path` columns (migration).
Swift `Session` and `SessionRecord` mirror them.

## 8. Output & UI

- **Markdown note** per type (frontmatter: `recording_type`, `participants`,
  `num_speakers`, `sentiment`, plus existing fields). Call note includes
  Participants (talk-ratio table), Sentiment, Conversation Insights, speaker-labeled
  Transcript.
- **Menu popover:** recording-type picker above the device pickers (default
  Call/Meeting).
- **Session Detail:** a **Conversation Insights** GroupBox — speaker count,
  talk-ratio bars, sentiment + emotion per speaker, and recommended actions; plus a
  **recording-type selector** with a Re-process action.

## 9. Settings

- `enable_analysis` (default true)
- `analysis_provider` = `local` | `assemblyai` | `deepgram` (default `local`;
  only `local` implemented in v1, others are seams)
- `llm_provider` = `openrouter` | `local` (default `openrouter`)
- `openrouter_api_key` (Keychain), `llm_model` (string, default
  `google/gemini-2.5-flash`; `anthropic/claude-sonnet-4.6` quality option; for local
  set e.g. `qwen2.5:32b`), `local_llm_base_url` (default `http://localhost:11434/v1`)
- `huggingface_token` (Keychain, for pyannote)
- `default_recording_type`
- Existing `enable_diarization` folds into per-type profile defaults.

## 10. Dependencies

Worker adds: `pyannote.audio`, `torch`, an SER model package, and an
OpenAI-compatible client (`openai`). The existing `anthropic` dependency is dropped
from the LLM path (OpenRouter replaces it).

## 11. Testing

- **Python unit (≥80% on new modules):** talk-metrics math from synthetic
  diarization; profile selection; schema validation; OpenRouter client JSON parsing
  (mocked HTTP); insight/sentiment prompt construction; graceful-degradation paths.
  Diarizer, emotion model, and LLM are mocked.
- **Swift:** stem-routing unit coverage where feasible; recording-type persistence;
  end-to-end verified via a real recording (mic + group audio) → both stems → analysis
  JSON → note.

## 12. Scope & Phasing

This is a large spec; the implementation plan will phase it:

1. **Foundation:** recording-type enum + profiles, type picker UX, DB migration,
   `recording_type` plumbing, OpenRouter client replacing Anthropic.
2. **Capture:** separate stems.
3. **Diarization + talk metrics** (local pyannote) and speaker attribution.
4. **Acoustic emotion + sentiment** (local SER + OpenRouter).
5. **Insights** (type-tailored prompts) + Markdown note shapes.
6. **UI:** Session Detail insights + type selector + re-process.

## 13. Out of Scope (v1)

- Live/real-time analysis (architecture leaves seams; not built).
- Cloud analysis providers (interface defined; not implemented).
- Interview and other extra types (enum is extensible).
- Distribution bundling of torch/models (packaging milestone).
