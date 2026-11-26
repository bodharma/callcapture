"""AI-notes fallbacks are reported as job warnings instead of silently degrading notes."""
from unittest.mock import patch

import pytest

from app import cli
from app.analyze import insights as insights_mod
from app.analyze import sentiment as sentiment_mod
from app.postprocess.llm_client import LLMError
from app.schemas.models import JobRequest, TranscriptSegment

OFFLINE = "AI notes and sentiment skipped: offline. Re-process when online to generate them."


def _segments():
    return [TranscriptSegment(start=0, end=2, text="Ship on Friday", speaker="You"),
            TranscriptSegment(start=2, end=4, text="Agreed", speaker="Speaker 1")]


class _FailingClient:
    def __init__(self, *args, **kwargs):
        pass

    def complete_json(self, **kwargs):
        raise LLMError("HTTP 404: model not found")


@pytest.fixture
def cloud_env(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.delenv("LLM_OFFLINE", raising=False)


def test_offline_skips_the_llm_and_says_so(cloud_env, monkeypatch):
    monkeypatch.setenv("LLM_OFFLINE", "1")
    warnings: list[str] = []
    with patch.object(insights_mod, "LLMClient", side_effect=AssertionError("LLM called offline")), \
         patch.object(sentiment_mod, "LLMClient", side_effect=AssertionError("LLM called offline")):
        result = insights_mod.analyze_insights(_segments(), recording_type="call_meeting", warnings=warnings)
        sentiment = sentiment_mod.analyze_sentiment(_segments(), warnings=warnings)
    assert result is not None and sentiment is not None
    assert warnings == [OFFLINE]


def test_llm_failure_names_the_reason(cloud_env):
    warnings: list[str] = []
    with patch.object(insights_mod, "LLMClient", _FailingClient), \
         patch.object(sentiment_mod, "LLMClient", _FailingClient):
        insights_mod.analyze_insights(_segments(), recording_type="call_meeting", warnings=warnings)
        sentiment_mod.analyze_sentiment(_segments(), warnings=warnings)
    assert warnings[0].startswith("AI notes failed (") and "HTTP 404" in warnings[0]
    assert warnings[0].endswith("rule-based notes were used.")
    assert warnings[1].startswith("AI sentiment failed (") and "HTTP 404" in warnings[1]
    assert warnings[1].endswith("neutral sentiment was used.")


def test_missing_cloud_key_is_reported(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_API_KEY", "")
    monkeypatch.delenv("LLM_OFFLINE", raising=False)
    warnings: list[str] = []
    insights_mod.analyze_insights(_segments(), recording_type="call_meeting", warnings=warnings)
    sentiment_mod.analyze_sentiment(_segments(), warnings=warnings)
    assert warnings == ["AI notes need an LLM API key; rule-based notes were used.",
                        "AI sentiment needs an LLM API key; neutral sentiment was used."]


def test_warnings_param_is_optional(cloud_env):
    with patch.object(insights_mod, "LLMClient", _FailingClient):
        assert insights_mod.analyze_insights(_segments(), recording_type="call_meeting") is not None


def test_pipeline_completes_and_returns_the_warnings(cloud_env, monkeypatch, tmp_path):
    monkeypatch.setenv("LLM_OFFLINE", "1")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(tmp_path / "rec.wav"))
    with patch("app.cli._transcribe_and_attribute", return_value=_segments()), \
         patch("app.cli.is_emotion_model_ready", return_value=False):
        result = cli._run_pipeline(request)
    assert result.status == "completed"
    assert OFFLINE in result.warnings
