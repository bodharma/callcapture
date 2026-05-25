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
