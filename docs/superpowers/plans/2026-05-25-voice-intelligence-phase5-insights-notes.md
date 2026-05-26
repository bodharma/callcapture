# Phase 5 — Type-Tailored Insights + Per-Type Note Shapes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generic profile-based Markdown note in the transcribe pipeline with a recording-type-tailored note driven by one LLM "insights" pass, persisting structured `Insights` in `<id>_analysis.json` and rendering a per-type `<id>_notes.md`.

**Architecture:** A new `analyze_insights()` LLM analyzer (mirrors `analyze_sentiment` — defensive parse, graceful fallback, never raises) produces a flat-superset `Insights` model. `formatter.render_note()` renders one of three note shapes (call/memo/lecture) from `Insights` + `Sentiment` + `SpeakerStats`. A shared `llm_env.py` helper removes the duplicated LLM-env/transcript/warn code now used by three analyzers. The legacy `generate_markdown`/`render_markdown` path survives only for the standalone `postprocess` command.

**Tech Stack:** Python 3.13, Pydantic v2, Click, pytest, `unittest.mock`. LLM via OpenAI-compatible `LLMClient`. Tests are numpy-only and never hit the network (mock `LLMClient.complete_json` or run the no-key fallback).

**Spec:** `docs/superpowers/specs/2026-05-25-phase5-insights-notes-design.md`

---

## File Structure

- **Create** `app/postprocess/llm_env.py` — `LlmEnv` dataclass, `resolve_llm_env()`, `warn()`, `transcript_text()`. Shared by the three LLM analyzers.
- **Create** `app/analyze/insights.py` — `analyze_insights()` + per-type prompts + defensive parse + rule-based fallback.
- **Modify** `app/schemas/models.py` — add `Insights`; add `insights` field to `ConversationAnalysis`.
- **Modify** `app/postprocess/markdown.py` — refactor onto `llm_env` helpers (behavior unchanged).
- **Modify** `app/analyze/sentiment.py` — refactor onto `llm_env` helpers (behavior unchanged).
- **Modify** `app/postprocess/formatter.py` — add `render_note()` + per-type renderers; delete `render_sentiment_section`.
- **Modify** `app/cli.py` — wire `analyze_insights` + `render_note` into `_run_pipeline`; add `_build_speakers`; add `insights` to `_write_analysis`.
- **Create tests** `tests/test_llm_env.py`, `tests/test_insights.py`, `tests/test_insights_schema.py`, `tests/test_render_note.py`, `tests/test_pipeline_insights.py`.
- **Delete test** `tests/test_sentiment_section.py` (the function it covers is removed; coverage moves to `test_render_note.py`).

Run tests from `python-worker/`. Test command prefix: `uv run pytest` (fall back to `pytest` if `uv` is unavailable).

---

## Task 1: Shared `llm_env.py` helper + refactor existing analyzers

**Files:**
- Create: `app/postprocess/llm_env.py`
- Test: `tests/test_llm_env.py`
- Modify: `app/postprocess/markdown.py`
- Modify: `app/analyze/sentiment.py`

- [ ] **Step 1: Write the failing test** — `tests/test_llm_env.py`

```python
from app.postprocess.llm_env import LlmEnv, resolve_llm_env, transcript_text, warn
from app.schemas.models import TranscriptSegment


def test_resolve_defaults(monkeypatch):
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.delenv("LLM_MODEL", raising=False)
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    env = resolve_llm_env()
    assert isinstance(env, LlmEnv)
    assert env.base_url == "https://openrouter.ai/api/v1"
    assert env.model == "google/gemini-2.5-flash"
    assert env.api_key == ""
    assert env.is_local is False


def test_resolve_local_detection(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://localhost:11434/v1")
    assert resolve_llm_env().is_local is True


def test_resolve_reads_overrides(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_MODEL", "anthropic/claude-sonnet-4.6")
    monkeypatch.setenv("LLM_API_KEY", "sk-x")
    env = resolve_llm_env()
    assert env.model == "anthropic/claude-sonnet-4.6"
    assert env.api_key == "sk-x"
    assert env.is_local is False


def test_transcript_text_plain():
    segs = [TranscriptSegment(start=0.0, end=1.0, text="hi", speaker="You")]
    assert transcript_text(segs) == "[You] hi"


def test_transcript_text_timestamps():
    segs = [TranscriptSegment(start=2.0, end=3.0, text="hi", speaker="You")]
    assert transcript_text(segs, timestamps=True) == "[2.0s] [You] hi"


def test_transcript_text_no_speaker():
    segs = [TranscriptSegment(start=0.0, end=1.0, text="hi")]
    assert transcript_text(segs) == "hi"


def test_warn_writes_json(capsys):
    warn("boom")
    assert '{"warning": "boom"}' in capsys.readouterr().err
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_llm_env.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.postprocess.llm_env'`

- [ ] **Step 3: Create `app/postprocess/llm_env.py`**

