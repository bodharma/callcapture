# Voice Intelligence — Phase 4b: Acoustic Emotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local acoustic emotion (audeering wav2vec2 dimensional SER via ONNX) producing per-speaker valence/arousal + dominant-emotion and a conversation emotional arc, downloaded on demand via a worker `prepare_emotion` command + Settings button, and fed into the 4a sentiment pass for tone reconciliation.

**Architecture:** A new `app/analyze/emotion.py` with **lazy** heavy-dep imports (audonnx/audeer/audiofile loaded only at real-model time) and two mocked seams (`predict_vad`, `_read_audio`); pure helpers (`dominant_emotion`, `slice_signal`) and mocked aggregation (`compute_speaker_emotion`, `compute_arc`) are fully unit-tested. The worker gates on the model existing on disk. Swift gets an `emotionModelsReady` flag + a download row that runs the `prepare_emotion` worker command through the existing `PythonBridge`.

**Tech Stack:** Python 3.11+, Pydantic, pytest, numpy (test-required), audonnx/audeer/audiofile/onnxruntime (real-path only, lazy); Swift/SwiftUI. Spec: `docs/superpowers/specs/2026-05-25-phase4b-acoustic-emotion-design.md`.

**Branch:** `feature/voice-intelligence-phase4b` (already created).

---

## Conventions

- **Python: always the venv.** `cd python-worker && ./.venv/bin/python -m pytest <args>`. Install deps with `./.venv/bin/python -m pip install <pkg>`.
- **Swift:** `cd macos-app && swift build` / `swift test`; tests use Swift Testing, `@testable import CallCapture`, `@Test` funcs marked `@available(macOS 14.2, *)`, `@Suite("…")` on structs.
- Pyright "could not be resolved" / `frozen=` and SourceKit "No such module"/"Cannot find type" are FALSE POSITIVES — judge by the real `pytest` / `swift build` only.
- Commits: conventional, NO mention of AI/Claude.
- **Lazy imports are load-bearing:** `audonnx`, `audeer`, `audiofile` must be imported INSIDE the functions that use them (never at module top of `emotion.py`), so the worker and unit tests import `emotion.py` with only `numpy` installed.

## File Structure

- Modify `python-worker/pyproject.toml` — add deps.
- Modify `python-worker/app/schemas/models.py` — `ArcPoint`; `SpeakerStats` emotion fields; widen `Sentiment.arc`; add `"prepare_emotion"` to `JobRequest.command`.
- Create `python-worker/app/analyze/emotion.py` — model dir/ready, `predict_vad`/`_read_audio` seams, `slice_signal`, `dominant_emotion`, `compute_speaker_emotion`, `compute_arc`, `prepare_emotion_model`.
- Modify `python-worker/app/analyze/sentiment.py` — tone-reconciliation prompt block.
- Modify `python-worker/app/cli.py` — `prepare_emotion` command; emotion wiring in `_run_pipeline`/`_write_analysis`.
- Modify `macos-app/Sources/Bridge/Models.swift` — `JobRequest.prepareEmotion()` factory.
- Modify `macos-app/Sources/Settings/SettingsManager.swift` — `emotionModelsReady`.
- Modify `macos-app/Sources/Settings/SettingsView.swift` — `EmotionModelsRow`.
- Tests: `tests/test_emotion_pure.py`, `tests/test_emotion_compute.py`, `tests/test_prepare_emotion.py`, `tests/test_sentiment_reconcile.py`, `tests/test_pipeline_emotion.py`, `tests/test_emotion_schema.py`.

---

## Task 1: Worker dependencies

**Files:** Modify `python-worker/pyproject.toml`

- [ ] **Step 1: Add deps**

In `python-worker/pyproject.toml`, change the `dependencies` list to:

```toml
dependencies = [
    "pydantic>=2.0",
    "pywhispercpp",
    "anthropic",
    "openai",
    "click",
    "numpy",
    "audonnx",
    "audeer",
    "audiofile",
    "onnxruntime",
]
```

- [ ] **Step 2: Install numpy into the venv (tests need it; the heavy stack is for the human)**

Run: `cd python-worker && ./.venv/bin/python -m pip install numpy`
Expected: numpy installed. (Do NOT install audonnx/onnxruntime now — they are lazy-imported and mocked in tests; the human installs them before the live check via `./.venv/bin/python -m pip install -e .`.)

- [ ] **Step 3: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/pyproject.toml && git commit -m "build(worker): add numpy + audeering SER deps for acoustic emotion"
```

---

## Task 2: Schema additions

**Files:**
- Modify: `python-worker/app/schemas/models.py`
- Test: `python-worker/tests/test_emotion_schema.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_emotion_schema.py`:

```python
from app.schemas.models import ArcPoint, ConversationAnalysis, Sentiment, SpeakerStats


def test_speaker_stats_emotion_fields_default_none():
    s = SpeakerStats(label="You")
    assert s.dominant_emotion is None
    assert s.valence is None
    assert s.arousal is None


