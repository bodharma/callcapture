"""Bounded NDJSON speech worker; final evidence is immutable per audio source."""
from __future__ import annotations

import base64
import binascii
from collections import OrderedDict
from contextlib import contextmanager, redirect_stdout
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import TextIO

import numpy as np

SAMPLE_RATE = 16000
MAX_SAMPLES = SAMPLE_RATE * 15
# ponytail: energy gate, not a VAD. Windows below about -50 dBFS RMS skip inference:
# Whisper turns them into "[BLANK_AUDIO]" or stock phrases ("Thank you for watching.").
# Speech quieter than the gate is missing from the live view only (the recording keeps
# it); switch to a real VAD (e.g. Silero) if that shows up.
SILENCE_RMS = 0.003
# Whisper's non-speech annotations: [BLANK_AUDIO], [MUSIC], (laughs), music notes.
_NON_SPEECH = re.compile(r"\[[^\]]*\]|\([^)]*\)|[\u266a\u266b]+")


def speech_text(text: str) -> str:
    return " ".join(_NON_SPEECH.sub(" ", text).split())
MAX_LINE_BYTES = 1_300_000


@contextmanager
def model_logs_to_stderr():
    """Keep Python and native diagnostics off the protocol's stdout."""
    sys.stdout.flush()
    saved_fd = os.dup(1)
    try:
        os.dup2(2, 1)
        with redirect_stdout(sys.stderr):
            yield
    finally:
        sys.stderr.flush()
        os.dup2(saved_fd, 1)
        os.close(saved_fd)


def _model_path(name: str) -> Path:
    from pywhispercpp.constants import AVAILABLE_MODELS, MODELS_DIR

    if name not in AVAILABLE_MODELS:
        raise ValueError("Unsupported Whisper model name")
    return Path(MODELS_DIR) / f"ggml-{name}.bin"


def _create_model(path: Path, language: str):
    from pywhispercpp.model import Model, pw

    if language != "auto" and pw.whisper_lang_id(language) < 0:
        raise ValueError("Unsupported speech language")
    if ".en" in path.name and language != "en":
        raise ValueError("English-only model requires explicit English; choose a multilingual model for Auto/Ukrainian")

    class CheckedModel(Model):
        # pywhispercpp 1.4.1 ignores whisper_full's rc and can return stale segments.
        def _transcribe(self, audio, n_processors=None):
            if n_processors is not None:
                raise ValueError("Live inference uses one persistent model process")
            rc = pw.whisper_full(self._ctx, self._params, audio, audio.size)
            if rc != 0:
                raise RuntimeError(f"Whisper inference failed (code {rc})")
            self.detected_language = pw.whisper_lang_str(pw.whisper_full_lang_id(self._ctx))
            count = pw.whisper_full_n_segments(self._ctx)
            return self._get_segments(self._ctx, 0, count, self.extract_probability)

    instance = CheckedModel(str(path), language=language, no_context=True,
                            print_progress=False, print_realtime=False,
                            print_timestamps=False, redirect_whispercpp_logs_to=sys.stderr)
    if instance._ctx is None:
        raise RuntimeError("Whisper could not load the model")
    return instance


def load_model(name: str, language: str):
    path = _model_path(name)
    if not path.is_file():
        raise RuntimeError(f"Local Whisper model '{name}' is not prepared; download it before recording")
    return _create_model(path, language)


def prepare_model(name: str) -> None:
    """Explicit download, validate before publishing; never cache partial downloads."""
    from pywhispercpp.utils import download_model

    path = _model_path(name)
    if path.is_file():
        _create_model(path, "en" if ".en" in name else "auto")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".live-model-", dir=path.parent) as staging:
        downloaded = download_model(name, download_dir=staging)
        if not downloaded or not Path(downloaded).is_file():
            raise RuntimeError("Whisper model download did not produce a model")
        _create_model(Path(downloaded), "en" if ".en" in name else "auto")
        os.replace(downloaded, path)


@dataclass
class AudioChunk:
    id: str
    source: str
    start: float
    final: bool
    pcm: np.ndarray

    @classmethod
    def parse(cls, data: dict):
        request_id = data.get("id")
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128 or not request_id.isprintable():
            raise ValueError("id must contain 1-128 printable characters")
        if data.get("source") not in ("mic", "system"):
            raise ValueError("source must be mic or system")
        if type(data.get("sample_rate")) is not int or data["sample_rate"] != SAMPLE_RATE:
            raise ValueError("sample_rate must be 16000")
        start = data.get("start")
        if type(start) not in (int, float) or not math.isfinite(start) or not 0 <= start <= 1_000_000_000:
            raise ValueError("start must be finite, nonnegative seconds within 1e9")
        if type(data.get("final")) is not bool:
            raise ValueError("final must be a boolean")
        encoded = data.get("pcm_f32le")
        if not isinstance(encoded, str) or not encoded or len(encoded) > MAX_SAMPLES * 4 * 4 // 3:
            raise ValueError("pcm_f32le must contain at most 15 seconds of float32LE audio")
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise ValueError("pcm_f32le is not valid base64") from exc
        if not raw or len(raw) % 4 or len(raw) > MAX_SAMPLES * 4:
            raise ValueError("PCM must contain 1-240000 complete float32 samples")
        pcm = np.frombuffer(raw, dtype="<f4").astype(np.float32, copy=True)
        if not np.isfinite(pcm).all():
            raise ValueError("PCM samples must be finite")
        return cls(request_id, data["source"], float(start), data["final"], pcm)


