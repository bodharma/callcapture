"""The live wire contract is local, bounded, and never invents speech."""
import base64
import io
import json
from types import SimpleNamespace

import numpy as np
import pytest
from click.testing import CliRunner


def frame(*, id="c1", source="mic", start=10.0, final=True, samples=None, **updates):
    if samples is None:
        samples = np.zeros(16000 * 6, dtype="<f4")
    request = dict(id=id, source=source, start=start, final=final,
                   sample_rate=16000, pcm_f32le=base64.b64encode(samples.tobytes()).decode())
    request.update(updates)
    return request


def segment(text="Hello there", start=0, end=200):
    return SimpleNamespace(t0=start, t1=end, text=text)


class Model:
    detected_language = "en"

    def __init__(self, responses=None):
        self.responses = iter(responses or [[segment()]])
        self.calls = []

    def transcribe(self, pcm):
        self.calls.append(pcm)
        result = next(self.responses)
        if isinstance(result, Exception):
            raise result
        print("model diagnostics must go to stderr")
        return result


def run(monkeypatch, requests, model=None):
    from app.transcribe import live
    model = model or Model()
    loads = []

    def load(name, language):
        loads.append((name, language))
        return model

    monkeypatch.setattr(live, "load_model", load)
    incoming = io.StringIO("".join(r + "\n" if isinstance(r, str) else json.dumps(r) + "\n"
                                 for r in requests))
    output = io.StringIO()
    result = live.run_live(incoming, output, "base", "auto")
    return [json.loads(line) for line in output.getvalue().splitlines()], model, loads, result


def test_persistent_model_offsets_sources_and_no_stdout_logs(monkeypatch, capsys):
    events, model, loads, result = run(monkeypatch, [frame(), frame(id="c2", source="system")],
                                     Model([[segment()], [segment("A reply")]]))
    assert result == 0
    assert loads == [("base", "auto")]
    assert events[0] == {"type": "ready"}
    turns = [e for e in events if e["type"] == "turn"]
    assert [(e["source"], e["start"], e["end"], e["text"], e["final"]) for e in turns] == [
        ("mic", 10.0, 12.0, "Hello there", True), ("system", 10.0, 12.0, "A reply", True)]
    assert turns[0]["id"] != turns[1]["id"]
    assert all(t["language"] == "en" for t in turns)
    assert [e for e in events if e["type"] == "chunk_done"] == [
        {"type": "chunk_done", "id": "c1"}, {"type": "chunk_done", "id": "c2"}]
    assert len(model.calls) == 2 and model.calls[0].dtype == np.dtype("float32")
    assert "diagnostics" in capsys.readouterr().err


def test_partial_then_final_then_retry_commits_only_once(monkeypatch):
    events, model, _, _ = run(monkeypatch,
        [frame(final=False), frame(), frame()], Model([[segment("Hello")], [segment()]]))
    assert [e["type"] for e in events] == ["ready", "partial", "chunk_done", "turn", "chunk_done", "chunk_done"]
    assert events[1] == {"type": "partial", "source": "mic", "text": "Hello", "start": 10.0, "end": 12.0}
    assert len(model.calls) == 2


def test_overlap_removes_repeated_suffix_only_for_same_source(monkeypatch):
    model = Model([[segment("The release plan is ready", end=500)],
                   [segment("is ready and testing starts", end=500)],
                   [segment("is ready and testing starts", end=500)],
                   [segment("and testing starts", end=200)]])
    events, _, _, _ = run(monkeypatch, [frame(start=0), frame(id="c2", start=4),
        frame(id="c3", start=4, source="system"), frame(id="c4", start=10)], model)
    turns = [e for e in events if e["type"] == "turn"]
    assert [e["text"] for e in turns] == ["The release plan is ready", "and testing starts",
                                            "is ready and testing starts", "and testing starts"]
    assert turns[1]["start"] == 5


def test_wholly_committed_overlap_is_not_emitted_again(monkeypatch):
    events, _, _, _ = run(monkeypatch, [frame(start=0), frame(id="c2", start=4)],
        Model([[segment("already said", end=500)], [segment("already said", end=100)]]))
    assert len([e for e in events if e["type"] == "turn"]) == 1