def test_speaker_stats_with_emotion_roundtrip():
    s = SpeakerStats(label="You", valence=0.7, arousal=0.5, dominant_emotion="content")
    restored = SpeakerStats.model_validate_json(s.model_dump_json())
    assert restored.valence == 0.7
    assert restored.dominant_emotion == "content"


def test_arc_point_and_widened_arc():
    sent = Sentiment(arc=[ArcPoint(t=10.0, score=0.3), ArcPoint(t=30.0, score=-0.2)])
    restored = Sentiment.model_validate_json(sent.model_dump_json())
    assert restored.arc[0].t == 10.0
    assert restored.arc[1].score == -0.2


def test_sentiment_arc_defaults_empty():
    assert Sentiment().arc == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_schema.py -v`
Expected: FAIL — `cannot import name 'ArcPoint'`.

- [ ] **Step 3: Implement**

In `python-worker/app/schemas/models.py`:

(a) Add emotion fields to `SpeakerStats` (after `longest_monologue_sec`):

```python
    dominant_emotion: str | None = None
    valence: float | None = None
    arousal: float | None = None
```

(b) **Before** the `Sentiment` class, add `ArcPoint`:

```python
class ArcPoint(BaseModel, frozen=True):
    """One point on the conversation emotional arc (acoustic valence over time)."""

    t: float       # window-center seconds
    score: float   # valence centered to -1..1
```

(c) In `Sentiment`, change the `arc` field from `arc: list[float] = Field(default_factory=list)` to:

```python
    arc: list[ArcPoint] = Field(default_factory=list)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_schema.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Add `prepare_emotion` to the request command Literal**

In `JobRequest`, change `command: Literal["transcribe", "postprocess", "export"]` to:

```python
    command: Literal["transcribe", "postprocess", "export", "prepare_emotion"]
```

- [ ] **Step 6: Run the full suite (no regressions from the arc type change)**

Run: `cd python-worker && ./.venv/bin/python -m pytest -q`
Expected: all pass (the 4a tests use empty arc, unaffected).

- [ ] **Step 7: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/schemas/models.py python-worker/tests/test_emotion_schema.py && git commit -m "feat(worker): add emotion fields, ArcPoint, prepare_emotion command"
```

---

## Task 3: Pure helpers — `dominant_emotion` + `slice_signal`

**Files:**
- Create: `python-worker/app/analyze/emotion.py`
- Test: `python-worker/tests/test_emotion_pure.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_emotion_pure.py`:

```python
import numpy as np

from app.analyze.emotion import dominant_emotion, slice_signal


def test_dominant_emotion_quadrants():
    assert dominant_emotion(0.8, 0.8) == "excited"
    assert dominant_emotion(0.8, 0.2) == "content"
    assert dominant_emotion(0.2, 0.8) == "frustrated"
    assert dominant_emotion(0.2, 0.2) == "sad"
    assert dominant_emotion(0.5, 0.5) == "neutral"


def test_slice_signal_basic():
    sr = 16000
    sig = np.arange(sr * 4, dtype=np.float32)  # 4 seconds ramp
    out = slice_signal(sig, sr, start=1.0, end=2.0, max_sec=30.0)
    assert len(out) == sr            # 1 second
    assert out[0] == sr              # sample at t=1.0s


def test_slice_signal_clamps_to_max_sec():
    sr = 16000
    sig = np.zeros(sr * 50, dtype=np.float32)  # 50 seconds
    out = slice_signal(sig, sr, start=0.0, end=50.0, max_sec=30.0)
    assert len(out) == sr * 30       # clipped to 30s


def test_slice_signal_clamps_to_bounds():
    sr = 16000
    sig = np.zeros(sr * 2, dtype=np.float32)
    out = slice_signal(sig, sr, start=1.5, end=99.0, max_sec=30.0)
    assert len(out) == int(sr * 0.5)  # only 0.5s of audio remains past 1.5s
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_pure.py -v`
Expected: FAIL — module `app.analyze.emotion` missing.

- [ ] **Step 3: Implement (module top + the two pure helpers)**

Create `python-worker/app/analyze/emotion.py`:

```python
"""Local acoustic emotion (Phase 4b) via the audeering wav2vec2 dimensional model.

Heavy deps (audonnx, audeer, audiofile, onnxruntime) are imported LAZILY inside the
functions that need them, so this module — and the worker that imports it — load fine
with only numpy installed. Unit tests mock `predict_vad` and `_read_audio`.
"""

from __future__ import annotations

import numpy as np

# Tuning constants (see spec §2, §7).
_TARGET_SR = 16000
_MIN_SEG_SEC = 0.5
_MAX_SEG_SEC = 30.0
_MAX_TOTAL_SEC_PER_SPEAKER = 300.0
_ARC_WINDOW_SEC = 20.0
_ARC_MAX_WINDOWS = 120

