"""OpenAI-compatible chat client. Works with OpenRouter or a local endpoint."""

from __future__ import annotations

import json
import sys
from typing import Any

from openai import OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
MAX_OUTPUT_TOKENS = 16384

AI_CUT_OFF_MESSAGE = (
    "AI notes were cut off — the meeting is too long for one pass; "
    "rule-based notes were used."
)


def _info(message: str) -> None:
    """Write an `{"info": ...}` JSON line to stderr (never prompt/transcript text)."""
    sys.stderr.write(json.dumps({"info": message}, ensure_ascii=False) + "\n")
    sys.stderr.flush()


from dataclasses import dataclass


@dataclass(frozen=True)
class LLMUsage:
    """Aggregated LLM usage for one worker job."""
    total_tokens: int = 0
    actual_cost: float | None = None  # summed OpenRouter cost, None if never reported


# Module-level accumulator. The worker handles one job per process, so a module
# global is safe; tests reset it explicitly.
_TOKENS = 0
_COST_SUM: float | None = None


def reset_usage() -> None:
    global _TOKENS, _COST_SUM
    _TOKENS = 0
    _COST_SUM = None


def record_usage(tokens: int, cost: float | None) -> None:
    global _TOKENS, _COST_SUM
    _TOKENS += int(tokens or 0)
    if cost is not None:
        _COST_SUM = (_COST_SUM or 0.0) + float(cost)


def get_usage() -> LLMUsage:
    return LLMUsage(total_tokens=_TOKENS, actual_cost=_COST_SUM)


def _extract_usage(resp: object) -> tuple[int, float | None]:
    """Pull (total_tokens, cost) from an OpenAI-compatible response.

    OpenRouter returns `usage.cost` when the request asked for it; other
    endpoints omit it, so cost is None and the caller's fallback rate applies.
    """
    usage = getattr(resp, "usage", None)
    if usage is None:
        return 0, None
    tokens = int(getattr(usage, "total_tokens", 0) or 0)
    cost = getattr(usage, "cost", None)
    return tokens, (float(cost) if cost is not None else None)


class LLMError(Exception):
    """Raised when the LLM endpoint is misconfigured or returns bad output."""


class LLMTruncatedError(LLMError):
    """The model reply was still cut off (finish_reason "length") after a retry."""

    def __init__(self) -> None:
        super().__init__(AI_CUT_OFF_MESSAGE)


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
        # Only OpenRouter understands the usage-cost request; sending it to a
        # strict local server (Ollama/llama.cpp) could 400 and silently degrade
        # post-processing, so gate it on the endpoint.
        self._is_openrouter = "openrouter.ai" in base_url
        # OpenAI SDK requires a non-empty key string; local servers ignore it.
        self._client = OpenAI(api_key=api_key or "none", base_url=base_url)

    def complete_json(
        self, system: str, user: str, max_tokens: int = 2048
    ) -> dict[str, Any]:
        """Send a system+user prompt and parse the reply as JSON.

        Raises:
            LLMError: on API failure or unparseable JSON.
        """
        budget = max_tokens
        for attempt in (1, 2):
            raw, finish = self._request(system, user, budget)
            if finish != "length":
                return self._parse_json(raw)
            if attempt == 1 and budget < MAX_OUTPUT_TOKENS:
                budget = min(budget * 2, MAX_OUTPUT_TOKENS)
                _info(f"LLM reply truncated (finish_reason=length); retrying with max_tokens={budget}")
                continue
            break
        raise LLMTruncatedError()

    def _request(self, system: str, user: str, max_tokens: int) -> tuple[str, str | None]:
        """One chat call; returns (content, finish_reason) and records usage."""
        # OpenRouter returns usage.cost when asked; only request it there.
        extra_body = {"usage": {"include": True}} if self._is_openrouter else {}
        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                extra_body=extra_body,
            )
            tokens, cost = _extract_usage(resp)
            record_usage(tokens, cost)
            choice = resp.choices[0]
            raw = choice.message.content or ""
            finish = getattr(choice, "finish_reason", None)
        except Exception as exc:  # noqa: BLE001 - surface as our error type
            raise LLMError(f"LLM request failed: {exc}") from exc
        _info(f"LLM call: finish_reason={finish} max_tokens={max_tokens} total_tokens={tokens}")
        return raw, finish

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