```python
"""Shared helpers for the LLM-backed analyzers (markdown, sentiment, insights):
endpoint resolution, stderr warnings, and transcript formatting."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass

from app.postprocess.llm_client import OPENROUTER_BASE_URL
from app.schemas.models import TranscriptSegment

_DEFAULT_MODEL = "google/gemini-2.5-flash"


@dataclass(frozen=True)
class LlmEnv:
    """Resolved LLM endpoint configuration from the LLM_* environment."""

    base_url: str
    model: str
    api_key: str
    is_local: bool


def resolve_llm_env() -> LlmEnv:
    """Read LLM_BASE_URL / LLM_MODEL / LLM_API_KEY (OpenRouter defaults).

    `is_local` is True when the base URL is not an openrouter.ai endpoint (e.g. a
    local Ollama/LM Studio server), in which case a missing API key is acceptable.
    """
    base_url = os.environ.get("LLM_BASE_URL", OPENROUTER_BASE_URL)
    model = os.environ.get("LLM_MODEL", _DEFAULT_MODEL)
    api_key = os.environ.get("LLM_API_KEY", "")
    is_local = "openrouter.ai" not in base_url
    return LlmEnv(base_url=base_url, model=model, api_key=api_key, is_local=is_local)


def warn(message: str) -> None:
    """Write a `{"warning": ...}` JSON line to stderr and flush."""
    sys.stderr.write(json.dumps({"warning": message}) + "\n")
    sys.stderr.flush()


def transcript_text(segments: list[TranscriptSegment], *, timestamps: bool = False) -> str:
    """Speaker-labeled transcript text for an LLM prompt.

    `timestamps=True` prefixes each line with `[12.3s] ` (markdown.py's format);
    the default omits timestamps (sentiment.py's format).
    """
    lines: list[str] = []
    for s in segments:
        speaker = f"[{s.speaker}] " if s.speaker else ""
        if timestamps:
            lines.append(f"[{s.start:.1f}s] {speaker}{s.text}")
        else:
            lines.append(f"{speaker}{s.text}")
    return "\n".join(lines)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_llm_env.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Refactor `app/analyze/sentiment.py` onto the shared helpers**

Replace the module's imports block and delete the now-shared locals `_transcript_text` and `_warn`. Keep `_clamp`, `_norm_label`, `_to_score`, `_neutral_fallback`, `_tone_block`, `_build_sentiment`, `_distinct_speakers`.

Change the imports (top of file) to:

```python
from __future__ import annotations

import math

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import resolve_llm_env, transcript_text, warn
from app.schemas.models import Sentiment, SpeakerSentiment, TranscriptSegment
```

Delete the `_transcript_text` function and the `_warn` function. Replace every `_warn(` call with `warn(`. In `analyze_sentiment`, replace the env block:

```python
    base_url = os.environ.get("LLM_BASE_URL", OPENROUTER_BASE_URL)
    model = os.environ.get("LLM_MODEL", "google/gemini-2.5-flash")
    api_key = os.environ.get("LLM_API_KEY", "")
    is_local = "openrouter.ai" not in base_url

    if not api_key and not is_local:
        _warn("no LLM_API_KEY for cloud endpoint, using neutral sentiment")
        return _neutral_fallback(segments)

    try:
        client = LLMClient(api_key=api_key, model=model, base_url=base_url)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"{_tone_block(emotion)}Transcript:\n\n{_transcript_text(segments)}",
        )
        return _build_sentiment(data, segments)
    except (LLMError, ValueError, TypeError, AttributeError, KeyError) as exc:
        _warn(f"sentiment failed: {exc}, using neutral sentiment")
        return _neutral_fallback(segments)
```

with:

```python
    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using neutral sentiment")
        return _neutral_fallback(segments)

    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"{_tone_block(emotion)}Transcript:\n\n{transcript_text(segments)}",
        )
        return _build_sentiment(data, segments)
    except (LLMError, ValueError, TypeError, AttributeError, KeyError) as exc:
        warn(f"sentiment failed: {exc}, using neutral sentiment")
        return _neutral_fallback(segments)
```

Note: `LLMClient` stays imported in `sentiment.py` so existing tests that `patch("app.analyze.sentiment.LLMClient", ...)` keep working. Remove the now-unused `OPENROUTER_BASE_URL` import (it lived in the old import line shown above; the new imports omit it). `import json`, `import os`, `import sys` are removed; `import math` stays (used by `_to_score`).

- [ ] **Step 6: Refactor `app/postprocess/markdown.py` onto the shared helpers**

Replace the imports and delete the local `_transcript_to_text`. New imports:

```python
from __future__ import annotations

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import resolve_llm_env, transcript_text, warn
from app.schemas.models import MarkdownNote, TranscriptSegment
```

Delete `_transcript_to_text`. Keep `_fallback_extraction` and `_SYSTEM_PROMPT`. Replace the body of `generate_markdown` (the env block + try) with:

```python
    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using fallback")
        return _fallback_extraction(segments)

    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"Transcript:\n\n{transcript_text(segments, timestamps=True)}",
        )
        return MarkdownNote(
            title=data.get("title", "Untitled"),
            summary=data.get("summary", "")[:499],
            key_points=data.get("key_points", []),
            decisions=data.get("decisions", []),
            action_items=data.get("action_items", []),
            transcript_segments=list(segments),
        )
    except LLMError as exc:
        warn(f"LLM failed: {exc}, using fallback")
        return _fallback_extraction(segments)
```

Remove the now-unused `import json`, `import os`, `import sys`, and the `OPENROUTER_BASE_URL` import. `LLMClient` stays imported so `patch("app.postprocess.markdown.LLMClient", ...)` still works.

- [ ] **Step 7: Run the regression + new suites**

Run: `uv run pytest tests/test_llm_env.py tests/test_sentiment.py tests/test_sentiment_reconcile.py tests/test_markdown_llm.py -v`
Expected: PASS (all previously-passing sentiment/markdown tests stay green; new llm_env tests pass)

- [ ] **Step 8: Commit**

```bash
git add app/postprocess/llm_env.py tests/test_llm_env.py app/analyze/sentiment.py app/postprocess/markdown.py
git commit -m "refactor(worker): extract shared llm_env helper for LLM analyzers"
```

---

## Task 2: `Insights` model + `ConversationAnalysis.insights`

**Files:**
- Modify: `app/schemas/models.py`
- Test: `tests/test_insights_schema.py`

- [ ] **Step 1: Write the failing test** — `tests/test_insights_schema.py`

```python
import pytest
from pydantic import ValidationError

