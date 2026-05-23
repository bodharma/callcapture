"""OpenAI-compatible chat client. Works with OpenRouter or a local endpoint."""

from __future__ import annotations

import json
from typing import Any

from openai import OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"


class LLMError(Exception):
    """Raised when the LLM endpoint is misconfigured or returns bad output."""


class LLMClient:
    """Calls chat-completion models via any OpenAI-compatible endpoint.

    Args:
        api_key: API key (use a placeholder like ``"ollama"`` for local servers).
        model: Model id, e.g. ``google/gemini-2.5-flash`` or ``qwen2.5:32b``.
        base_url: Endpoint base URL. Defaults to OpenRouter.
    """

    def __init__(
        self, api_key: str, model: str, base_url: str = OPENROUTER_BASE_URL
    ) -> None:
        self.model = model
        # OpenAI SDK requires a non-empty key string; local servers ignore it.
        self._client = OpenAI(api_key=api_key or "none", base_url=base_url)

    def complete_json(
        self, system: str, user: str, max_tokens: int = 2048
    ) -> dict[str, Any]:
        """Send a system+user prompt and parse the reply as JSON.

        Raises:
            LLMError: on API failure or unparseable JSON.
        """
        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            )
            raw = resp.choices[0].message.content or ""
        except Exception as exc:  # noqa: BLE001 - surface as our error type
            raise LLMError(f"LLM request failed: {exc}") from exc

        return self._parse_json(raw)

    @staticmethod
    def _parse_json(raw: str) -> dict[str, Any]:
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            lines = [ln for ln in cleaned.split("\n") if not ln.startswith("```")]
            cleaned = "\n".join(lines)
        try:
            data = json.loads(cleaned)
        except json.JSONDecodeError as exc:
            raise LLMError(f"Invalid JSON from model: {exc}") from exc
        if not isinstance(data, dict):
            raise LLMError("Model JSON was not an object")
        return data
