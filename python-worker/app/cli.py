"""Click CLI entry point for the callcapture worker."""

from __future__ import annotations

import json
import os
import signal
import sys
import wave
from collections.abc import Callable
from functools import lru_cache
from typing import Any

import click

from app.analyze.attribution import attribute_segments
from app.analyze.diarization import load_diarization_turns
from app.analyze.emotion import SpeakerEmotion, compute_arc, compute_speaker_emotion, is_emotion_model_ready, prepare_emotion_model
from app.analyze.insights import analyze_insights
from app.analyze.metrics import compute_speaker_stats
from app.analyze.sentiment import analyze_sentiment
from app.export.writer import write_markdown, write_raw_transcript
from app.postprocess import pricing
from app.postprocess.formatter import render_markdown, render_note
from app.postprocess.llm_client import get_usage, reset_usage
from app.postprocess.markdown import generate_markdown
from app.schemas.models import (
    ConversationAnalysis,
    Insights,
    JobRequest,
    JobResult,
    Sentiment,
    SpeakerStats,
    TranscriptSegment,
)
from app.transcribe.engine import transcribe, transcribe_path
from app.utils.progress import report_progress, report_result

_shutdown_requested = False


def _handle_sigterm(_signum: int, _frame: Any) -> None:
    global _shutdown_requested
    _shutdown_requested = True
    sys.stderr.write('{"signal": "SIGTERM received, shutting down"}\n')
    sys.stderr.flush()


signal.signal(signal.SIGTERM, _handle_sigterm)


def _check_ping(raw: str) -> bool:
    """Check for ping/pong heartbeat, respond if detected."""
    try:
        data = json.loads(raw)
        if data.get("action") == "ping":
            sys.stderr.write(json.dumps({"pong": True}) + "\n")
            sys.stderr.flush()
            return True
    except (json.JSONDecodeError, AttributeError):
        pass
    return False


# ponytail: catches digital silence only (e.g. the system tap while nothing plays,
# or a capture that wrote no frames). A quiet-room mic still goes to the provider.
_SILENCE_PEAK = 4  # int16 units, about -78 dBFS
_NO_AUDIO = (
    "The recording contains no audio (microphone and system audio are silent). "
    "Check CallCapture's Microphone and System Audio Recording permissions in "
    "System Settings > Privacy & Security, then record again."
)


@lru_cache(maxsize=None)  # the worker handles one job per process
def _is_silent(path: str) -> bool:
    """True only for a readable 16-bit WAV that never rises above the silence floor."""
    import numpy as np

    try:
        with wave.open(path) as w:
            if w.getsampwidth() != 2:
                return False
            while chunk := w.readframes(1 << 16):
                if np.abs(np.frombuffer(chunk, dtype=np.int16).astype(np.int32)).max() > _SILENCE_PEAK:
                    return False
    except (wave.Error, OSError, EOFError):
        return False  # unknown is not silent: let the engine report a real error
    return True