_LOW = 0.45
_HIGH = 0.55


def dominant_emotion(valence: float, arousal: float) -> str:
    """Map (valence, arousal) — each ~0..1, 0.5 ≈ neutral — to a coarse label."""
    if valence > _HIGH and arousal > _HIGH:
        return "excited"
    if valence > _HIGH and arousal < _LOW:
        return "content"
    if valence < _LOW and arousal > _HIGH:
        return "frustrated"
    if valence < _LOW and arousal < _LOW:
        return "sad"
    return "neutral"


def slice_signal(
    signal: np.ndarray,
    sampling_rate: int,
    start: float,
    end: float,
    max_sec: float = _MAX_SEG_SEC,
) -> np.ndarray:
    """Return the `[start, end]` span of `signal`, clamped to its bounds and to
    `max_sec` seconds."""
    start_idx = max(0, int(start * sampling_rate))
    end_idx = min(len(signal), int(end * sampling_rate))
    if end_idx <= start_idx:
        return signal[0:0]
    max_len = int(max_sec * sampling_rate)
    end_idx = min(end_idx, start_idx + max_len)
    return signal[start_idx:end_idx]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_pure.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/analyze/emotion.py python-worker/tests/test_emotion_pure.py && git commit -m "feat(worker): add emotion quadrant mapping and signal slicing"
```

---

## Task 4: Model dir/ready + inference seams

**Files:**
- Modify: `python-worker/app/analyze/emotion.py`
- Test: extend `python-worker/tests/test_emotion_pure.py`

`predict_vad` and `_read_audio` wrap the heavy deps (lazy import) and are NOT unit-tested directly (they need the real model/audio). `emotion_model_dir`/`is_emotion_model_ready` are tested.

> **Confirm against the resolved packages during implementation:** the audonnx call
> (`audonnx.load(model_dir)`; `model(signal, sr)["logits"][0]` ordered `[arousal,
> dominance, valence]`), the `audiofile.read(path)` return `(signal, sr)`, and the
> extracted model layout (whether `model.yaml` is the readiness marker). Adjust the
> bodies of `predict_vad`/`_read_audio`/`is_emotion_model_ready` to the real API if they
> differ; keep their signatures.

- [ ] **Step 1: Write the failing test (readiness + dir)**

Append to `python-worker/tests/test_emotion_pure.py`:

```python
import os


def test_emotion_model_dir_under_app_support():
    from app.analyze.emotion import emotion_model_dir
    d = emotion_model_dir()
    assert d.endswith("models/emotion-msp-dim")
    assert "CallCapture" in d


def test_is_emotion_model_ready(tmp_path, monkeypatch):
    from app.analyze import emotion
    monkeypatch.setattr(emotion, "emotion_model_dir", lambda: str(tmp_path))
    assert emotion.is_emotion_model_ready() is False
    (tmp_path / "model.yaml").write_text("meta")
    assert emotion.is_emotion_model_ready() is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_pure.py -v`
Expected: FAIL — `emotion_model_dir`/`is_emotion_model_ready` missing.

- [ ] **Step 3: Implement (append to `emotion.py`)**

Add `import os` to the top import block (with `import numpy as np`), then append the rest:

```python
def emotion_model_dir() -> str:
    """Where the extracted audeering model lives (shared by prepare + analysis)."""
    base = os.path.expanduser("~/Library/Application Support/CallCapture")
    return os.path.join(base, "models", "emotion-msp-dim")


def is_emotion_model_ready() -> bool:
    """True if the model has been downloaded+extracted. Confirm the marker file
    name against the real Zenodo archive; `model.yaml` is audonnx's loader entry."""
    directory = emotion_model_dir()
    return os.path.isfile(os.path.join(directory, "model.yaml"))


# --- heavy-dep seams (lazy import; not unit-tested) -------------------------

_model = None  # cached audonnx model for this process


def _read_audio(path: str) -> tuple[np.ndarray, int]:
    """Read `path` as float32 mono @ 16 kHz. Lazy-imports audiofile."""
    import audiofile  # lazy

    signal, sampling_rate = audiofile.read(path, always_2d=False)
    signal = np.asarray(signal, dtype=np.float32)
    if signal.ndim > 1:  # downmix to mono
        signal = signal.mean(axis=0)
    return signal, int(sampling_rate)


def predict_vad(signal: np.ndarray, sampling_rate: int) -> tuple[float, float, float]:
    """Return (valence, arousal, dominance) in ~0..1 for a mono 16 kHz signal.

    Lazy-loads the audonnx model once. The model emits logits ordered
    [arousal, dominance, valence]; this reorders to (valence, arousal, dominance).
    """
    global _model
    if _model is None:
        import audonnx  # lazy

        _model = audonnx.load(emotion_model_dir())
    logits = _model(signal, sampling_rate)["logits"][0]
    arousal, dominance, valence = float(logits[0]), float(logits[1]), float(logits[2])
    return valence, arousal, dominance
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_pure.py -v`
Expected: PASS (6 tests). (`predict_vad`/`_read_audio` aren't called — no heavy deps needed.)

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/analyze/emotion.py python-worker/tests/test_emotion_pure.py && git commit -m "feat(worker): emotion model dir, readiness check, and inference seams"
```

