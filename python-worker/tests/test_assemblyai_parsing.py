"""Tests for the AssemblyAI response-mapping helper.

The actual HTTP flow (upload → submit → poll) needs a live key; we test the
deterministic part — parsing the completed transcript body into the worker's
`TranscriptSegment` shape, including the diarized utterance branch and the
no-diarization fallback.
"""

from __future__ import annotations

from app.transcribe.remote_engine import (
    _assemblyai_segments_from,
    _assemblyai_transcript_payload,
)


def test_maps_diarized_utterances_to_segments_with_speaker_labels():
    body = {
        "status": "completed",
        "audio_duration": 12.5,
        "utterances": [
            {"start": 0, "end": 2000, "text": "Hello there", "speaker": "A"},
            {"start": 2100, "end": 5500, "text": "Hi back", "speaker": "B"},
        ],
    }
    segs = _assemblyai_segments_from(body)
    assert len(segs) == 2
    assert segs[0].start == 0.0
    assert segs[0].end == 2.0
    assert segs[0].text == "Hello there"
    assert segs[0].speaker == "Speaker A"
    assert segs[1].speaker == "Speaker B"
    assert segs[1].start == 2.1


def test_missing_speaker_id_leaves_speaker_none():
    body = {"utterances": [{"start": 0, "end": 1000, "text": "x"}]}
    segs = _assemblyai_segments_from(body)
    assert segs[0].speaker is None


def test_no_utterances_falls_back_to_full_text_single_segment():
    body = {"text": "All as one block.", "audio_duration": 7.0}
    segs = _assemblyai_segments_from(body)
    assert len(segs) == 1
    assert segs[0].text == "All as one block."
    assert segs[0].start == 0.0
    assert segs[0].end == 7.0
    assert segs[0].speaker is None


def test_empty_body_returns_no_segments():
    assert _assemblyai_segments_from({}) == []
    assert _assemblyai_segments_from({"text": "   "}) == []


# ---- transcript payload --------------------------------------------------
#
# AssemblyAI deprecated the singular `speech_model` param (and the `best` /
# `nano` aliases) — sending them returns HTTP 400 "speech model is deprecated".
# The current API uses the `speech_models` priority list. We send
# ["universal-3-pro", "universal-2"]: Pro handles its 6 high-accuracy languages,
# Universal-2 (~99 languages) handles everything else, both with diarization.
# The English-only analytics (sentiment / chapters / entities) are never read by
# `_assemblyai_segments_from`, so we no longer request them at all.

_EXPECTED_SPEECH_MODELS = ["universal-3-pro", "universal-2"]
_DEAD_ANALYTICS = ("sentiment_analysis", "auto_chapters", "entity_detection")


def test_payload_never_sends_deprecated_speech_model_key():
    for lang in ("en", "auto", "", "uk", "es"):
        p = _assemblyai_transcript_payload("u://x.wav", lang)
        assert "speech_model" not in p, f"deprecated key leaked for {lang!r}"
        assert p["speech_models"] == _EXPECTED_SPEECH_MODELS


def test_payload_always_requests_diarization():
    for lang in ("en", "auto", "uk", "es"):
        p = _assemblyai_transcript_payload("u://x.wav", lang)
        assert p["speaker_labels"] is True, f"no diarization for {lang!r}"


def test_payload_drops_unused_english_only_analytics():
    for lang in ("en", "auto", "uk", "es"):
        p = _assemblyai_transcript_payload("u://x.wav", lang)
        for feature in _DEAD_ANALYTICS:
            assert feature not in p, f"{feature} requested but never parsed"


def test_payload_for_explicit_language_sets_language_code():
    p = _assemblyai_transcript_payload("u://x.wav", "uk")
    assert p["language_code"] == "uk"
    assert "language_detection" not in p


def test_payload_for_auto_uses_language_detection_not_code():
    for lang in ("auto", ""):
        p = _assemblyai_transcript_payload("u://x.wav", lang)
        assert "language_code" not in p
        assert p["language_detection"] is True


def test_payload_carries_audio_url():
    p = _assemblyai_transcript_payload("u://x.wav", "en")
    assert p["audio_url"] == "u://x.wav"


def _fake_assemblyai(poll_body):
    def request(method, url, **kwargs):
        if url.endswith("/upload"):
            return {"upload_url": "https://upload.invalid/u"}
        if method == "POST":
            return {"id": "t1"}
        return poll_body
    return request


def test_no_spoken_audio_is_an_empty_transcript_not_a_failure(tmp_path, monkeypatch):
    """A stem with sound but no speech (music, system sounds) must not fail the job."""
    from app.transcribe import remote_engine
    audio = tmp_path / "stem.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(remote_engine, "_assemblyai_request", _fake_assemblyai({
        "status": "error",
        "error": "language_detection cannot be performed on files with no spoken audio.",
    }))
    assert remote_engine._transcribe_assemblyai(str(audio), "auto", "key", "job") == []


def test_other_assemblyai_errors_still_fail(tmp_path, monkeypatch):
    import pytest
    from app.transcribe import remote_engine
    audio = tmp_path / "stem.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(remote_engine, "_assemblyai_request", _fake_assemblyai({
        "status": "error", "error": "Invalid API key"}))
    with pytest.raises(RuntimeError, match="Invalid API key"):
        remote_engine._transcribe_assemblyai(str(audio), "auto", "key", "job")