def _transcribe_and_attribute(request: JobRequest) -> list[TranscriptSegment]:
    """Transcribe stems when present (mic = You, system = remote, attributed by
    the diarization sidecar), else transcribe the single mixed file as remote.
    Digitally silent stems are skipped: a provider rejects them ("no spoken
    audio"), which used to fail the job and discard the other stem's speech."""
    base = os.path.splitext(request.audio_path)[0]
    mic_path = f"{base}_mic.wav"
    system_path = f"{base}_system.wav"

    if os.path.exists(mic_path) and os.path.exists(system_path):
        mic_silent, system_silent = _is_silent(mic_path), _is_silent(system_path)
        if mic_silent and system_silent:
            raise RuntimeError(_NO_AUDIO)
        mic_segments = [] if mic_silent else transcribe_path(mic_path, request)
        system_segments = [] if system_silent else transcribe_path(system_path, request)
        turns = load_diarization_turns(system_path)
        return attribute_segments(mic_segments, system_segments, turns, self_label="You")

    # No stems: transcribe the mixed/single file.
    if _is_silent(request.audio_path):
        raise RuntimeError(_NO_AUDIO)
    segments = transcribe(request)
    if request.recording_type == "voice_memo":
        # A solo memo is the user speaking.
        return attribute_segments(segments, [], None, self_label="You")
    turns = load_diarization_turns(request.audio_path)
    return attribute_segments([], segments, turns, self_label="You")


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
    speakers: list[SpeakerStats] | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path.

    `speakers` may be passed in to avoid recomputing talk metrics when the caller
    already built them (e.g. for note rendering); otherwise they are derived here.
    """
    if speakers is None:
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


def _count_stems(audio_path: str) -> int:
    """Number of files actually sent for transcription: each non-silent stem when
    mic+system stems exist, else the single file."""
    base = os.path.splitext(audio_path)[0]
    stems = [f"{base}_mic.wav", f"{base}_system.wav"]
    if not all(os.path.exists(p) for p in stems):
        return 1
    return max(1, sum(not _is_silent(p) for p in stems))


def _processing_costs(request: JobRequest) -> dict:
    """USD cost of this job's LLM calls (free for a local engine), plus the tokens used."""
    usage = get_usage()
    if request.llm_engine.startswith("local"):
        cost_p = 0.0
    else:
        fallback = request.llm_fallback_rate_per_1m
        if fallback is None:
            fallback = pricing.DEFAULT_LLM_FALLBACK_RATE_PER_1M
        cost_p = pricing.processing_cost(usage.actual_cost, usage.total_tokens, fallback)
    return {
        "cost_processing": round(cost_p, 6),
        "cost_currency": "USD",
        "llm_tokens": usage.total_tokens,
    }


def _compute_costs(request: JobRequest, duration_sec: float | None) -> dict:
    """USD cost breakdown for this job, plus raw usage for later recompute."""
    minutes = (duration_sec or 0.0) / 60.0
    provider = request.remote_provider if request.engine == "remote" else "local_whisper"
    rates = pricing.merge_rates(request.stt_rates_per_min)
    cost_t = pricing.transcription_cost(
        minutes, provider, _count_stems(request.audio_path), rates
    )
    return {
        "cost_transcription": round(cost_t, 6),
        "audio_minutes": round(minutes, 4),
        **_processing_costs(request),
    }


_TRANSCRIBE_AGAIN = "Use Re-process to transcribe the recording again."


class SavedTranscriptError(ValueError):
    """The saved transcript can't be used; the message is a sentence for the user."""


