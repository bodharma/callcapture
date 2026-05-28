"""Regression tests for the local whisper engine's language handling.

Prior bug: `language="auto"` was silently rewritten to `"en"`, forcing every
recording to be decoded as English (Ukrainian audio came out as garbled English
approximations). Auto must reach whisper.cpp as `"auto"` so it can detect.
"""

from __future__ import annotations

import sys
import types
from unittest.mock import MagicMock

from app.transcribe.local_engine import transcribe_local


def _install_fake_pywhispercpp(monkeypatch) -> MagicMock:
    """Install a fake `pywhispercpp.model.Model` so we can assert how it is
    constructed without needing the real whisper binary or any audio."""
    fake_segment = types.SimpleNamespace(t0=0, t1=100, text="hello")
    model_factory = MagicMock()
    fake_instance = MagicMock()
    fake_instance.transcribe.return_value = [fake_segment]
    model_factory.return_value = fake_instance

    fake_module = types.ModuleType("pywhispercpp.model")
    fake_module.Model = model_factory
    parent = types.ModuleType("pywhispercpp")
    parent.model = fake_module

    monkeypatch.setitem(sys.modules, "pywhispercpp", parent)
    monkeypatch.setitem(sys.modules, "pywhispercpp.model", fake_module)
    return model_factory


def test_auto_language_reaches_whisper_as_auto(monkeypatch, tmp_path):
    """`language="auto"` MUST be forwarded to Whisper (not rewritten to en)."""
    factory = _install_fake_pywhispercpp(monkeypatch)

    audio = tmp_path / "x.wav"
    audio.write_bytes(b"")

    transcribe_local(
        audio_path=str(audio), model="base", language="auto", job_id="t"
    )

    assert factory.call_count == 1
    kwargs = factory.call_args.kwargs
    assert kwargs.get("language") == "auto", (
        f"expected language='auto' to reach whisper, got {kwargs.get('language')!r}"
    )


def test_explicit_language_is_passed_through(monkeypatch, tmp_path):
    """A specific language code stays intact."""
    factory = _install_fake_pywhispercpp(monkeypatch)

    audio = tmp_path / "x.wav"
    audio.write_bytes(b"")

    transcribe_local(
        audio_path=str(audio), model="base", language="uk", job_id="t"
    )

    assert factory.call_args.kwargs.get("language") == "uk"
