"""Digitally silent stems are not sent to a transcription provider.

A system stem is pure zeros whenever nothing plays during a recording. Sending it
to AssemblyAI failed the whole job ("no spoken audio") and discarded the mic speech.
"""
import wave

import numpy as np
import pytest

from app import cli
from app.schemas.models import JobRequest, TranscriptSegment


def _wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(np.asarray(samples, dtype=np.int16).tobytes())


def _speech(n=16000):
    return (np.sin(np.linspace(0, 400 * np.pi, n)) * 3000).astype(np.int16)


def _request(tmp_path):
    return JobRequest(job_id="j", command="transcribe", audio_path=str(tmp_path / "rec.wav"))


def test_silent_system_stem_is_skipped_and_mic_speech_kept(tmp_path, monkeypatch):
    _wav(tmp_path / "rec.wav", _speech() // 2)
    _wav(tmp_path / "rec_mic.wav", _speech())
    _wav(tmp_path / "rec_system.wav", np.zeros(16000))
    calls = []

    def fake_transcribe_path(path, request):
        calls.append(path)
        return [TranscriptSegment(start=0, end=1, text="hello", speaker=None)]

    monkeypatch.setattr(cli, "transcribe_path", fake_transcribe_path)
    segments = cli._transcribe_and_attribute(_request(tmp_path))
    assert calls == [str(tmp_path / "rec_mic.wav")]
    assert [(s.speaker, s.text) for s in segments] == [("You", "hello")]


def test_silent_mic_stem_is_skipped_and_system_speech_kept(tmp_path, monkeypatch):
    _wav(tmp_path / "rec.wav", _speech() // 2)
    _wav(tmp_path / "rec_mic.wav", np.zeros(16000))
    _wav(tmp_path / "rec_system.wav", _speech())
    calls = []
    monkeypatch.setattr(cli, "transcribe_path", lambda path, request: calls.append(path) or [
        TranscriptSegment(start=0, end=1, text="remote", speaker="Speaker A")])
    segments = cli._transcribe_and_attribute(_request(tmp_path))
    assert calls == [str(tmp_path / "rec_system.wav")]
    assert [s.text for s in segments] == ["remote"]


def test_all_silent_stems_fail_with_an_actionable_error_and_no_provider_call(tmp_path, monkeypatch):
    for name in ("rec.wav", "rec_mic.wav", "rec_system.wav"):
        _wav(tmp_path / name, np.zeros(16000))
    monkeypatch.setattr(cli, "transcribe_path", lambda *a: pytest.fail("silent audio sent to a provider"))
    with pytest.raises(RuntimeError, match="no audio"):
        cli._transcribe_and_attribute(_request(tmp_path))


def test_silent_single_file_fails_without_a_provider_call(tmp_path, monkeypatch):
    _wav(tmp_path / "rec.wav", np.zeros(16000))
    monkeypatch.setattr(cli, "transcribe", lambda *a: pytest.fail("silent audio sent to a provider"))
    with pytest.raises(RuntimeError, match="no audio"):
        cli._transcribe_and_attribute(_request(tmp_path))


def test_cost_counts_only_transcribed_stems(tmp_path):
    _wav(tmp_path / "rec.wav", _speech())
    _wav(tmp_path / "rec_mic.wav", _speech())
    _wav(tmp_path / "rec_system.wav", np.zeros(16000))
    assert cli._count_stems(str(tmp_path / "rec.wav")) == 1
    _wav(tmp_path / "rec_system.wav", _speech())
    cli._is_silent.cache_clear()
    assert cli._count_stems(str(tmp_path / "rec.wav")) == 2


def test_unreadable_audio_is_not_treated_as_silent(tmp_path, monkeypatch):
    (tmp_path / "rec.wav").write_bytes(b"not a wav")
    monkeypatch.setattr(cli, "transcribe", lambda request: [TranscriptSegment(start=0, end=1, text="x")])
    assert [s.text for s in cli._transcribe_and_attribute(_request(tmp_path))] == ["x"]
