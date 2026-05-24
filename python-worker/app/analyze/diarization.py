"""Reads the optional diarization turns sidecar written by a diarization provider."""

from __future__ import annotations

import json
import os

from app.schemas.models import DiarizationTurn


def sidecar_path(audio_path: str) -> str:
    """Path of the diarization sidecar for a given audio file."""
    base = os.path.splitext(audio_path)[0]
    return f"{base}_diarization.json"


def load_diarization_turns(audio_path: str) -> list[DiarizationTurn] | None:
    """Load speaker turns from `<base>_diarization.json`, or None if absent/invalid.

    The sidecar is produced by the diarization provider (Phase 3b). Its absence
    means "not diarized" — callers fall back to a single speaker.
    """
    path = sidecar_path(audio_path)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return [DiarizationTurn.model_validate(t) for t in data.get("turns", [])]
    except Exception:
        return None
