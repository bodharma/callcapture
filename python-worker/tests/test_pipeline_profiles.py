"""A selected export profile changes the real pipeline output without new LLM calls."""
from pathlib import Path
from unittest.mock import patch

import pytest

from app import cli
from app.schemas.models import Insights, JobRequest, TranscriptSegment


@pytest.mark.parametrize("kind,heading", [("call_meeting", "## Conversation Insights"),
    ("voice_memo", "## Reflections"), ("lecture", "## Key Concepts")])
def test_pipeline_honors_profiles_and_preserves_type_insights(tmp_path, kind, heading):
    segments = [TranscriptSegment(start=0, end=1, text="First unique source turn", speaker="You"),
                TranscriptSegment(start=2, end=3, text="Last unique source turn", speaker="Speaker A")]
    insights = Insights(title="Synthetic discussion", summary="A summary", dynamics="A useful exchange",
                        reflections=["Reflect"], key_concepts=["Concept"])
    rendered = {}
    with patch("app.cli._transcribe_and_attribute", return_value=segments), \
         patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch("app.cli.analyze_sentiment", return_value=None), \
         patch("app.cli.analyze_insights", return_value=insights) as analyze:
        for profile in ("meeting_notes", "full_transcript", "obsidian"):
            audio = tmp_path / f"{profile}.wav"
            request = JobRequest(job_id=profile, command="transcribe", audio_path=str(audio),
                                 recording_type=kind, markdown_profile=profile)
            result = cli._run_pipeline(request)
            assert result.status == "completed"
            rendered[profile] = Path(result.markdown_path).read_text()
        assert analyze.call_count == 3
    assert len(set(rendered.values())) == 3
    assert all(heading in output for output in rendered.values())
    assert not rendered["meeting_notes"].startswith("---\n")
    assert rendered["obsidian"].startswith("---\n")
    assert "## Full Transcript" in rendered["full_transcript"]
    for segment in segments:
        assert segment.text not in rendered["meeting_notes"]
        assert segment.text in rendered["full_transcript"]
        if kind == "call_meeting":
            assert segment.text in rendered["obsidian"]
        assert f"[{segment.start:.1f}s - {segment.end:.1f}s]" in rendered["full_transcript"]