---

## Task 5: `compute_speaker_emotion` + `compute_arc`

**Files:**
- Modify: `python-worker/app/analyze/emotion.py`
- Test: `python-worker/tests/test_emotion_compute.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_emotion_compute.py`:

```python
import numpy as np

from app.analyze import emotion as emo
from app.analyze.emotion import SpeakerEmotion, compute_arc, compute_speaker_emotion
from app.schemas.models import TranscriptSegment


def _seg(start, end, speaker):
    return TranscriptSegment(start=start, end=end, text="x", speaker=speaker)


def test_compute_speaker_emotion_duration_weighted(monkeypatch):
    # Two speakers; You has a 2s and a 4s segment, Speaker 1 a 3s segment.
    segs = [_seg(0, 2, "You"), _seg(2, 5, "Speaker 1"), _seg(5, 9, "You")]
    # Stems "exist": map any read to a fixed-length zero signal.
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 20, np.float32), 16000))
    # predict_vad returns valence depending on speaker via the (zero) signal length;
    # instead key off a counter to give You vs Speaker 1 different values.
    calls = {"n": 0}

    def fake_predict(signal, sr):
        # You segments -> valence .8/arousal .6 ; Speaker 1 -> .2/.7
        calls["n"] += 1
        return (0.8, 0.6, 0.5)

    monkeypatch.setattr(emo, "predict_vad", fake_predict)

    out = compute_speaker_emotion(segs, "/tmp/sess.wav")
    assert set(out) == {"You", "Speaker 1"}
    assert isinstance(out["You"], SpeakerEmotion)
    assert out["You"].dominant_emotion == "excited"   # 0.8/0.6
    assert 0.0 <= out["You"].valence <= 1.0


def test_compute_speaker_emotion_skips_short_segments(monkeypatch):
    segs = [_seg(0, 0.2, "You")]  # < 0.5s -> skipped, no speakers
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000, np.float32), 16000))
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.5, 0.5, 0.5))
    assert compute_speaker_emotion(segs, "/tmp/sess.wav") == {}


def test_compute_arc_windows(monkeypatch):
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 60, np.float32), 16000))
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.75, 0.5, 0.5))  # valence .75 -> score .5
    arc = compute_arc("/tmp/sess.wav", window_sec=20.0, max_windows=120)
    assert len(arc) == 3                     # 60s / 20s
    assert arc[0].t == 10.0                  # first window center
    assert abs(arc[0].score - 0.5) < 1e-6    # 2*0.75 - 1


def test_compute_arc_empty_on_read_failure(monkeypatch):
    def boom(path):
        raise OSError("no file")
    monkeypatch.setattr(emo, "_read_audio", boom)
    assert compute_arc("/tmp/missing.wav") == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_compute.py -v`
Expected: FAIL — `SpeakerEmotion`/`compute_speaker_emotion`/`compute_arc` missing.

- [ ] **Step 3: Implement (append to `emotion.py`)**

Add the `SpeakerEmotion` dataclass near the top imports (after `import numpy as np`, add `from dataclasses import dataclass`), and the two functions:

```python
@dataclass(frozen=True)
class SpeakerEmotion:
    valence: float
    arousal: float
    dominant_emotion: str
```