from app.schemas.models import ConversationAnalysis, Insights


def test_defaults_all_empty():
    i = Insights()
    assert i.title == "Untitled"
    assert i.summary == ""
    assert i.key_points == []
    assert i.action_items == []
    assert i.recommended_actions == []
    assert i.dynamics == ""
    assert i.opportunities == []
    assert i.reflections == []
    assert i.outline == []
    assert i.key_concepts == []
    assert i.qa == []
    assert i.takeaways == []


def test_summary_length_validator():
    with pytest.raises(ValidationError):
        Insights(summary="x" * 501)


def test_frozen_instance():
    i = Insights()
    with pytest.raises(ValidationError):
        i.summary = "nope"


def test_conversation_analysis_carries_insights():
    a = ConversationAnalysis(insights=Insights(title="T", summary="S", key_points=["k"]))
    assert a.insights is not None
    assert a.insights.title == "T"
    assert a.model_dump()["insights"]["summary"] == "S"


def test_conversation_analysis_insights_default_none():
    assert ConversationAnalysis().insights is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_insights_schema.py -v`
Expected: FAIL — `ImportError: cannot import name 'Insights'`

- [ ] **Step 3: Add the `Insights` model to `app/schemas/models.py`**

Insert this class immediately before `class ConversationAnalysis` (after `class Sentiment`):

```python
class Insights(BaseModel, frozen=True):
    """Type-tailored conversation insights (Phase 5).

    Flat superset: every field is optional with an empty default. Each recording type
    fills only its relevant subset (call: dynamics/opportunities/recommended_actions/
    action_items; voice_memo: key_points/action_items/reflections; lecture: outline/
    key_concepts/qa/takeaways). `summary` and `title` are shared by all types.
    """

    title: str = "Untitled"
    summary: str = ""
    key_points: list[str] = Field(default_factory=list)
    action_items: list[str] = Field(default_factory=list)
    recommended_actions: list[str] = Field(default_factory=list)
    dynamics: str = ""
    opportunities: list[str] = Field(default_factory=list)
    reflections: list[str] = Field(default_factory=list)
    outline: list[str] = Field(default_factory=list)
    key_concepts: list[str] = Field(default_factory=list)
    qa: list[str] = Field(default_factory=list)
    takeaways: list[str] = Field(default_factory=list)

    @field_validator("summary")
    @classmethod
    def summary_must_be_short(cls, v: str) -> str:
        if len(v) > 500:
            raise ValueError("summary must be <500 characters")
        return v
```

Then add the `insights` field to `ConversationAnalysis` (after the `sentiment` field):

```python
    sentiment: Sentiment | None = None
    insights: Insights | None = None
```

(`Field` and `field_validator` are already imported at the top of the file.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_insights_schema.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add app/schemas/models.py tests/test_insights_schema.py
git commit -m "feat(worker): add Insights model and ConversationAnalysis.insights"
```

---

## Task 3: `insights.py` type-tailored analyzer

**Files:**
- Create: `app/analyze/insights.py`
- Test: `tests/test_insights.py`

- [ ] **Step 1: Write the failing test** — `tests/test_insights.py`

```python
from unittest.mock import MagicMock, patch

from app.analyze.insights import analyze_insights
from app.postprocess.llm_client import LLMError
from app.schemas.models import Insights, Sentiment, TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="let's close the deal", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="I need to think", speaker="Speaker 1"),
    ]


def test_empty_returns_none():
    assert analyze_insights([], recording_type="call_meeting") is None


def test_no_key_cloud_returns_fallback(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    ins = analyze_insights(_segs(), recording_type="voice_memo")
    assert isinstance(ins, Insights)
    assert ins.summary != ""
    assert ins.key_points  # fallback fills key_points from segments
    assert ins.reflections == []  # type-specific extras stay empty in fallback


def test_call_happy_path_filters_to_call_fields(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "Deal Call",
        "summary": "Discussed closing.",
        "dynamics": "You drove it.",
        "opportunities": ["address hesitation"],
        "recommended_actions": ["send proposal"],
        "action_items": ["follow up Monday"],
        "outline": ["should be dropped"],  # not a call field
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="call_meeting")
    assert ins.title == "Deal Call"
    assert ins.dynamics == "You drove it."
    assert ins.opportunities == ["address hesitation"]
    assert ins.recommended_actions == ["send proposal"]
    assert ins.action_items == ["follow up Monday"]
    assert ins.outline == []  # dropped — not in call field set


def test_lecture_uses_lecture_prompt_and_fields(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "Bio 101",
        "summary": "Cells.",
        "outline": ["intro", "mitosis"],
        "key_concepts": ["cell"],
        "qa": ["Q: why? A: because"],
        "takeaways": ["cells divide"],
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="lecture")
    system_arg = fake.complete_json.call_args.kwargs["system"]
    assert "lecture/talk" in system_arg
    assert ins.outline == ["intro", "mitosis"]
    assert ins.takeaways == ["cells divide"]
    assert ins.action_items == []  # not a lecture field


def test_defensive_parse_drops_non_str_and_clamps(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": 123,                       # non-str -> derived from first segment
        "summary": "x" * 600,               # clamped to 499
        "key_points": ["ok", 5, "", "  "],   # drops 5, "", "  "
        "action_items": "not a list",        # -> []
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="voice_memo")
    assert len(ins.summary) == 499
    assert ins.key_points == ["ok"]
    assert ins.action_items == []
    assert ins.title == "let's close the deal"  # from segments[0].text


def test_llm_error_returns_fallback(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.side_effect = LLMError("boom")
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="call_meeting")
    assert ins.summary != ""  # fallback summary from segments


def test_context_block_includes_sentiment_and_tone(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {"title": "t", "summary": "s"}
    sent = Sentiment(overall="positive", overall_score=0.5)
    emo = {"You": {"valence": 0.3, "arousal": 0.2, "dominant_emotion": "calm"}}
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        analyze_insights(_segs(), recording_type="call_meeting", sentiment=sent, emotion=emo)
    user_arg = fake.complete_json.call_args.kwargs["user"]
    assert "Overall sentiment: positive" in user_arg
    assert "You sounded calm" in user_arg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_insights.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.analyze.insights'`

