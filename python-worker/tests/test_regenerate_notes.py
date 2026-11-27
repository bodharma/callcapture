"""`regenerate_notes`: AI notes from the saved transcript, with no transcription.

Synthetic transcripts only. Every transcription entry point is wired to fail, so a
test passes only if the job never transcribes.
"""
import json
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from app import cli
from app.analyze import insights as insights_mod
from app.analyze import sentiment as sentiment_mod
from app.postprocess import llm_client
from app.postprocess.llm_client import LLMError, LLMTruncatedError
from app.schemas.models import Insights, JobRequest

SAVED = [
    {"start": 0.0, "end": 2.0, "text": "Shall we ship on Friday?", "speaker": "You"},
    {"start": 2.0, "end": 5.0, "text": "Yes, if staging is green.", "speaker": "Speaker 1"},
    {"start": 5.0, "end": 5.5, "text": "Ambient noise", "speaker": None},
]


def _never(*_args, **_kwargs):
    raise AssertionError("regenerate_notes must not transcribe")


@pytest.fixture
def no_transcription():
    with patch("app.cli._transcribe_and_attribute", side_effect=_never), \
         patch("app.cli.transcribe", side_effect=_never), \
         patch("app.cli.transcribe_path", side_effect=_never), \
         patch("app.cli._count_stems", side_effect=_never), \
         patch("app.cli.is_emotion_model_ready", return_value=False):
        yield


