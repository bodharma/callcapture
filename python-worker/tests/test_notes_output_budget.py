"""AI notes output budget scales with meeting length; truncated replies are detected."""
import sys
from unittest.mock import MagicMock, patch

import pytest

# CI has no pywhispercpp; stub it the way the other tests do.
sys.modules.setdefault("pywhispercpp", MagicMock())
sys.modules.setdefault("pywhispercpp.model", MagicMock())

from app.analyze import insights as insights_mod
from app.postprocess import markdown as markdown_mod
from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import notes_max_tokens
from app.schemas.models import TranscriptSegment

CUT_OFF = "AI notes were cut off — the meeting is too long for one pass; rule-based notes were used."
SECRET = "zxqv-secret-transcript-text"


def _seg(end: float) -> list[TranscriptSegment]:
    return [TranscriptSegment(start=0.0, end=end, text=SECRET, speaker="You")]


def _completion(content: str, finish_reason: str = "stop"):
    choice = MagicMock()
    choice.message.content = content
    choice.finish_reason = finish_reason
    resp = MagicMock()
    resp.choices = [choice]
    resp.usage.total_tokens = 123
    resp.usage.cost = None
    return resp


@pytest.mark.parametrize("seconds,expected", [
    (10 * 60, 4096),
    (3600, 4096),
    (3 * 3600 + 14 * 60, 6467),  # 11640 s = 3.2333 h * 2000 -> ceil 6467
    (10 * 3600, 16384),
])
def test_budget_scales_with_duration(seconds, expected):
    assert notes_max_tokens(_seg(seconds)) == expected


def test_budget_empty_segments_is_minimum():
    assert notes_max_tokens([]) == 4096


def test_length_triggers_one_retry_with_double_budget():
    client = LLMClient(api_key="k", model="m")
    create = MagicMock(side_effect=[_completion('{"a": "unterm', "length"),
                                    _completion('{"a": 1}', "stop")])
    with patch.object(client._client.chat.completions, "create", create):
        assert client.complete_json("s", "u", max_tokens=5000) == {"a": 1}
    assert [c.kwargs["max_tokens"] for c in create.call_args_list] == [5000, 10000]


def test_retry_budget_is_capped():
    client = LLMClient(api_key="k", model="m")
    create = MagicMock(side_effect=[_completion("{", "length"), _completion("{}", "stop")])
    with patch.object(client._client.chat.completions, "create", create):
        client.complete_json("s", "u", max_tokens=12000)
    assert [c.kwargs["max_tokens"] for c in create.call_args_list] == [12000, 16384]


def test_stop_does_not_retry():
    client = LLMClient(api_key="k", model="m")
    create = MagicMock(return_value=_completion('{"a": 1}', "stop"))
    with patch.object(client._client.chat.completions, "create", create):
        client.complete_json("s", "u")
    assert create.call_count == 1


def test_two_length_replies_raise_cut_off_error():
    client = LLMClient(api_key="k", model="m")
    create = MagicMock(return_value=_completion("{", "length"))
    with patch.object(client._client.chat.completions, "create", create):
        with pytest.raises(LLMError) as ei:
            client.complete_json("s", "u", max_tokens=4096)
    assert create.call_count == 2
    assert str(ei.value) == CUT_OFF


def test_logs_finish_reason_budget_usage_but_no_text(capsys):
    client = LLMClient(api_key="k", model="m")
    with patch.object(client._client.chat.completions, "create",
                      return_value=_completion('{"a": 1}', "stop")):
        client.complete_json(system="sys " + SECRET, user="user " + SECRET, max_tokens=4096)
    err = capsys.readouterr().err
    assert "finish_reason" in err and "stop" in err and "4096" in err and "123" in err
    assert SECRET not in err


@pytest.fixture
def cloud_env(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.delenv("LLM_OFFLINE", raising=False)


def test_insights_cut_off_warns_and_falls_back(cloud_env):
    warnings: list[str] = []
    fake = MagicMock()
    fake.complete_json.side_effect = LLMError(CUT_OFF)
    # real error type so the warning path can recognise it
    from app.postprocess.llm_client import LLMTruncatedError
    fake.complete_json.side_effect = LLMTruncatedError()
    with patch.object(insights_mod, "LLMClient", return_value=fake):
        result = insights_mod.analyze_insights(
            _seg(3 * 3600 + 14 * 60), recording_type="call_meeting", warnings=warnings)
    assert result is not None and result.title
    assert warnings == [CUT_OFF]
    assert fake.complete_json.call_args.kwargs["max_tokens"] == 6467


def test_markdown_passes_scaled_budget(cloud_env):
    fake = MagicMock()
    fake.complete_json.return_value = {"title": "T", "summary": "S"}
    with patch.object(markdown_mod, "LLMClient", return_value=fake):
        markdown_mod.generate_markdown(_seg(10 * 3600))
    assert fake.complete_json.call_args.kwargs["max_tokens"] == 16384