- [ ] **Step 3: Create `app/analyze/insights.py`**

```python
"""Type-tailored LLM conversation insights (Phase 5).

One LLM pass produces the structured payload that drives both <id>_analysis.json and
the per-type Markdown note. Mirrors app.analyze.sentiment: reuses the shared LLM env
helper and never raises into the pipeline — an unusable endpoint or any failure yields
a rule-based fallback that still renders a (sparse) note.
"""

from __future__ import annotations

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import resolve_llm_env, transcript_text, warn
from app.schemas.models import Insights, Sentiment, TranscriptSegment

_CALL_PROMPT = (
    "You are a conversation strategist analyzing a call/meeting transcript. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"dynamics": str (who drove the conversation, momentum shifts, agreement/hesitation), '
    '"opportunities": [str (persuasion openings, unaddressed objections)], '
    '"recommended_actions": [str (next moves)], '
    '"action_items": [str (concrete follow-ups)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_MEMO_PROMPT = (
    "You are a note-taking assistant for a personal voice memo. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"key_points": [str], "action_items": [str (concrete follow-ups)], '
    '"reflections": [str (open questions, things to revisit)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_LECTURE_PROMPT = (
    "You are a study assistant summarizing a lecture/talk transcript. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"outline": [str (section headers in order)], '
    '"key_concepts": [str (terms or ideas with a brief gloss)], '
    '"qa": [str (questions raised and their answers, if any)], '
    '"takeaways": [str (what to remember)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_PROMPTS = {
    "call_meeting": _CALL_PROMPT,
    "voice_memo": _MEMO_PROMPT,
    "lecture": _LECTURE_PROMPT,
}

# Which Insights fields each type may populate; all others keep their defaults.
_FIELDS = {
    "call_meeting": ("dynamics", "opportunities", "recommended_actions", "action_items"),
    "voice_memo": ("key_points", "action_items", "reflections"),
    "lecture": ("outline", "key_concepts", "qa", "takeaways"),
}

# Of the type-specific fields above, which are list[str] (everything except "dynamics").
_LIST_FIELDS = {
    "key_points", "action_items", "recommended_actions", "opportunities",
    "reflections", "outline", "key_concepts", "qa", "takeaways",
}


def _str_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and item.strip():
            out.append(item.strip())
    return out


def _clean_summary(value: object) -> str:
    return value[:499] if isinstance(value, str) else ""


def _title(value: object, segments: list[TranscriptSegment]) -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()[:120]
    if segments and segments[0].text.strip():
        return segments[0].text.strip()[:60]
    return "Untitled"


def _context_block(sentiment: Sentiment | None, emotion: dict | None) -> str:
    """Optional sentiment + acoustic-tone context so insights reconcile with tone."""
    lines: list[str] = []
    if sentiment is not None:
        lines.append(
            f"Overall sentiment: {sentiment.overall} ({sentiment.overall_score:+.2f})."
        )
    if emotion:
        for label, e in emotion.items():
            try:
                valence = float(e.get("valence", 0.0))
                arousal = float(e.get("arousal", 0.0))
            except (TypeError, ValueError, AttributeError):
                continue
            dom = e.get("dominant_emotion", "neutral") if isinstance(e, dict) else "neutral"
            lines.append(f"- {label} sounded {dom} (valence {valence:.2f}, arousal {arousal:.2f}).")
    if not lines:
        return ""
    return "Context:\n" + "\n".join(lines) + "\n\n"


def _fallback_insights(segments: list[TranscriptSegment]) -> Insights:
    texts = [s.text for s in segments if s.text.strip()]
    title = (texts[0][:60] if texts else "Untitled") or "Untitled"
    summary = " ".join(texts)[:499]
    return Insights(title=title, summary=summary, key_points=texts[:5])


def _build_insights(
    data: dict, recording_type: str, segments: list[TranscriptSegment]
) -> Insights:
    fields = _FIELDS.get(recording_type, _FIELDS["call_meeting"])
    payload: dict[str, object] = {
        "title": _title(data.get("title"), segments),
        "summary": _clean_summary(data.get("summary")),
    }
    for name in fields:
        raw = data.get(name)
        if name in _LIST_FIELDS:
            payload[name] = _str_list(raw)
        else:  # "dynamics" — the only non-list type-specific field
            payload[name] = raw.strip() if isinstance(raw, str) else ""
    return Insights(**payload)


def analyze_insights(
    segments: list[TranscriptSegment],
    *,
    recording_type: str,
    sentiment: Sentiment | None = None,
    emotion: dict | None = None,
) -> Insights | None:
    """Produce type-tailored Insights from speaker-labeled segments via the LLM.

    Returns None for an empty transcript. Never raises: no API key (cloud) or any
    failure yields a rule-based fallback covering the shared fields.
    """
    if not segments:
        return None

    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using fallback insights")
        return _fallback_insights(segments)

    system = _PROMPTS.get(recording_type, _CALL_PROMPT)
    user = f"{_context_block(sentiment, emotion)}Transcript:\n\n{transcript_text(segments)}"
    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(system=system, user=user)
        if not isinstance(data, dict):
            raise LLMError("non-dict JSON from LLM")
        return _build_insights(data, recording_type, segments)
    except (LLMError, ValueError, TypeError, AttributeError, KeyError) as exc:
        warn(f"insights failed: {exc}, using fallback insights")
        return _fallback_insights(segments)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_insights.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Commit**

```bash
git add app/analyze/insights.py tests/test_insights.py
git commit -m "feat(worker): type-tailored LLM insights analyzer"
```

---

## Task 4: Per-type note rendering in `formatter.py`

**Files:**
- Modify: `app/postprocess/formatter.py`
- Test: `tests/test_render_note.py`
- Delete: `tests/test_sentiment_section.py`

- [ ] **Step 1: Write the failing test** — `tests/test_render_note.py`

```python
from app.postprocess.formatter import render_note
from app.schemas.models import (
    Insights,
    Sentiment,
    SpeakerSentiment,
    SpeakerStats,
    TranscriptSegment,
)