@pytest.mark.parametrize("changes", [
    {"source": "other"}, {"sample_rate": 8000}, {"sample_rate": 16000.0},
    {"start": -1}, {"start": float("nan")}, {"start": float("inf")}, {"start": True},
    {"final": 1}, {"id": ""}, {"id": "x" * 129}, {"id": 1},
    {"pcm_f32le": "not base64"}, {"pcm_f32le": ""},
    {"pcm_f32le": base64.b64encode(b"abc").decode()},
    {"samples": np.array([float("nan")], dtype="<f4")},
    {"samples": np.array([float("inf")], dtype="<f4")},
    {"samples": np.zeros(16000 * 15 + 1, dtype="<f4")},
])
def test_rejects_invalid_audio_without_running_model(monkeypatch, changes):
    events, model, _, _ = run(monkeypatch, [frame(**changes)])
    assert events[-1]["type"] == "error"
    assert "message" in events[-1]
    assert not model.calls
    assert not any(e["type"] == "chunk_done" for e in events)


@pytest.mark.parametrize("raw", ["{", "[]", "null", '{}', '{"type":"unsupported"}'])
def test_bad_json_shapes_fail_and_next_request_still_works(monkeypatch, raw):
    events, _, _, _ = run(monkeypatch, [raw, frame()])
    assert [e["type"] for e in events] == ["ready", "error", "turn", "chunk_done"]


def test_oversize_wire_frame_is_drained_then_processing_continues(monkeypatch):
    from app.transcribe import live
    events, model, _, _ = run(monkeypatch, ["x" * (live.MAX_LINE_BYTES + 1), frame()])
    assert [e["type"] for e in events] == ["ready", "error", "turn", "chunk_done"]
    assert len(model.calls) == 1


def test_stop_and_eof_drain_prior_requests_but_ignore_later_frames(monkeypatch):
    events, model, _, result = run(monkeypatch, [frame(), {"type": "stop"}, frame(id="later")])
    assert result == 0
    assert len(model.calls) == 1
    assert events[-1] == {"type": "chunk_done", "id": "c1"}


def test_model_failure_is_error_and_can_retry_same_chunk(monkeypatch):
    events, model, _, _ = run(monkeypatch, [frame(), frame()],
                            Model([RuntimeError("decoder failed"), [segment()]]))
    assert [e["type"] for e in events] == ["ready", "error", "turn", "chunk_done"]
    assert events[1]["request_id"] == "c1"
    assert "decoder failed" in events[1]["message"]


def test_no_model_or_dependency_means_error_not_ready(monkeypatch):
    from app.transcribe import live
    monkeypatch.setattr(live, "load_model", lambda *_: (_ for _ in ()).throw(ImportError("pywhispercpp missing")))
    output = io.StringIO()
    assert live.run_live(io.StringIO(""), output, "base", "auto") == 1
    events = [json.loads(line) for line in output.getvalue().splitlines()]
    assert len(events) == 1 and events[0]["type"] == "error"
    assert "missing" in events[0]["message"]


def test_invalid_native_timestamps_fail_whole_chunk_before_any_turn(monkeypatch):
    events, _, _, _ = run(monkeypatch, [frame()],
        Model([[segment(), segment("bad", end=float("nan"))]]))
    assert [e["type"] for e in events] == ["ready", "error"]


def test_cli_registers_live_and_passes_model_and_language(monkeypatch):
    from app.cli import cli
    from app.transcribe import live
    calls = []
    monkeypatch.setattr(live, "run_live", lambda incoming, outgoing, model, language: calls.append((model, language)) or 0)
    result = CliRunner().invoke(cli, ["live", "--model", "base", "--language", "uk"], input='{"type":"stop"}\n')
    assert result.exit_code == 0, result.output
    assert calls == [("base", "uk")]


def test_prepare_command_explicitly_downloads_and_emits_ready(monkeypatch):
    from app.cli import cli
    from app.transcribe import live
    calls = []
    monkeypatch.setattr(live, "prepare_model", lambda name: calls.append(name))
    result = CliRunner().invoke(cli, ["prepare-live-model", "--model", "base"])
    assert result.exit_code == 0, result.output
    assert calls == ["base"]
    assert json.loads(result.stdout) == {"type": "ready"}


def test_prepare_command_failure_emits_error_and_nonzero(monkeypatch):
    from app.cli import cli
    from app.transcribe import live
    monkeypatch.setattr(live, "prepare_model", lambda name: (_ for _ in ()).throw(RuntimeError("download failed")))
    result = CliRunner().invoke(cli, ["prepare-live-model", "--model", "base"])
    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"type": "error", "message": "download failed"}