def _load_saved_transcript(path: str) -> list[TranscriptSegment]:
    """Segments as the pipeline saved them: already speaker-attributed, start-ordered."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            raise ValueError("the transcript is not a list of segments")
        segments = [TranscriptSegment.model_validate(item) for item in data]
    except FileNotFoundError as exc:
        raise SavedTranscriptError(
            f"The saved transcript is missing. {_TRANSCRIBE_AGAIN}"
        ) from exc
    except (OSError, ValueError) as exc:  # JSON and validation errors are ValueErrors
        raise SavedTranscriptError(
            f"The saved transcript couldn't be read. {_TRANSCRIBE_AGAIN}"
        ) from exc
    if not segments:
        raise SavedTranscriptError(
            f"The saved transcript is empty, so there is nothing to make notes from. {_TRANSCRIBE_AGAIN}"
        )
    return segments


def _failed(request: JobRequest, message: str, warnings: list[str]) -> JobResult:
    return JobResult(job_id=request.job_id, status="failed", error_message=message, warnings=warnings)


def _run_pipeline(request: JobRequest) -> JobResult:
    """Execute the full transcribe -> postprocess -> export pipeline."""
    warnings: list[str] = []

    reset_usage()

    report_progress(request.job_id, 0.0, "starting")

    segments = _transcribe_and_attribute(request)
    if not segments:
        return _failed(
            request,
            "No speech was detected in the recording, so no transcript was produced.",
            warnings,
        )

    analysis_path, md_path = _analyze_and_write_notes(request, segments, warnings)

    base_dir = os.path.dirname(request.audio_path)
    base_name = os.path.splitext(os.path.basename(request.audio_path))[0]
    raw_path = os.path.join(base_dir, f"{base_name}_transcript.json")
    write_raw_transcript(segments, raw_path)

    duration_sec = segments[-1].end

    report_progress(request.job_id, 1.0, "done")

    costs = _compute_costs(request, duration_sec)
    return JobResult(
        job_id=request.job_id,
        status="completed",
        raw_transcript_path=raw_path,
        markdown_path=md_path,
        analysis_path=analysis_path,
        duration_sec=duration_sec,
        warnings=warnings,
        **costs,
    )


def _run_regenerate_notes(request: JobRequest) -> JobResult:
    """Rebuild the AI notes and the analysis from the session's saved transcript.

    No audio is transcribed or uploaded, so only the processing cost is reported, and
    the transcript file is never rewritten: its speaker labels, which the app's speaker
    names are keyed by, stay as they were.
    """
    warnings: list[str] = []

    reset_usage()

    report_progress(request.job_id, 0.0, "loading transcript")

    if not request.transcript_path:
        return _failed(
            request, "No saved transcript was given, so there is nothing to make notes from.", warnings
        )
    try:
        segments = _load_saved_transcript(request.transcript_path)
    except SavedTranscriptError as exc:
        return _failed(request, str(exc), warnings)

    analysis_path, md_path = _analyze_and_write_notes(request, segments, warnings)

    report_progress(request.job_id, 1.0, "done")

    return JobResult(
        job_id=request.job_id,
        status="completed",
        raw_transcript_path=request.transcript_path,
        markdown_path=md_path,
        analysis_path=analysis_path,
        duration_sec=segments[-1].end,
        warnings=warnings,
        **_processing_costs(request),
    )


def _analyze_and_write_notes(
    request: JobRequest, segments: list[TranscriptSegment], warnings: list[str]
) -> tuple[str, str]:
    """The post-transcription half that `transcribe` and `regenerate_notes` share, so
    their notes can't drift apart: acoustic emotion (when the model is ready), sentiment,
    insights, speaker metrics, `<base>_analysis.json` and `<base>_notes.md`.

    Appends the AI notes fallbacks to `warnings`; returns (analysis path, note path).
    """
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
    sentiment = analyze_sentiment(
        segments,
        emotion=emotion_summary or None,
        notes_language=request.notes_language,
        warnings=warnings,
    )
    if sentiment is not None and arc:
        sentiment = sentiment.model_copy(update={"arc": arc})

    insights = analyze_insights(
        segments,
        recording_type=request.recording_type,
        sentiment=sentiment,
        emotion=emotion_summary or None,
        notes_language=request.notes_language,
        warnings=warnings,
    )
    speakers = _build_speakers(segments, emotion)
    analysis_path = _write_analysis(
        request, segments, sentiment, emotion, insights, speakers=speakers
    )

    report_progress(request.job_id, 0.5, "postprocessing")

    rendered = render_note(request.recording_type, insights, sentiment, speakers, segments,
                           profile=request.markdown_profile)

    report_progress(request.job_id, 0.8, "exporting")

    base_dir = os.path.dirname(request.audio_path)
    base_name = os.path.splitext(os.path.basename(request.audio_path))[0]
    md_path = os.path.join(base_dir, f"{base_name}_notes.md")
    write_markdown(rendered, md_path)

    return analysis_path, md_path


@click.group()
@click.version_option(version="0.1.0", prog_name="call-capture-worker")
def cli() -> None:
    """CallCapture Python worker CLI."""


def main() -> None:
    """Entry point that disables Click's standalone mode to preserve stdout."""
    sys.exit(cli(standalone_mode=False))


