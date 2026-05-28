"""Tests for the notes-language directive that forces the LLM output language.

`language_directive` is a pure helper; the three analyzers (markdown, sentiment,
insights) MUST prepend it to their system prompt when `notes_language` is set
to anything other than "auto".
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from app.analyze.insights import analyze_insights
from app.analyze.sentiment import analyze_sentiment
from app.postprocess.llm_env import language_directive
from app.postprocess.markdown import generate_markdown
from app.schemas.models import TranscriptSegment


def _segs():
    return [TranscriptSegment(start=0.0, end=1.0, text="hello", speaker="You")]


# ---- pure helper ---------------------------------------------------------


def test_directive_empty_for_auto():
    assert language_directive("auto") == ""
    assert language_directive("") == ""
    assert language_directive(None) == ""


def test_directive_uses_human_name_for_known_code():
    out = language_directive("uk")
    assert "Ukrainian" in out
    assert out.endswith("\n\n")


def test_directive_falls_back_to_code_for_unknown():
    out = language_directive("xx")
    assert "xx" in out


# ---- injected into analyzers ---------------------------------------------


def _set_cloud_key(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")


def test_sentiment_prepends_directive(monkeypatch):
    _set_cloud_key(monkeypatch)
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "neutral", "overall_score": 0.0, "by_speaker": {},
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        analyze_sentiment(_segs(), notes_language="uk")
    system = fake.complete_json.call_args.kwargs["system"]
    assert system.startswith("Respond ENTIRELY in Ukrainian.")


def test_insights_prepends_directive(monkeypatch):
    _set_cloud_key(monkeypatch)
    fake = MagicMock()
    fake.complete_json.return_value = {"title": "t", "summary": "s"}
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        analyze_insights(_segs(), recording_type="call_meeting", notes_language="ru")
    system = fake.complete_json.call_args.kwargs["system"]
    assert system.startswith("Respond ENTIRELY in Russian.")


def test_markdown_prepends_directive(monkeypatch):
    _set_cloud_key(monkeypatch)
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "t", "summary": "s",
        "key_points": [], "decisions": [], "action_items": [],
    }
    with patch("app.postprocess.markdown.LLMClient", return_value=fake):
        generate_markdown(_segs(), notes_language="es")
    system = fake.complete_json.call_args.kwargs["system"]
    assert system.startswith("Respond ENTIRELY in Spanish.")


def test_auto_does_not_prepend(monkeypatch):
    """`auto` must leave the system prompt unchanged."""
    _set_cloud_key(monkeypatch)
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "neutral", "overall_score": 0.0, "by_speaker": {},
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        analyze_sentiment(_segs(), notes_language="auto")
    system = fake.complete_json.call_args.kwargs["system"]
    assert not system.startswith("Respond ENTIRELY")