```python
from app.schemas.models import ArcPoint, TranscriptSegment  # add to imports


def _stem_for(speaker: str, audio_path: str) -> str:
    """Audio file holding a speaker's voice: You -> mic stem, others -> system stem,
    falling back to the mixed file when a stem is absent."""
    base = os.path.splitext(audio_path)[0]
    stem = f"{base}_mic.wav" if speaker == "You" else f"{base}_system.wav"
    return stem if os.path.exists(stem) else audio_path


def compute_speaker_emotion(
    segments: list[TranscriptSegment],
    audio_path: str,
) -> dict[str, SpeakerEmotion]:
    """Duration-weighted per-speaker valence/arousal over each speaker's segments.

    Segments < `_MIN_SEG_SEC` are skipped; each is clipped to `_MAX_SEG_SEC`; total
    inferred audio per speaker is capped at `_MAX_TOTAL_SEC_PER_SPEAKER` (longest
    segments first). SER inference and audio reading are the mocked seams.
    """
    by_speaker: dict[str, list[TranscriptSegment]] = {}
    for s in segments:
        if (s.end - s.start) < _MIN_SEG_SEC:
            continue
        by_speaker.setdefault(s.speaker or "Speaker 1", []).append(s)

    result: dict[str, SpeakerEmotion] = {}
    for speaker, segs in by_speaker.items():
        path = _stem_for(speaker, audio_path)
        try:
            signal, sr = _read_audio(path)
        except Exception:  # noqa: BLE001 - degrade per-speaker on read failure
            continue
        # Longest segments first, capped to the per-speaker budget.
        ordered = sorted(segs, key=lambda s: s.end - s.start, reverse=True)
        budget = _MAX_TOTAL_SEC_PER_SPEAKER
        v_sum = a_sum = w_sum = 0.0
        for s in ordered:
            if budget <= 0:
                break
            clip = slice_signal(signal, sr, s.start, s.end, max_sec=min(_MAX_SEG_SEC, budget))
            dur = len(clip) / sr if sr else 0.0
            if dur < _MIN_SEG_SEC:
                continue
            valence, arousal, _ = predict_vad(clip, sr)
            v_sum += valence * dur
            a_sum += arousal * dur
            w_sum += dur
            budget -= dur
        if w_sum <= 0:
            continue
        valence = v_sum / w_sum
        arousal = a_sum / w_sum
        result[speaker] = SpeakerEmotion(
            valence=round(valence, 4),
            arousal=round(arousal, 4),
            dominant_emotion=dominant_emotion(valence, arousal),
        )
    return result


def compute_arc(
    audio_path: str,
    window_sec: float = _ARC_WINDOW_SEC,
    max_windows: int = _ARC_MAX_WINDOWS,
) -> list[ArcPoint]:
    """Acoustic-valence arc over the mixed recording, ≤ `max_windows` windows."""
    try:
        signal, sr = _read_audio(audio_path)
    except Exception:  # noqa: BLE001 - no arc on read failure
        return []
    total_sec = len(signal) / sr if sr else 0.0
    if total_sec <= 0:
        return []
    n = min(max_windows, max(1, int(total_sec // window_sec) or 1))
    step = total_sec / n
    points: list[ArcPoint] = []
    for i in range(n):
        start = i * step
        clip = slice_signal(signal, sr, start, start + step, max_sec=window_sec)
        if len(clip) == 0:
            continue
        valence, _, _ = predict_vad(clip, sr)
        points.append(ArcPoint(t=round(start + step / 2.0, 2), score=round(2.0 * valence - 1.0, 4)))
    return points
```

