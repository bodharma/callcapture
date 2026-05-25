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