@cli.command()
@click.pass_context
def transcribe_cmd(ctx: click.Context) -> None:
    """Read a JobRequest from stdin and run the full pipeline."""
    _run_job_from_stdin(ctx, _run_pipeline)


@cli.command(name="regenerate_notes")
@click.pass_context
def regenerate_notes_cmd(ctx: click.Context) -> None:
    """Read a JobRequest from stdin and rebuild the AI notes from its saved transcript."""
    _run_job_from_stdin(ctx, _run_regenerate_notes)


def _run_job_from_stdin(ctx: click.Context, run: Callable[[JobRequest], JobResult]) -> None:
    """One JobRequest on stdin, progress on stderr, one JobResult on stdout."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw:
        sys.stderr.write('{"error": "empty stdin"}\n')
        sys.stderr.flush()
        ctx.exit(1)
        return

    if _check_ping(raw):
        return

    try:
        request = JobRequest.model_validate_json(raw)
    except Exception as exc:
        result = JobResult(
            job_id="unknown",
            status="error",
            error_message=f"Invalid JobRequest: {exc}",
        )
        report_result(result)
        ctx.exit(1)
        return

    try:
        result = run(request)
    except Exception as exc:
        result = JobResult(
            job_id=request.job_id,
            status="error",
            error_message=str(exc),
        )

    report_result(result)


@cli.command()
def postprocess() -> None:
    """Run postprocessing on an existing transcript."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw or _check_ping(raw):
        return

    try:
        request = JobRequest.model_validate_json(raw)
    except Exception as exc:
        result = JobResult(job_id="unknown", status="error", error_message=str(exc))
        report_result(result)
        return

    try:
        transcript_path = os.path.splitext(request.audio_path)[0] + "_transcript.json"
        with open(transcript_path, encoding="utf-8") as f:
            seg_data = json.load(f)
        segments = [TranscriptSegment.model_validate(s) for s in seg_data]

        note = generate_markdown(
            segments,
            request.markdown_profile,
            notes_language=request.notes_language,
        )
        rendered = render_markdown(note, request.markdown_profile)
        md_path = os.path.splitext(request.audio_path)[0] + "_notes.md"
        write_markdown(rendered, md_path)

        result = JobResult(
            job_id=request.job_id,
            status="completed",
            markdown_path=md_path,
        )
    except Exception as exc:
        result = JobResult(job_id=request.job_id, status="error", error_message=str(exc))

    report_result(result)


@cli.command()
def export() -> None:
    """Export transcript and notes to files."""
    raw = click.get_text_stream("stdin").read().strip()
    if not raw or _check_ping(raw):
        return

    sys.stderr.write('{"info": "export command is handled as part of transcribe pipeline"}\n')
    sys.stderr.flush()


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


@cli.command(name="live")
@click.option("--model", default="base", show_default=True)
@click.option("--language", default="auto", show_default=True)
@click.pass_context
def live_cmd(ctx: click.Context, model: str, language: str) -> None:
    """Transcribe local PCM chunks from stdin until stop or EOF."""
    from app.transcribe.live import run_live

    ctx.exit(run_live(click.get_text_stream("stdin"), click.get_text_stream("stdout"), model, language))


@cli.command(name="prepare-live-model")
@click.option("--model", default="base", show_default=True)
@click.pass_context
def prepare_live_model(ctx: click.Context, model: str) -> None:
    """Explicitly download and validate a local speech model before recording."""
    from app.transcribe.live import emit, model_logs_to_stderr, prepare_model

    output = click.get_text_stream("stdout")
    try:
        with model_logs_to_stderr():
            prepare_model(model)
    except Exception as exc:
        emit(output, {"type": "error", "message": str(exc)})
        ctx.exit(1)
        return
    emit(output, {"type": "ready"})


# Register the transcribe command with the expected CLI name
cli.add_command(transcribe_cmd, name="transcribe")

if __name__ == "__main__":
    main()