def _speakers():
    return [
        SpeakerStats(label="You", is_self=True, talk_seconds=30.0, talk_ratio=0.6,
                     words=100, words_per_min=140.0, turns=5, dominant_emotion="calm"),
        SpeakerStats(label="Speaker 1", talk_ratio=0.4, words=60, words_per_min=120.0,
                     turns=4, dominant_emotion="sad"),
    ]


def _sentiment():
    return Sentiment(overall="positive", overall_score=0.5,
                     by_speaker={"You": SpeakerSentiment(label="positive", score=0.6)})


def _segs():
    return [TranscriptSegment(start=0.0, end=2.0, text="hi", speaker="You")]


def test_call_note_sections():
    ins = Insights(title="Deal", summary="Closed.", dynamics="You led.",
                   opportunities=["push"], recommended_actions=["send"],
                   action_items=["call Bob"])
    out = render_note("call_meeting", ins, _sentiment(), _speakers(), _segs())
    assert out.startswith("---\n")
    assert "recording_type: call_meeting" in out
    assert "# Deal" in out
    assert "**Summary:** Closed." in out
    assert "## Participants" in out
    assert "| You |" in out
    assert "Tone" in out  # at least one speaker has dominant_emotion
    assert "## Sentiment" in out
    assert "**Overall:** positive (+0.50)" in out
    assert "## Conversation Insights" in out
    assert "You led." in out
    assert "### Opportunities" in out
    assert "### Recommended Actions" in out
    assert "### Action Items" in out
    assert "- [ ] call Bob" in out
    assert "## Transcript" in out


def test_call_note_omits_empty_sections():
    ins = Insights(title="T", summary="S")
    out = render_note("call_meeting", ins, None, [], [])
    assert "## Participants" not in out  # no speakers
    assert "## Sentiment" not in out      # sentiment None
    assert "## Conversation Insights" not in out
    assert "## Transcript" not in out
    assert "sentiment:" not in out        # frontmatter omits sentiment when None


def test_memo_note_shape():
    ins = Insights(title="Memo", summary="Did stuff.", key_points=["a", "b"],
                   action_items=["do x"], reflections=["why?"])
    out = render_note("voice_memo", ins, _sentiment(), [], _segs())
    assert "# Memo" in out
    assert "## Summary" in out
    assert "Did stuff." in out
    assert "## Key Points" in out
    assert "- a" in out
    assert "## Action Items" in out
    assert "- [ ] do x" in out
    assert "## Reflections" in out
    assert "- why?" in out
    assert "## Transcript" not in out
    assert "## Participants" not in out
    assert "## Sentiment" not in out      # memo body has no Sentiment section
    assert "sentiment: positive" in out   # but frontmatter carries it


def test_lecture_note_shape():
    ins = Insights(title="Bio", summary="Cells.", outline=["intro"],
                   key_concepts=["cell"], qa=["Q/A"], takeaways=["divide"])
    out = render_note("lecture", ins, None, [], _segs())
    assert "# Bio" in out
    assert "## Outline" in out
    assert "- intro" in out
    assert "## Key Concepts" in out
    assert "## Summary" in out
    assert "Cells." in out
    assert "## Q&A" in out
    assert "## Takeaways" in out
    assert "- divide" in out


def test_unknown_type_falls_back_to_call():
    ins = Insights(title="X", summary="Y", dynamics="Z")
    out = render_note("interview", ins, None, [], [])
    assert "# X" in out
    assert "## Conversation Insights" in out  # call renderer (dynamics present)


def test_none_insights_renders_minimal():
    out = render_note("voice_memo", None, None, [], [])
    assert out.startswith("---\n")
    assert "# Untitled" in out


def test_participants_table_without_tone():
    speakers = [SpeakerStats(label="You", talk_ratio=1.0, words=10,
                             words_per_min=100.0, turns=1)]
    out = render_note("call_meeting", Insights(title="T", summary="S"), None, speakers, [])
    assert "## Participants" in out
    assert "| 100% |" in out      # talk_ratio 1.0 -> 100%
    assert "Tone" not in out      # no dominant_emotion on any speaker
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_render_note.py -v`
Expected: FAIL — `ImportError: cannot import name 'render_note'`

- [ ] **Step 3: Add rendering to `app/postprocess/formatter.py`**

Update the import line at the top from:

```python
from app.schemas.models import MarkdownNote, Sentiment
```

to:

```python
from app.schemas.models import (
    Insights,
    MarkdownNote,
    Sentiment,
    SpeakerStats,
    TranscriptSegment,
)
```

Delete the entire `render_sentiment_section` function (the last function in the file). Append the following:

```python
def _bullets(items: list[str]) -> list[str]:
    return [f"- {it}" for it in items if it]


def _checkbox_items(items: list[str]) -> list[str]:
    return [f"- [ ] {it}" for it in items if it]