(Place the `from app.schemas.models import ArcPoint, TranscriptSegment` and `from dataclasses import dataclass` with the other top-of-file imports; everything else appends after the seams.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_emotion_compute.py -v`
Expected: PASS (4 tests). Note `test_compute_arc_windows` expects 3 windows for 60s/20s.

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/analyze/emotion.py python-worker/tests/test_emotion_compute.py && git commit -m "feat(worker): per-speaker emotion aggregation and emotional arc"
```

---

## Task 6: `prepare_emotion` download + CLI command

**Files:**
- Modify: `python-worker/app/analyze/emotion.py` (add `prepare_emotion_model`)
- Modify: `python-worker/app/cli.py` (add the `prepare_emotion` command)
- Test: `python-worker/tests/test_prepare_emotion.py`

> **Confirm against `audeer` during implementation:** `audeer.download_url(url, dest)` and
> `audeer.extract_archive(archive, out_dir)` (names/return values). Adjust the body of
> `prepare_emotion_model` if the real API differs; keep its signature.

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_prepare_emotion.py`:

```python
from app.analyze import emotion as emo


def test_prepare_idempotent_when_ready(tmp_path, monkeypatch):
    monkeypatch.setattr(emo, "emotion_model_dir", lambda: str(tmp_path))
    monkeypatch.setattr(emo, "is_emotion_model_ready", lambda: True)
    called = {"download": 0}
    monkeypatch.setattr(emo, "_download_and_extract", lambda d: called.__setitem__("download", called["download"] + 1))
    emo.prepare_emotion_model()
    assert called["download"] == 0  # already present -> no download


def test_prepare_downloads_when_absent(tmp_path, monkeypatch):
    monkeypatch.setattr(emo, "emotion_model_dir", lambda: str(tmp_path))
    monkeypatch.setattr(emo, "is_emotion_model_ready", lambda: False)
    called = {"download": 0}
    monkeypatch.setattr(emo, "_download_and_extract", lambda d: called.__setitem__("download", called["download"] + 1))
    emo.prepare_emotion_model()
    assert called["download"] == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_prepare_emotion.py -v`
Expected: FAIL — `prepare_emotion_model`/`_download_and_extract` missing.

- [ ] **Step 3: Implement the download (append to `emotion.py`)**

```python
_ZENODO_URL = "https://zenodo.org/record/6221127/files/w2v2-L-robust-12.6bc4a7fd-1.1.0.zip"


def _download_and_extract(directory: str) -> None:
    """Download the Zenodo archive and extract it into `directory`. Lazy-imports
    audeer."""
    import audeer  # lazy

    audeer.mkdir(directory)
    archive = audeer.download_url(_ZENODO_URL, directory, verbose=False)
    audeer.extract_archive(archive, directory)


def prepare_emotion_model() -> None:
    """Ensure the emotion model is downloaded+extracted. Idempotent."""
    if is_emotion_model_ready():
        return
    _download_and_extract(emotion_model_dir())
```

- [ ] **Step 4: Add the CLI command (modify `cli.py`)**

Add the import near the others: `from app.analyze.emotion import prepare_emotion_model`.

Add this command (e.g. after the `export` command, before the `cli.add_command(...)` line):

```python
@cli.command(name="prepare_emotion")
def prepare_emotion() -> None:
    """Download the acoustic-emotion model (triggered from Settings)."""
    raw = click.get_text_stream("stdin").read().strip()
    if _check_ping(raw):
        return
    job_id = "prepare_emotion"
    try:
        data = json.loads(raw) if raw else {}
        job_id = data.get("job_id", job_id)
    except json.JSONDecodeError:
        pass

    report_progress(job_id, 0.1, "downloading emotion model")
    try:
        prepare_emotion_model()
    except Exception as exc:  # noqa: BLE001 - surface as an error result
        report_result(JobResult(job_id=job_id, status="error", error_message=str(exc)))
        return
    report_progress(job_id, 1.0, "done")
    report_result(JobResult(job_id=job_id, status="completed"))
```

- [ ] **Step 5: Run tests + full suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_prepare_emotion.py -v` (2 pass)
Run: `cd python-worker && ./.venv/bin/python -m pytest -q` (all pass)

- [ ] **Step 6: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/analyze/emotion.py python-worker/app/cli.py python-worker/tests/test_prepare_emotion.py && git commit -m "feat(worker): prepare_emotion model download command"
```

---

## Task 7: Sentiment tone reconciliation

**Files:**
- Modify: `python-worker/app/analyze/sentiment.py`
- Test: `python-worker/tests/test_sentiment_reconcile.py`

The `emotion` param is a plain `dict[str, dict]` (`{label: {"valence","arousal","dominant_emotion"}}`) so `sentiment.py` stays free of `emotion.py`/ML imports.

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_sentiment_reconcile.py`:

```python
from unittest.mock import MagicMock, patch

from app.analyze.sentiment import _tone_block, analyze_sentiment
from app.schemas.models import TranscriptSegment


def _segs():
    return [TranscriptSegment(start=0, end=2, text="ok", speaker="You")]


def test_tone_block_empty_when_no_emotion():
    assert _tone_block(None) == ""
    assert _tone_block({}) == ""


def test_tone_block_lists_speakers():
    block = _tone_block({"You": {"valence": 0.7, "arousal": 0.5, "dominant_emotion": "content"}})
    assert "You" in block and "content" in block
    assert "0.7" in block


def test_emotion_passed_into_prompt(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {"overall": "positive", "overall_score": 0.5, "by_speaker": {}}
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        analyze_sentiment(_segs(), emotion={"You": {"valence": 0.7, "arousal": 0.5, "dominant_emotion": "content"}})
    user_arg = fake.complete_json.call_args.kwargs["user"]
    assert "Vocal tone" in user_arg
    assert "content" in user_arg


def test_no_emotion_keeps_4a_prompt(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {"overall": "neutral", "overall_score": 0.0, "by_speaker": {}}
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        analyze_sentiment(_segs())
    user_arg = fake.complete_json.call_args.kwargs["user"]
    assert "Vocal tone" not in user_arg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_reconcile.py -v`
Expected: FAIL — `_tone_block` missing / "Vocal tone" not in prompt.

- [ ] **Step 3: Implement (modify `sentiment.py`)**

Add the helper (after `_transcript_text`):

```python
def _tone_block(emotion: dict | None) -> str:
    """Acoustic-tone context for the prompt, or '' when no emotion is available."""
    if not emotion:
        return ""
    lines = ["Vocal tone (acoustic emotion):"]
    for label, e in emotion.items():
        try:
            valence = float(e.get("valence", 0.0))
            arousal = float(e.get("arousal", 0.0))
        except (TypeError, ValueError, AttributeError):
            continue
        dom = e.get("dominant_emotion", "neutral") if isinstance(e, dict) else "neutral"
        lines.append(f"- {label} sounded {dom} (valence {valence:.2f}, arousal {arousal:.2f}).")
    lines.append("Reconcile the text sentiment with this vocal tone.\n")
    return "\n".join(lines)
```

In `analyze_sentiment`, change the `complete_json` user argument to prepend the tone block:

```python
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"{_tone_block(emotion)}Transcript:\n\n{_transcript_text(segments)}",
        )
```

(The `emotion` parameter already exists on `analyze_sentiment`; only the `user=` line changes.)

- [ ] **Step 4: Run tests + full suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_reconcile.py -v` (4 pass)
Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment.py -q` (4a tests still pass — the no-emotion prompt is unchanged aside from an empty prefix)

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/analyze/sentiment.py python-worker/tests/test_sentiment_reconcile.py && git commit -m "feat(worker): reconcile sentiment with acoustic tone in the prompt"
```

---

## Task 8: Pipeline wiring (emotion → SpeakerStats, arc, sentiment)

**Files:**
- Modify: `python-worker/app/cli.py`
- Test: `python-worker/tests/test_pipeline_emotion.py`

- [ ] **Step 1: Add imports + thread emotion through `_write_analysis`**

In `cli.py` add imports:

```python
from app.analyze.emotion import compute_arc, compute_speaker_emotion, is_emotion_model_ready
```

Change `_write_analysis` to accept and merge emotion. Replace its body's `speakers`/`analysis` construction:

```python
def _write_analysis(
    request: JobRequest,
    segments: list[TranscriptSegment],
    sentiment: Sentiment | None = None,
    emotion: dict | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = compute_speaker_stats(segments, self_label="You")
    if emotion:
        speakers = [
            s.model_copy(update={
                "valence": emotion[s.label].valence,
                "arousal": emotion[s.label].arousal,
                "dominant_emotion": emotion[s.label].dominant_emotion,
            }) if s.label in emotion else s
            for s in speakers
        ]
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
        sentiment=sentiment,
    )
    base = os.path.splitext(request.audio_path)[0]
    analysis_path = f"{base}_analysis.json"
    tmp = analysis_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(analysis.model_dump_json(indent=2))
    os.replace(tmp, analysis_path)
    return analysis_path
```

- [ ] **Step 2: Compute emotion + arc in `_run_pipeline` and reconcile**

In `_run_pipeline`, replace:

```python
    sentiment = analyze_sentiment(segments)
    analysis_path = _write_analysis(request, segments, sentiment)
```

with:

```python
    emotion = {}
    arc = []
    if is_emotion_model_ready():
        try:
            emotion = compute_speaker_emotion(segments, request.audio_path)
            arc = compute_arc(request.audio_path)
        except Exception as exc:  # noqa: BLE001 - emotion is best-effort
            sys.stderr.write(json.dumps({"warning": f"emotion failed: {exc}"}) + "\n")
            sys.stderr.flush()
            emotion, arc = {}, []

    emotion_summary = {
        label: {"valence": e.valence, "arousal": e.arousal, "dominant_emotion": e.dominant_emotion}
        for label, e in emotion.items()
    }
    sentiment = analyze_sentiment(segments, emotion=emotion_summary or None)
    if sentiment is not None and arc:
        sentiment = sentiment.model_copy(update={"arc": arc})
    analysis_path = _write_analysis(request, segments, sentiment, emotion)
```

- [ ] **Step 3: Write the integration test**

Create `python-worker/tests/test_pipeline_emotion.py`:

```python
import json
from unittest.mock import patch

from app import cli
from app.analyze.emotion import SpeakerEmotion
from app.schemas.models import ArcPoint, JobRequest, Sentiment, SpeakerSentiment, TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="hi", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="hey", speaker="Speaker 1"),
    ]


