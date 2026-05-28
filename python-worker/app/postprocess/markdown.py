"""LLM-powered markdown note generation from transcript segments."""

from __future__ import annotations

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import (
    language_directive,
    resolve_llm_env,
    transcript_text,
    warn,
)
from app.schemas.models import MarkdownNote, TranscriptSegment

_SYSTEM_PROMPT = (
    "You are a meeting notes assistant. Given a call transcript, extract structured "
    "information. Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), "key_points": [str], '
    '"decisions": [str], "action_items": [str (each starting with "- [ ] " or empty string)]}\n'
    "Rules: No invented facts. Mark unclear text with [unclear]."
)


def _fallback_extraction(
    segments: list[TranscriptSegment],
) -> MarkdownNote:
    """Rule-based fallback when no LLM API key is available."""
    texts = [seg.text for seg in segments]
    title = texts[0][:60] if texts else "Untitled Call"
    summary = " ".join(texts)[:499]
    return MarkdownNote(
        title=title,
        summary=summary,
        key_points=texts[:5],
        decisions=[],
        action_items=[],
        transcript_segments=list(segments),
    )


def generate_markdown(
    segments: list[TranscriptSegment],
    profile: str = "meeting_notes",
    notes_language: str = "auto",
) -> MarkdownNote:
    """Generate a structured MarkdownNote from transcript segments via the LLM.

    Uses the OpenAI-compatible endpoint described by the LLM_* env vars
    (OpenRouter or a local server). Falls back to rule-based extraction when the
    endpoint is unusable or the call fails.

    Args:
        segments: Transcript segments.
        profile: Markdown profile (used during rendering).
    """
    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using fallback")
        return _fallback_extraction(segments)

    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(
            system=language_directive(notes_language) + _SYSTEM_PROMPT,
            user=f"Transcript:\n\n{transcript_text(segments, timestamps=True)}",
        )
        return MarkdownNote(
            title=data.get("title", "Untitled"),
            summary=data.get("summary", "")[:499],
            key_points=data.get("key_points", []),
            decisions=data.get("decisions", []),
            action_items=data.get("action_items", []),
            transcript_segments=list(segments),
        )
    except LLMError as exc:
        warn(f"LLM failed: {exc}, using fallback")
        return _fallback_extraction(segments)