def _section(heading: str, items: list[str]) -> list[str]:
    """A '## Heading' block with its items, or [] when there are no items."""
    if not items:
        return []
    return [heading, "", *items, ""]


def _frontmatter(
    recording_type: str,
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    duration_min = segments[-1].end / 60.0 if segments else 0.0
    lines = [
        "---",
        f'title: "{insights.title}"',
        f"date: {now}",
        f"recording_type: {recording_type}",
        f"num_speakers: {len(speakers)}",
    ]
    if speakers:
        lines.append("participants:")
        for s in speakers:
            lines.append(f"  - {s.label}")
    if sentiment is not None:
        lines.append(f"sentiment: {sentiment.overall} ({sentiment.overall_score:+.2f})")
    lines += [
        "tags:",
        "  - call-notes",
        "  - auto-generated",
        f"duration_min: {duration_min:.1f}",
        "---",
    ]
    return lines


def _participants_table(speakers: list[SpeakerStats]) -> list[str]:
    if not speakers:
        return []
    show_tone = any(s.dominant_emotion for s in speakers)
    header = "| Speaker | Talk % | Words | WPM | Turns |"
    divider = "|---------|-------:|------:|----:|------:|"
    if show_tone:
        header += " Tone |"
        divider += "------|"
    lines = ["## Participants", "", header, divider]
    for s in speakers:
        row = (
            f"| {s.label} | {s.talk_ratio * 100:.0f}% | {s.words} | "
            f"{s.words_per_min:.0f} | {s.turns} |"
        )
        if show_tone:
            row += f" {s.dominant_emotion or '-'} |"
        lines.append(row)
    lines.append("")
    return lines


def _sentiment_section(sentiment: Sentiment | None) -> list[str]:
    if sentiment is None:
        return []
    lines = [
        "## Sentiment",
        "",
        f"**Overall:** {sentiment.overall} ({sentiment.overall_score:+.2f})",
    ]
    if sentiment.by_speaker:
        lines.append("")
        for label, sp in sentiment.by_speaker.items():
            lines.append(f"- **{label}:** {sp.label} ({sp.score:+.2f})")
    lines.append("")
    return lines


def _transcript_section(segments: list[TranscriptSegment]) -> list[str]:
    if not segments:
        return []
    lines = ["## Transcript", ""]
    for seg in segments:
        speaker = f"**{seg.speaker}:** " if seg.speaker else ""
        lines.append(f"`[{seg.start:.1f}s - {seg.end:.1f}s]` {speaker}{seg.text}")
        lines.append("")
    return lines


def _render_call_body(
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    if insights.summary:
        body += [f"**Summary:** {insights.summary}", ""]
    body += _participants_table(speakers)
    body += _sentiment_section(sentiment)

    insight_lines: list[str] = []
    if insights.dynamics:
        insight_lines += [insights.dynamics, ""]
    insight_lines += _section("### Opportunities", _bullets(insights.opportunities))
    insight_lines += _section("### Recommended Actions", _bullets(insights.recommended_actions))
    insight_lines += _section("### Action Items", _checkbox_items(insights.action_items))
    if insight_lines:
        body += ["## Conversation Insights", "", *insight_lines]

    body += _transcript_section(segments)
    return body


def _render_memo_body(
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    body += _section("## Summary", [insights.summary] if insights.summary else [])
    body += _section("## Key Points", _bullets(insights.key_points))
    body += _section("## Action Items", _checkbox_items(insights.action_items))
    body += _section("## Reflections", _bullets(insights.reflections))
    return body


def _render_lecture_body(
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    body += _section("## Outline", _bullets(insights.outline))
    body += _section("## Key Concepts", _bullets(insights.key_concepts))
    body += _section("## Summary", [insights.summary] if insights.summary else [])
    body += _section("## Q&A", _bullets(insights.qa))
    body += _section("## Takeaways", _bullets(insights.takeaways))
    return body


_NOTE_RENDERERS = {
    "call_meeting": _render_call_body,
    "voice_memo": _render_memo_body,
    "lecture": _render_lecture_body,
}


def render_note(
    recording_type: str,
    insights: Insights | None,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> str:
    """Render the per-type Markdown note (frontmatter + body).

    Unknown `recording_type` falls back to the call/meeting shape. A None `insights`
    is treated as an empty `Insights` so the note still renders (minimal).
    """
    ins = insights if insights is not None else Insights()
    renderer = _NOTE_RENDERERS.get(recording_type, _render_call_body)
    body = renderer(ins, sentiment, speakers, segments)
    frontmatter = "\n".join(
        _frontmatter(recording_type, ins, sentiment, speakers, segments)
    )
    return f"{frontmatter}\n\n" + "\n".join(body)
```

(`datetime`/`timezone` are already imported at the top of `formatter.py`.)

- [ ] **Step 4: Delete the obsolete sentiment-section test**

```bash
git rm tests/test_sentiment_section.py
```

(The `render_sentiment_section` function is removed; its behavior is covered by `test_render_note.py::test_call_note_sections`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `uv run pytest tests/test_render_note.py tests/test_formatter.py -v`
Expected: PASS (`test_render_note.py` passes; `test_formatter.py` — which tests `render_markdown` profiles — stays green since those renderers are untouched)

- [ ] **Step 6: Commit**

```bash
git add app/postprocess/formatter.py tests/test_render_note.py
git commit -m "feat(worker): per-type Markdown note rendering; drop sentiment-section placeholder"
```

---

## Task 5: Wire insights + per-type note into the pipeline (`cli.py`)

**Files:**
- Modify: `app/cli.py`
- Test: `tests/test_pipeline_insights.py`

- [ ] **Step 1: Write the failing test** — `tests/test_pipeline_insights.py`

```python
import json
from unittest.mock import patch

from app import cli
from app.schemas.models import Insights, JobRequest, TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="hi there", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="hello back", speaker="Speaker 1"),
    ]


def test_pipeline_writes_insights_and_calls_note(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    ins = Insights(title="Sync", summary="We synced.", dynamics="Balanced.",
                   action_items=["ship it"])
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=ins):
        result = cli._run_pipeline(request)

    assert result.status == "completed"

    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    assert analysis["insights"]["title"] == "Sync"
    assert analysis["insights"]["dynamics"] == "Balanced."

    notes = (tmp_path / "sess_notes.md").read_text()
    assert notes.startswith("---\n")
    assert "recording_type: call_meeting" in notes
    assert "# Sync" in notes
    assert "## Conversation Insights" in notes
    assert "- [ ] ship it" in notes


def test_pipeline_memo_note_shape(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "memo.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio),
                         recording_type="voice_memo")

    ins = Insights(title="Idea", summary="An idea.", key_points=["point"],
                   reflections=["revisit later"])
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=ins):
        result = cli._run_pipeline(request)

    assert result.status == "completed"
    notes = (tmp_path / "memo_notes.md").read_text()
    assert "recording_type: voice_memo" in notes
    assert "## Reflections" in notes
    assert "- revisit later" in notes
    assert "## Conversation Insights" not in notes  # memo shape


def test_pipeline_passes_recording_type_to_analyze_insights(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    audio = tmp_path / "lec.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio),
                         recording_type="lecture")

    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_insights", return_value=Insights(title="L", summary="s")) as m:
        cli._run_pipeline(request)

    assert m.call_args.kwargs["recording_type"] == "lecture"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_pipeline_insights.py -v`
Expected: FAIL — `AttributeError: <module 'app.cli'> does not have the attribute 'analyze_insights'` (patch target missing)

- [ ] **Step 3: Update imports in `app/cli.py`**

Change:

```python
from app.export.writer import write_markdown, write_raw_transcript
from app.analyze.sentiment import analyze_sentiment
from app.postprocess.formatter import render_markdown, render_sentiment_section
from app.postprocess.markdown import generate_markdown
from app.schemas.models import (
    ConversationAnalysis,
    JobRequest,
    JobResult,
    Sentiment,
    TranscriptSegment,
)
```

to:

```python
from app.export.writer import write_markdown, write_raw_transcript
from app.analyze.insights import analyze_insights
from app.analyze.sentiment import analyze_sentiment
from app.postprocess.formatter import render_markdown, render_note
from app.postprocess.markdown import generate_markdown
from app.schemas.models import (
    ConversationAnalysis,
    Insights,
    JobRequest,
    JobResult,
    Sentiment,
    TranscriptSegment,
)
```

(`render_markdown` and `generate_markdown` are kept — the `postprocess` command still uses them.)

- [ ] **Step 4: Add `_build_speakers` and update `_write_analysis`**

Replace the entire `_write_analysis` function with a `_build_speakers` helper plus a slimmer `_write_analysis`:

```python
def _build_speakers(
    segments: list[TranscriptSegment],
    emotion: dict[str, SpeakerEmotion] | None = None,
) -> list[SpeakerStats]:
    """Per-speaker talk metrics, enriched with acoustic emotion when available."""
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
    return speakers


def _write_analysis(
    request: JobRequest,
    segments: list[TranscriptSegment],
    sentiment: Sentiment | None = None,
    emotion: dict[str, SpeakerEmotion] | None = None,
    insights: Insights | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = _build_speakers(segments, emotion)
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
        sentiment=sentiment,
        insights=insights,
    )
    base = os.path.splitext(request.audio_path)[0]
    analysis_path = f"{base}_analysis.json"
    tmp = analysis_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(analysis.model_dump_json(indent=2))
    os.replace(tmp, analysis_path)
    return analysis_path
```

This requires `SpeakerStats` to be importable in `cli.py`. Add it to the `app.schemas.models` import group:

```python
from app.schemas.models import (
    ConversationAnalysis,
    Insights,
    JobRequest,
    JobResult,
    Sentiment,
    SpeakerStats,
    TranscriptSegment,
)
```

`SpeakerEmotion` is already imported from `app.analyze.emotion`; `compute_speaker_stats` is already imported from `app.analyze.metrics`. Note `_write_analysis(request, segments)` (two positional args) still works — `test_pipeline_stems.py` is unaffected.

- [ ] **Step 5: Rewrite the analyze/postprocess section of `_run_pipeline`**

Replace this block (from the emotion computation through the markdown write):

```python
    emotion_summary = {
        label: {"valence": e.valence, "arousal": e.arousal, "dominant_emotion": e.dominant_emotion}
        for label, e in emotion.items()
    }
    sentiment = analyze_sentiment(segments, emotion=emotion_summary or None)
    if sentiment is not None and arc:
        sentiment = sentiment.model_copy(update={"arc": arc})
    analysis_path = _write_analysis(request, segments, sentiment, emotion)

    report_progress(request.job_id, 0.5, "postprocessing")

    note = generate_markdown(segments, profile=request.markdown_profile)

    rendered = render_markdown(note, profile=request.markdown_profile)
    section = render_sentiment_section(sentiment)
    if section:
        rendered = f"{rendered}\n{section}"

    report_progress(request.job_id, 0.8, "exporting")
```

with:

```python
    emotion_summary = {
        label: {"valence": e.valence, "arousal": e.arousal, "dominant_emotion": e.dominant_emotion}
        for label, e in emotion.items()
    }
    sentiment = analyze_sentiment(segments, emotion=emotion_summary or None)
    if sentiment is not None and arc:
        sentiment = sentiment.model_copy(update={"arc": arc})

    insights = analyze_insights(
        segments,
        recording_type=request.recording_type,
        sentiment=sentiment,
        emotion=emotion_summary or None,
    )
    analysis_path = _write_analysis(request, segments, sentiment, emotion, insights)

    report_progress(request.job_id, 0.5, "postprocessing")

    speakers = _build_speakers(segments, emotion)
    rendered = render_note(request.recording_type, insights, sentiment, speakers, segments)

    report_progress(request.job_id, 0.8, "exporting")
```

Leave the rest of `_run_pipeline` (raw transcript + markdown write, duration, result) unchanged.

- [ ] **Step 6: Run the new pipeline test to verify it passes**

Run: `uv run pytest tests/test_pipeline_insights.py -v`
Expected: PASS (3 passed)

- [ ] **Step 7: Run the pipeline regression suite**

Run: `uv run pytest tests/test_pipeline_stems.py tests/test_pipeline_sentiment.py tests/test_pipeline_emotion.py -v`
Expected: PASS — `test_pipeline_sentiment.py` still finds `## Sentiment` + `**Overall:** positive (+0.50)` in the call note; `test_pipeline_emotion.py` still finds emotion-enriched speakers + arc; `test_pipeline_stems.py` still calls `_write_analysis(request, segments)`.

- [ ] **Step 8: Commit**

```bash
git add app/cli.py tests/test_pipeline_insights.py
git commit -m "feat(worker): wire type-tailored insights and per-type note into pipeline"
```

---

## Task 6: Full suite green + final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire worker test suite**

Run: `uv run pytest -q`
Expected: all tests PASS, no errors. If any sentiment/markdown test fails, it indicates the Task 1 refactor changed observable behavior — fix the refactor (not the test) so the warning strings and outputs match the originals.

- [ ] **Step 2: Lint/format check (if configured)**

Run: `uv run ruff check app tests`
Expected: no errors. Fix any unused-import warnings left by the Task 1 refactor (e.g., a stale `OPENROUTER_BASE_URL`/`json`/`os`/`sys` import in `markdown.py` or `sentiment.py`).

- [ ] **Step 3: Smoke-test the no-key pipeline end to end (offline fallback)**

Run:

```bash
uv run python - <<'PY'
import json, tempfile, os
from app import cli
from app.schemas.models import JobRequest, TranscriptSegment
from unittest.mock import patch

d = tempfile.mkdtemp()
audio = os.path.join(d, "s.wav"); open(audio, "wb").close()
req = JobRequest(job_id="x", command="transcribe", audio_path=audio, recording_type="voice_memo")
segs = [TranscriptSegment(start=0.0, end=2.0, text="remember to buy milk", speaker="You")]
os.environ.pop("LLM_API_KEY", None); os.environ.pop("LLM_BASE_URL", None)
with patch("app.cli._transcribe_and_attribute", return_value=segs):
    r = cli._run_pipeline(req)
print("status:", r.status)
print(open(os.path.join(d, "s_notes.md")).read())
print("--- analysis insights ---")
print(json.dumps(json.load(open(os.path.join(d, "s_analysis.json")))["insights"], indent=2))
PY
```

Expected: `status: completed`; a voice-memo note (frontmatter + `# ...` + `## Summary` + `## Key Points`) with no network call; `analysis.insights` populated from the rule-based fallback.

- [ ] **Step 4: Update the roadmap memory**

Edit `/Users/bodharma/.claude/projects/-Users-bodharma-dev-repos-personal-call-capture-macos/memory/voice-intelligence-roadmap.md`: mark Phase 5 DONE with a short summary (insights analyzer, per-type notes, llm_env extraction) and note Phase 6 (UI) as the remaining worker-external phase. This is a memory file, not committed to the repo.

- [ ] **Step 5: Final commit (if any verification fixups were made)**

```bash
git add -A
git commit -m "test(worker): Phase 5 full-suite green and offline smoke check"
```

---

## Self-Review

**Spec coverage:**
- §2 decision 1 (unified type-tailored call, legacy kept for postprocess) → Task 5 (pipeline uses `render_note`; `postprocess` command untouched, keeps `generate_markdown`/`render_markdown`). ✓
- §2 decision 2 + §4 (flat-superset `Insights`) → Task 2. ✓
- §2 decision 3 + §8 (`llm_env.py` extraction, refactor markdown + sentiment) → Task 1. ✓
- §5 (`analyze_insights`: per-type prompts, context block, defensive parse, fallback, never raises) → Task 3. ✓
- §6 (per-type note shapes, frontmatter, participants table, sentiment/transcript only in call) → Task 4. ✓
- §7 (pipeline wiring; delete `render_sentiment_section`; `markdown_profile` kept for postprocess) → Tasks 4 + 5. ✓
- §9 (graceful degradation: no key/error → fallback) → Tasks 3 (fallback) + 5 (offline smoke) + 6. ✓
- §10 (tests) → Tasks 1-5 test files + Task 6 full suite. ✓
- §11 (out of scope: no Swift, no two-tier, no hierarchical summarization) → respected; none added. ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to" — every code step shows complete code. ✓

**Type consistency:** `analyze_insights(segments, *, recording_type, sentiment=None, emotion=None)` is called with exactly those kwargs in Task 5. `render_note(recording_type, insights, sentiment, speakers, segments)` signature matches its calls in Tasks 4 + 5. `Insights` field names (`dynamics`, `opportunities`, `recommended_actions`, `action_items`, `key_points`, `reflections`, `outline`, `key_concepts`, `qa`, `takeaways`, `title`, `summary`) are identical across Tasks 2, 3, 4. `_build_speakers(segments, emotion)` defined and used consistently in Task 5. `resolve_llm_env()/warn()/transcript_text()` signatures match across Tasks 1, 3 and the markdown/sentiment refactors. ✓