def test_finalized_id_rejects_changed_audio(monkeypatch):
    events, model, _, _ = run(monkeypatch, [frame(), frame(start=11)])
    assert events[-1]["type"] == "error"
    assert len(model.calls) == 1


def test_model_absence_never_downloads(monkeypatch, tmp_path):
    from app.transcribe import live
    monkeypatch.setattr(live, "_model_path", lambda name: tmp_path / "missing.bin")
    with pytest.raises(RuntimeError, match="not prepared"):
        live.load_model("base", "auto")


def test_invalid_model_name_is_not_a_path_or_download_target(monkeypatch, tmp_path):
    import sys
    import types
    from app.transcribe import live
    # CI installs no native pywhispercpp; the check only needs its model catalogue.
    constants = types.ModuleType("pywhispercpp.constants")
    constants.AVAILABLE_MODELS = ["base"]
    constants.MODELS_DIR = str(tmp_path)
    monkeypatch.setitem(sys.modules, "pywhispercpp.constants", constants)
    with pytest.raises(ValueError, match="Unsupported Whisper model"):
        live._model_path("../../another-model")
    assert live._model_path("base") == tmp_path / "ggml-base.bin"


def test_checked_model_rejects_native_failure_before_reading_stale_segments(monkeypatch, tmp_path):
    import sys
    import types
    from app.transcribe import live

    class FakeModel:
        def __init__(self, *args, **kwargs):
            self._ctx = object()
            self._params = object()
            self.extract_probability = False

        def _get_segments(self, *args):
            pytest.fail("Reading stale native segments after a failed inference")

    native = SimpleNamespace(whisper_full=lambda *args: -7, whisper_lang_id=lambda language: 1)
    module = types.ModuleType("pywhispercpp.model")
    module.Model = FakeModel
    module.pw = native
    monkeypatch.setitem(sys.modules, "pywhispercpp.model", module)
    model = live._create_model(tmp_path / "ggml-base.bin", "auto")
    with pytest.raises(RuntimeError, match="code -7"):
        model._transcribe(np.zeros(100, dtype=np.float32))


def test_prepare_publishes_only_validated_model(monkeypatch, tmp_path):
    import sys
    import types
    from app.transcribe import live
    # CI installs no native pywhispercpp; stand in for its downloader module.
    utils = types.ModuleType("pywhispercpp.utils")
    monkeypatch.setitem(sys.modules, "pywhispercpp.utils", utils)
    target = tmp_path / "ggml-base.bin"
    monkeypatch.setattr(live, "_model_path", lambda name: target)

    def download(name, download_dir):
        path = __import__("pathlib").Path(download_dir) / target.name
        path.write_bytes(b"invalid HTTP response")
        return str(path)

    utils.download_model = download
    monkeypatch.setattr(live, "_create_model", lambda *_: (_ for _ in ()).throw(RuntimeError("invalid model")))
    with pytest.raises(RuntimeError, match="invalid model"):
        live.prepare_model("base")
    assert not target.exists()
    assert not list(tmp_path.iterdir())


def test_native_stdout_diagnostics_are_redirected(monkeypatch, capfd):
    import os

    class NativeLoggingModel(Model):
        def transcribe(self, pcm):
            os.write(1, b"native diagnostic\n")
            return super().transcribe(pcm)

    events, _, _, _ = run(monkeypatch, [frame()], NativeLoggingModel())
    captured = capfd.readouterr()
    assert "native diagnostic" not in captured.out
    assert "native diagnostic" in captured.err
    assert events[-1]["type"] == "chunk_done"


def test_finalized_chunk_history_and_overlap_tail_are_bounded():
    from app.transcribe.live import AudioChunk, LiveTranscriber
    model = Model([[segment("word", end=1)]] * 520)
    transcriber = LiveTranscriber(model)
    for index in range(520):
        transcriber.process(AudioChunk.parse(frame(id=str(index), start=index)))
    assert len(transcriber.finalized) == 512
    assert len(transcriber.tails["mic"]) == 128


@pytest.mark.parametrize("command", ["live", "prepare-live-model"])
def test_module_entrypoint_exits_nonzero_on_model_error(command):
    import subprocess
    import sys
    from pathlib import Path

    result = subprocess.run([sys.executable, "-m", "app.cli", command, "--model", "invalid-model"],
                            cwd=Path(__file__).resolve().parents[1], input="", capture_output=True,
                            text=True, timeout=15)
    assert result.returncode == 1
    assert json.loads(result.stdout)["type"] == "error"