@pytest.fixture
def no_llm(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.delenv("LLM_OFFLINE", raising=False)


def _session(tmp_path, segments=SAVED):
    audio = tmp_path / "S1.wav"
    audio.write_bytes(b"")
    transcript = tmp_path / "S1_transcript.json"
    transcript.write_text(json.dumps(segments, ensure_ascii=False, indent=2), encoding="utf-8")
    return audio, transcript


def _request(audio, transcript, **kw):
    fields = dict(job_id="S1", command="regenerate_notes", audio_path=str(audio),
                  transcript_path=None if transcript is None else str(transcript))
    fields.update(kw)
    return JobRequest(**fields)


def test_notes_and_analysis_come_from_the_saved_transcript(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)
    before = transcript.read_bytes()
    insights = Insights(title="Release", summary="Ship on Friday if staging is green.",
                        takeaways=["Check staging"])
    with patch("app.cli.analyze_insights", return_value=insights) as analyze:
        result = cli._run_regenerate_notes(_request(audio, transcript, recording_type="lecture",
                                                    notes_language="uk"))

    assert result.status == "completed", result.error_message
    assert analyze.call_args.kwargs["recording_type"] == "lecture"
    assert analyze.call_args.kwargs["notes_language"] == "uk"
    assert [s.speaker for s in analyze.call_args.args[0]] == ["You", "Speaker 1", None]

    assert result.markdown_path == str(tmp_path / "S1_notes.md")
    assert result.analysis_path == str(tmp_path / "S1_analysis.json")
    notes = (tmp_path / "S1_notes.md").read_text(encoding="utf-8")
    assert "# Release" in notes
    assert "## Takeaways" in notes  # the lecture note shape: the session's current type
    assert "- Check staging" in notes
    analysis = json.loads((tmp_path / "S1_analysis.json").read_text(encoding="utf-8"))
    assert analysis["insights"]["title"] == "Release"
    assert analysis["recording_type"] == "lecture"
    # A row without a speaker counts as the default remote speaker, as in the pipeline.
    assert [s["label"] for s in analysis["speakers"]] == ["You", "Speaker 1"]

    # The transcript, and so its speaker labels (and the user's names for them), is untouched.
    assert transcript.read_bytes() == before
    assert result.raw_transcript_path == str(transcript)
    assert result.duration_sec == 5.5


def test_only_the_processing_cost_is_reported(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)

    def costly(*_args, **_kwargs):
        llm_client.record_usage(tokens=1200, cost=0.0042)
        return Insights(title="Release", summary="s")

    with patch("app.cli.analyze_insights", side_effect=costly):
        result = cli._run_regenerate_notes(_request(audio, transcript, llm_engine="claude"))

    assert result.status == "completed"
    assert result.cost_transcription is None
    assert result.audio_minutes is None
    assert result.cost_processing == 0.0042
    assert result.llm_tokens == 1200
    assert result.cost_currency == "USD"


class _FailingClient:
    def __init__(self, *args, **kwargs):
        pass

    def complete_json(self, **kwargs):
        raise LLMError("HTTP 404: model not found")


class _CutOffClient(_FailingClient):
    def complete_json(self, **kwargs):
        raise LLMTruncatedError()


@pytest.fixture
def cloud_env(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.delenv("LLM_OFFLINE", raising=False)


def _earlier_notes(tmp_path):
    notes = tmp_path / "S1_notes.md"
    notes.write_text("# Release\n\nGood AI notes from an earlier run.\n", encoding="utf-8")
    analysis = tmp_path / "S1_analysis.json"
    analysis.write_text('{"insights": {"title": "Release"}}', encoding="utf-8")
    return notes, analysis, notes.read_bytes(), analysis.read_bytes()


EARLIER_SENTIMENT = {
    "overall": "positive", "overall_score": 0.6,
    "by_speaker": {"You": {"label": "positive", "score": 0.7}, "Speaker 1": {"label": "mixed", "score": 0.1}},
    "arc": [{"t": 10.0, "score": 0.2}, {"t": 30.0, "score": 0.4}],
}


def _earlier_analysis(tmp_path, sentiment):
    (tmp_path / "S1_analysis.json").write_text(
        json.dumps({"recording_type": "call_meeting", "insights": {"title": "Old"}, "sentiment": sentiment}),
        encoding="utf-8")


def _regenerate_with_failing_sentiment(tmp_path, audio, transcript):
    with patch.object(sentiment_mod, "LLMClient", _FailingClient), \
         patch("app.cli.analyze_insights", return_value=Insights(title="New release", summary="s")) as analyze:
        result = cli._run_regenerate_notes(_request(audio, transcript))
    analysis = json.loads((tmp_path / "S1_analysis.json").read_text(encoding="utf-8"))
    notes = (tmp_path / "S1_notes.md").read_text(encoding="utf-8")
    return result, analysis, notes, analyze


def test_a_sentiment_failure_keeps_the_earlier_sentiment(tmp_path, no_transcription, cloud_env):
    audio, transcript = _session(tmp_path)
    _earlier_analysis(tmp_path, EARLIER_SENTIMENT)

    result, analysis, notes, analyze = _regenerate_with_failing_sentiment(tmp_path, audio, transcript)

    assert result.status == "completed"
    assert result.notes_kept is False
    assert result.warnings == ["AI sentiment failed (HTTP 404: model not found); the earlier sentiment was kept."]
    assert analysis["insights"]["title"] == "New release"
    assert analysis["sentiment"] == EARLIER_SENTIMENT
    assert "# New release" in notes
    assert "**Overall:** positive (+0.60)" in notes
    assert "- **Speaker 1:** mixed (+0.10)" in notes
    # The new insights were written with the earlier sentiment as their context.
    assert analyze.call_args.kwargs["sentiment"].overall == "positive"


FALLBACK_SENTIMENT = {
    "overall": "neutral", "overall_score": 0.0, "arc": [{"t": 10.0, "score": 0.2}],
    "by_speaker": {"You": {"label": "neutral", "score": 0.0}, "Speaker 1": {"label": "neutral", "score": 0.0}},
}


@pytest.mark.parametrize("earlier", ["no analysis", "garbled", "no sentiment", "fallback sentiment"])
def test_a_sentiment_failure_without_earlier_ai_sentiment_falls_back_to_neutral(
    tmp_path, no_transcription, cloud_env, earlier
):
    audio, transcript = _session(tmp_path)
    if earlier == "garbled":
        (tmp_path / "S1_analysis.json").write_text("{garbled", encoding="utf-8")
    elif earlier == "no sentiment":
        _earlier_analysis(tmp_path, None)
    elif earlier == "fallback sentiment":
        _earlier_analysis(tmp_path, FALLBACK_SENTIMENT)

    result, analysis, notes, _ = _regenerate_with_failing_sentiment(tmp_path, audio, transcript)

    assert result.notes_kept is False
    assert result.warnings == ["AI sentiment failed (HTTP 404: model not found); neutral sentiment was used."]
    assert analysis["insights"]["title"] == "New release"
    assert analysis["sentiment"]["overall"] == "neutral"
    assert analysis["sentiment"]["overall_score"] == 0.0
    assert analysis["sentiment"]["arc"] == []
    assert "**Overall:** neutral (+0.00)" in notes


def test_transcription_never_carries_sentiment_over(tmp_path, cloud_env):
    audio, transcript = _session(tmp_path)
    _earlier_analysis(tmp_path, EARLIER_SENTIMENT)
    segments = cli._load_saved_transcript(str(transcript))
    with patch.object(sentiment_mod, "LLMClient", _FailingClient), \
         patch("app.cli.analyze_insights", return_value=Insights(title="New release", summary="s")), \
         patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch("app.cli._transcribe_and_attribute", return_value=segments), \
         patch("app.cli._count_stems", return_value=1):
        result = cli._run_pipeline(JobRequest(job_id="S1", command="transcribe", audio_path=str(audio)))

    analysis = json.loads((tmp_path / "S1_analysis.json").read_text(encoding="utf-8"))
    assert analysis["sentiment"]["overall"] == "neutral"
    assert result.warnings == ["AI sentiment failed (HTTP 404: model not found); neutral sentiment was used."]


@pytest.mark.parametrize("client, reason", [
    (_FailingClient, "HTTP 404: model not found"),
    (_CutOffClient, "the reply was cut off"),
])
def test_an_ai_failure_keeps_the_previous_notes(tmp_path, no_transcription, cloud_env, client, reason):
    audio, transcript = _session(tmp_path)
    notes, analysis, notes_before, analysis_before = _earlier_notes(tmp_path)
    with patch.object(insights_mod, "LLMClient", client), patch.object(sentiment_mod, "LLMClient", client):
        result = cli._run_regenerate_notes(_request(audio, transcript))

    assert result.status == "completed"
    assert result.notes_kept is True
    assert result.markdown_path is None
    assert result.analysis_path is None
    assert result.warnings == [f"Regenerating AI notes failed ({reason}); the previous notes were kept."]
    assert notes.read_bytes() == notes_before
    assert analysis.read_bytes() == analysis_before


def test_without_a_key_the_previous_notes_are_kept(tmp_path, no_transcription, monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_API_KEY", "")
    monkeypatch.delenv("LLM_OFFLINE", raising=False)
    audio, transcript = _session(tmp_path)
    notes, analysis, notes_before, analysis_before = _earlier_notes(tmp_path)

    result = cli._run_regenerate_notes(_request(audio, transcript))

    assert result.notes_kept is True
    assert result.warnings == ["Regenerating AI notes failed (no LLM API key); the previous notes were kept."]
    assert notes.read_bytes() == notes_before
    assert analysis.read_bytes() == analysis_before


def test_transcription_still_writes_rule_based_notes_when_the_ai_fails(tmp_path, cloud_env):
    audio, transcript = _session(tmp_path)
    segments = cli._load_saved_transcript(str(transcript))
    with patch.object(insights_mod, "LLMClient", _FailingClient), \
         patch.object(sentiment_mod, "LLMClient", _FailingClient), \
         patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch("app.cli._transcribe_and_attribute", return_value=segments), \
         patch("app.cli._count_stems", return_value=1):
        result = cli._run_pipeline(JobRequest(job_id="S1", command="transcribe", audio_path=str(audio)))

    assert result.status == "completed"
    assert result.notes_kept is False
    assert result.markdown_path == str(tmp_path / "S1_notes.md")
    assert "AI notes failed (HTTP 404: model not found); rule-based notes were used." in result.warnings
    assert (tmp_path / "S1_notes.md").read_text(encoding="utf-8").startswith("# ")


def test_the_shared_step_reports_whether_the_ai_wrote_the_notes(tmp_path, cloud_env):
    audio, transcript = _session(tmp_path)
    segments = cli._load_saved_transcript(str(transcript))
    request = _request(audio, transcript)
    with patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch.object(sentiment_mod, "LLMClient", _FailingClient):
        with patch.object(insights_mod, "LLMClient", _FailingClient):
            fell_back = cli._analyze_and_write_notes(request, segments, [])
        with patch("app.cli.analyze_insights", return_value=Insights(title="Release", summary="s")):
            wrote = cli._analyze_and_write_notes(request, segments, [])

    assert fell_back.ai_fallback == "HTTP 404: model not found"
    assert fell_back.markdown_path == str(tmp_path / "S1_notes.md")  # transcribe keeps writing
    assert wrote.ai_fallback is None


def test_both_commands_share_one_post_transcription_step(tmp_path, no_llm):
    audio, transcript = _session(tmp_path)
    shared = cli._analyze_and_write_notes
    with patch("app.cli._analyze_and_write_notes", side_effect=shared) as step, \
         patch("app.cli.is_emotion_model_ready", return_value=False), \
         patch("app.cli._transcribe_and_attribute", return_value=cli._load_saved_transcript(str(transcript))), \
         patch("app.cli._count_stems", return_value=1):
        cli._run_regenerate_notes(_request(audio, transcript))
        cli._run_pipeline(JobRequest(job_id="S1", command="transcribe", audio_path=str(audio)))
    assert step.call_count == 2


@pytest.mark.parametrize("problem, content", [
    ("missing", None),
    ("empty", "[]"),
    ("garbled", "{not json"),
    ("wrong shape", '{"start": 0}'),
])
def test_an_unusable_transcript_fails_with_a_sentence(tmp_path, no_transcription, no_llm, problem, content):
    audio = tmp_path / "S1.wav"
    audio.write_bytes(b"")
    transcript = tmp_path / "S1_transcript.json"
    if content is not None:
        transcript.write_text(content, encoding="utf-8")

    result = cli._run_regenerate_notes(_request(audio, transcript))

    assert result.status == "failed", problem
    assert result.error_message and result.error_message.endswith("."), problem
    assert "Process the recording again" in result.error_message, problem
    assert not (tmp_path / "S1_notes.md").exists()


def test_a_request_without_a_transcript_path_fails_with_a_sentence(tmp_path, no_transcription, no_llm):
    audio = tmp_path / "S1.wav"
    audio.write_bytes(b"")

    result = cli._run_regenerate_notes(_request(audio, None))

    assert result.status == "failed"
    assert result.error_message == "No saved transcript was given, so there is nothing to make notes from."


def test_the_cli_command_reads_the_request_and_prints_the_result(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)
    payload = _request(audio, transcript).model_dump_json()

    with patch("app.cli.analyze_insights", return_value=Insights(title="Release", summary="s")):
        run = CliRunner().invoke(cli.cli, ["regenerate_notes"], input=payload)

    assert run.exit_code == 0, run.output
    result = json.loads(run.stdout.strip().splitlines()[-1])
    assert result["status"] == "completed"
    assert result["markdown_path"] == str(tmp_path / "S1_notes.md")


def test_the_cli_command_accepts_the_swift_request_shape(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)
    # What `JobRequest.regenerateNotes(session:settings:)` encodes.
    payload = json.dumps({
        "job_id": "S1", "command": "regenerate_notes", "audio_path": str(audio),
        "engine": "remote", "language": "uk", "markdown_profile": "meeting_notes",
        "whisper_model": "base", "llm_engine": "claude", "remote_provider": "assemblyai",
        "recording_type": "call_meeting", "notes_language": "uk", "stt_rates_per_min": {},
        "llm_fallback_rate_per_1m": 3.0, "transcript_path": str(transcript),
    })

    run = CliRunner().invoke(cli.cli, ["regenerate_notes"], input=payload)

    assert run.exit_code == 0, run.output
    assert json.loads(run.stdout.strip().splitlines()[-1])["status"] == "completed"


def test_a_render_failure_leaves_the_earlier_analysis_and_notes_untouched(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)
    _earlier_analysis(tmp_path, EARLIER_SENTIMENT)
    (tmp_path / "S1_notes.md").write_text("# Old notes\n", encoding="utf-8")
    analysis_before = (tmp_path / "S1_analysis.json").read_bytes()
    notes_before = (tmp_path / "S1_notes.md").read_bytes()

    with patch("app.cli.analyze_insights", return_value=Insights(title="New", summary="s")), \
         patch("app.cli.render_note", side_effect=RuntimeError("render broke")):
        with pytest.raises(RuntimeError):
            cli._run_regenerate_notes(_request(audio, transcript))

    assert (tmp_path / "S1_analysis.json").read_bytes() == analysis_before
    assert (tmp_path / "S1_notes.md").read_bytes() == notes_before


def test_regenerate_reports_progress_through_the_ai_step(tmp_path, no_transcription, no_llm):
    audio, transcript = _session(tmp_path)
    ticks = []
    with patch("app.cli.analyze_insights", return_value=Insights(title="T", summary="s")), \
         patch("app.cli.report_progress", side_effect=lambda _id, p, stage: ticks.append((p, stage))):
        cli._run_regenerate_notes(_request(audio, transcript))

    assert ticks == [
        (0.0, "loading transcript"),
        (0.15, "analysing sentiment"),
        (0.35, "writing notes"),
        (0.5, "postprocessing"),
        (0.8, "exporting"),
        (1.0, "done"),
    ]
