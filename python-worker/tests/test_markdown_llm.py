from unittest.mock import MagicMock, patch

from app.postprocess.markdown import generate_markdown
from app.schemas.models import TranscriptSegment


def _segments():
    return [TranscriptSegment(start=0.0, end=2.0, text="Hello there", speaker=None)]


def test_uses_llm_when_cloud_key_present(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_MODEL", "google/gemini-2.5-flash")
    monkeypatch.setenv("LLM_API_KEY", "key")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "T", "summary": "S", "key_points": ["k"],
        "decisions": [], "action_items": [],
    }
    with patch("app.postprocess.markdown.LLMClient", return_value=fake):
        note = generate_markdown(_segments())
    assert note.title == "T"
    fake.complete_json.assert_called_once()


def test_uses_llm_for_local_without_key(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://localhost:11434/v1")
    monkeypatch.setenv("LLM_MODEL", "qwen2.5:32b")
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "L", "summary": "S", "key_points": [],
        "decisions": [], "action_items": [],
    }
    with patch("app.postprocess.markdown.LLMClient", return_value=fake):
        note = generate_markdown(_segments())
    assert note.title == "L"


def test_falls_back_when_cloud_and_no_key(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    note = generate_markdown(_segments())
    assert note.title  # fallback still produces a note