class LiveTranscriber:
    def __init__(self, model):
        self.model = model
        self.finalized: OrderedDict[tuple[str, str], str] = OrderedDict()
        self.ends = {"mic": 0.0, "system": 0.0}
        self.tails = {"mic": [], "system": []}

    def process(self, chunk: AudioChunk) -> list[dict]:
        key = (chunk.source, chunk.id)
        fingerprint = hashlib.sha256(chunk.pcm.tobytes() + str(chunk.start).encode()).hexdigest()
        if key in self.finalized:
            if fingerprint != self.finalized[key]:
                raise ValueError("A finalized chunk id cannot be reused for different audio")
            return []
        if float(np.sqrt(np.mean(np.square(chunk.pcm, dtype=np.float64)))) < SILENCE_RMS:
            if chunk.final:
                self._remember(key, fingerprint)
            return []
        with model_logs_to_stderr():
            segments = self.model.transcribe(chunk.pcm)
        duration = chunk.pcm.size / SAMPLE_RATE
        candidates = []
        for index, segment in enumerate(segments):
            start, end = float(segment.t0) / 100, float(segment.t1) / 100
            if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end < start:
                raise ValueError("Whisper returned invalid segment timestamps")
            text = speech_text(segment.text)
            if text and start < duration:
                candidates.append((index, chunk.start + start, chunk.start + min(end, duration), text))
        if not chunk.final:
            return [{"type": "partial", "source": chunk.source, "start": candidates[0][1],
                     "end": candidates[-1][2], "text": " ".join(s[3] for s in candidates)}] if candidates else []

        events = []
        end_of_source = self.ends[chunk.source]
        tail = list(self.tails[chunk.source])
        language = getattr(self.model, "detected_language", None)
        for index, start, end, text in candidates:
            if end <= end_of_source:
                continue
            words = text.split()
            if start < end_of_source:
                normalized = [re.sub(r"\W", "", word).casefold() for word in words]
                for length in range(min(len(tail), len(words)), 0, -1):
                    if tail[-length:] == normalized[:length]:
                        words = words[length:]
                        break
                start = end_of_source
            if not words or start >= end:
                continue
            text = " ".join(words)
            identity = hashlib.sha256(f"{chunk.source}\0{chunk.id}\0{chunk.start}\0{index}".encode()).hexdigest()[:24]
            event = dict(type="turn", id=identity, source=chunk.source, start=start,
                         end=end, text=text, final=True)
            if isinstance(language, str) and language:
                event["language"] = language
            events.append(event)
            end_of_source = end
            tail = (tail + [re.sub(r"\W", "", word).casefold() for word in words])[-128:]
        self.ends[chunk.source] = end_of_source
        self.tails[chunk.source] = tail
        self._remember(key, fingerprint)
        return events

    def _remember(self, key: tuple[str, str], fingerprint: str) -> None:
        self.finalized[key] = fingerprint
        if len(self.finalized) > 512:
            self.finalized.popitem(last=False)


def emit(output: TextIO, event: dict) -> None:
    output.write(json.dumps(event, ensure_ascii=False, allow_nan=False) + "\n")
    output.flush()


def run_live(incoming: TextIO, output: TextIO, model_name: str, language: str) -> int:
    try:
        with model_logs_to_stderr():
            transcriber = LiveTranscriber(load_model(model_name, language))
    except Exception as exc:
        emit(output, {"type": "error", "message": str(exc)})
        return 1
    emit(output, {"type": "ready"})
    while True:
        line = incoming.readline(MAX_LINE_BYTES + 1)
        if not line:
            return 0
        if len(line) > MAX_LINE_BYTES:
            while line and not line.endswith("\n"):
                line = incoming.readline(MAX_LINE_BYTES + 1)
            emit(output, {"type": "error", "message": "Request exceeds the live frame size limit"})
            continue
        request_id = None
        try:
            data = json.loads(line)
            if not isinstance(data, dict):
                raise ValueError("A live request must be a JSON object")
            if data == {"type": "stop"}:
                return 0
            if isinstance(data.get("id"), str) and len(data["id"]) <= 128:
                request_id = data["id"]
            chunk = AudioChunk.parse(data)
            for event in transcriber.process(chunk):
                emit(output, event)
            emit(output, {"type": "chunk_done", "id": chunk.id})
        except Exception as exc:
            error = {"type": "error", "message": str(exc)}
            if request_id is not None:
                error["request_id"] = request_id
            emit(output, error)