def test_pipeline_enriches_speakers_and_arc(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)   # generate_markdown -> offline fallback
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    emotion = {
        "You": SpeakerEmotion(valence=0.8, arousal=0.6, dominant_emotion="excited"),
        "Speaker 1": SpeakerEmotion(valence=0.3, arousal=0.7, dominant_emotion="frustrated"),
    }
    sent = Sentiment(overall="positive", overall_score=0.4,
                     by_speaker={"You": SpeakerSentiment(label="positive", score=0.5)})

    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.is_emotion_model_ready", return_value=True), \
         patch("app.cli.compute_speaker_emotion", return_value=emotion), \
         patch("app.cli.compute_arc", return_value=[ArcPoint(t=10.0, score=0.2)]), \
         patch("app.cli.analyze_sentiment", return_value=sent):
        result = cli._run_pipeline(request)

    assert result.status == "completed"
    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    you = next(s for s in analysis["speakers"] if s["label"] == "You")
    assert you["dominant_emotion"] == "excited"
    assert you["valence"] == 0.8
    assert analysis["sentiment"]["arc"][0]["t"] == 10.0


def test_pipeline_skips_emotion_when_model_absent(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    sent = Sentiment(overall="neutral", overall_score=0.0)
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch("app.cli.analyze_sentiment", return_value=sent) as mock_sent:
        result = cli._run_pipeline(request)

    assert result.status == "completed"
    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    you = next(s for s in analysis["speakers"] if s["label"] == "You")
    assert you["valence"] is None
    assert analysis["sentiment"]["arc"] == []
    # analyze_sentiment called with emotion=None when model absent
    assert mock_sent.call_args.kwargs.get("emotion") is None
```

- [ ] **Step 4: Run tests + full suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_pipeline_emotion.py -v` (2 pass)
Run: `cd python-worker && ./.venv/bin/python -m pytest -q` (all pass)

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add python-worker/app/cli.py python-worker/tests/test_pipeline_emotion.py && git commit -m "feat(worker): wire acoustic emotion into analysis, arc, and sentiment"
```

---

## Task 9: Swift — prepare_emotion request, settings flag, download row

**Files:**
- Modify: `macos-app/Sources/Bridge/Models.swift`
- Modify: `macos-app/Sources/Settings/SettingsManager.swift`
- Modify: `macos-app/Sources/Settings/SettingsView.swift`

UI/wiring is build-verified + human-verified (no new unit tests).

- [ ] **Step 1: Add a `prepareEmotion` request factory (`Models.swift`)**

In `JobRequest`, after the `transcribe(session:settings:)` factory, add:

```swift
    /// Creates a request that asks the worker to download the acoustic-emotion model.
    static func prepareEmotion() -> JobRequest {
        JobRequest(
            jobId: UUID().uuidString,
            command: "prepare_emotion",
            audioPath: "",
            engine: "local_whisper",
            language: "auto",
            speakerDiarization: false,
            markdownProfile: "meeting_notes",
            whisperModel: "base",
            llmEngine: "claude",
            remoteProvider: "groq",
            recordingType: "call_meeting"
        )
    }
```

- [ ] **Step 2: Add the persisted flag (`SettingsManager.swift`)**

After the `diarizationModelsReady` stored property, add:

```swift
    var emotionModelsReady: Bool = false { didSet { persist("emotion_models_ready", String(emotionModelsReady)) } }
```

In `loadAll()`, after the `diarization_models_ready` load line, add:

```swift
        if let raw = rows["emotion_models_ready"] { emotionModelsReady = raw == "true" }
```

- [ ] **Step 3: Add the download row + wire it into the speaker section (`SettingsView.swift`)**

In `speakerSection`, after the `DiarizationModelsRow(...)`, add an emotion row:

```swift
            EmotionModelsRow(
                bridge: appModel.pythonBridge,
                modelsReady: $settings.emotionModelsReady
            )
```

At the end of the file (after `DiarizationModelsRow`), add:

```swift
/// Shows acoustic-emotion model status and a download button. The model lives in the
/// Python worker, so the download runs the `prepare_emotion` worker command via the bridge.
@available(macOS 14.2, *)
private struct EmotionModelsRow: View {
    let bridge: PythonBridge
    @Binding var modelsReady: Bool

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Emotion model")
                Spacer()
                statusLabel
            }
            Button(isDownloading ? "Downloading…" : "Download emotion model") {
                download()
            }
            .disabled(isDownloading || modelsReady)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Adds per-speaker emotion (valence/arousal) and an emotional arc. Large one-time download (~1 GB); analysis still runs without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloading {
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        } else if modelsReady {
            Text("Ready").font(.caption).foregroundStyle(.green)
        } else {
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func download() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                let result = try await bridge.runJob(request: .prepareEmotion())
                if result.status == "completed" {
                    modelsReady = true
                } else {
                    errorMessage = result.errorMessage ?? "Download failed"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}
```

- [ ] **Step 4: Build + test**

Run: `cd macos-app && swift build 2>&1 | tail -5` → `Build complete!`
Run: `cd macos-app && swift test 2>&1 | tail -5` → all pass (unchanged count; no new Swift tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/bodharma/dev/repos/personal/call-capture-macos && git add macos-app/Sources/Bridge/Models.swift macos-app/Sources/Settings/SettingsManager.swift macos-app/Sources/Settings/SettingsView.swift && git commit -m "feat(app): emotion model download in Settings via prepare_emotion command"
```

---

## Final verification

- [ ] **Worker suite:** `cd python-worker && ./.venv/bin/python -m pytest -q` — all pass (no audonnx/onnxruntime needed; seams mocked).
- [ ] **Swift:** `cd macos-app && swift build && swift test` — build clean, tests pass.
- [ ] **Human live check (needs the full stack + ~1 GB download — cannot be done by an agent):**
  1. `cd python-worker && ./.venv/bin/python -m pip install -e .` (installs audonnx/audeer/audiofile/onnxruntime).
  2. `./run-dev.sh`, Settings → **Download emotion model** → reaches **Ready** (worker downloads from Zenodo).
  3. Record a Call/Meeting (mic + 2+ remote speakers), process, and confirm `<id>_analysis.json` has per-speaker `valence`/`arousal`/`dominant_emotion` and a non-empty `sentiment.arc`; sentiment should reflect tone. Confirm the audonnx `logits` order is `[arousal, dominance, valence]` (the `predict_vad` reorder) on real output.

## Notes for Phase 5/6

- Phase 5 folds emotion + reconciled sentiment into per-type note shapes (the minimal `## Sentiment` section becomes part of the per-type template).
- Phase 6 renders the arc + per-speaker emotion in Session Detail.
- Deferred (from 4a/4b reviews): extract a shared `resolve_llm_env()` + transcript-formatter helper used by `markdown.py` and `sentiment.py`.
