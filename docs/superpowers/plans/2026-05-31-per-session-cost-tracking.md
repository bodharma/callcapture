# Per-Session Cost Tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the USD cost of transcription + LLM processing for each new session, with user-editable rates.

**Architecture:** A new pure `pricing.py` computes costs from audio minutes × per-provider rate (×stems) and LLM usage (OpenRouter actual cost, else tokens × fallback). The worker captures LLM usage via a module-level log in `llm_client.py`, computes costs in `_run_pipeline`, and returns them in `JobResult`. Swift persists three cost columns (migration v5), exposes editable rates in Settings (flowed to the worker via `JobRequest`), and renders a breakdown in the detail view + a badge in the list.

**Tech Stack:** Python (Pydantic, pytest), Swift/SwiftUI, GRDB.

**Spec:** `docs/superpowers/specs/2026-05-29-per-session-cost-tracking-design.md`

---

## File Structure

**Python — Create:**
- `python-worker/app/postprocess/pricing.py` — default rate table + pure cost functions
- `python-worker/tests/test_pricing.py`
- `python-worker/tests/test_llm_usage.py`
- `python-worker/tests/test_pipeline_cost.py`

**Python — Modify:**
- `python-worker/app/postprocess/llm_client.py` — capture token usage + OpenRouter cost into a module log
- `python-worker/app/schemas/models.py` — `JobRequest` (rate fields) + `JobResult` (cost fields)
- `python-worker/app/cli.py` — compute costs in `_run_pipeline`, attach to `JobResult`

**Swift — Modify:**
- `macos-app/Sources/Persistence/Database.swift` — migration `v5_costColumns`
- `macos-app/Sources/Session/SessionManager.swift` — `Session` cost fields + persist from `JobResult`
- `macos-app/Sources/Settings/SettingsManager.swift` — rate fields + load + reset
- `macos-app/Sources/Settings/SettingsView.swift` — Pricing section
- `macos-app/Sources/Bridge/Models.swift` — `JobRequest` rate injection + `JobResult` cost decode
- `macos-app/Sources/UI/SessionDetailView.swift` — cost breakdown row
- `macos-app/Sources/UI/SessionRowView.swift` — total badge

**Swift — Create:**
- `macos-app/Tests/CallCaptureTests/CostFormatTests.swift`
- `macos-app/Tests/CallCaptureTests/PricingSettingsTests.swift`

Run python tests from `python-worker/` with the venv: `.venv/bin/python -m pytest`. Run swift tests from `macos-app/` with `swift test`.

---

# PHASE A — Worker (Python)

## Task 1: `pricing.py` — rate table + pure cost functions

**Files:**
- Create: `python-worker/app/postprocess/pricing.py`
- Create: `python-worker/tests/test_pricing.py`

- [ ] **Step 1: Write the failing tests**

Create `python-worker/tests/test_pricing.py`:

```python
from app.postprocess import pricing


def test_transcription_cost_single_stem():
    # 10 min × $0.0035/min × 1 stem
    c = pricing.transcription_cost(10.0, "assemblyai", 1, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert round(c, 6) == 0.035


def test_transcription_cost_doubles_for_two_stems():
    c = pricing.transcription_cost(10.0, "assemblyai", 2, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert round(c, 6) == 0.07


def test_transcription_cost_local_is_zero():
    c = pricing.transcription_cost(60.0, "local_whisper", 2, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert c == 0.0


def test_transcription_cost_unknown_provider_is_zero():
    # Unknown provider → rate 0 (never crash on a typo)
    c = pricing.transcription_cost(10.0, "mystery", 1, pricing.DEFAULT_STT_RATE_PER_MIN)
    assert c == 0.0


def test_transcription_cost_override_rate_wins():
    rates = pricing.merge_rates({"assemblyai": 0.01})
    c = pricing.transcription_cost(10.0, "assemblyai", 1, rates)
    assert round(c, 6) == 0.1


def test_merge_rates_falls_back_to_defaults_for_missing_keys():
    rates = pricing.merge_rates({"assemblyai": 0.01})
    assert rates["deepgram"] == pricing.DEFAULT_STT_RATE_PER_MIN["deepgram"]
    assert rates["assemblyai"] == 0.01


def test_merge_rates_ignores_none_and_negative():
    rates = pricing.merge_rates({"assemblyai": None, "deepgram": -5})
    assert rates["assemblyai"] == pricing.DEFAULT_STT_RATE_PER_MIN["assemblyai"]
    assert rates["deepgram"] == pricing.DEFAULT_STT_RATE_PER_MIN["deepgram"]


def test_processing_cost_uses_actual_when_present():
    c = pricing.processing_cost(0.0123, 5000, 3.0)
    assert c == 0.0123


def test_processing_cost_falls_back_to_tokens_when_actual_none():
    # 2,000,000 tokens × $3 / 1e6 = $6
    c = pricing.processing_cost(None, 2_000_000, 3.0)
    assert round(c, 6) == 6.0


def test_processing_cost_zero_tokens_no_actual_is_zero():
    assert pricing.processing_cost(None, 0, 3.0) == 0.0
```

- [ ] **Step 2: Run, expect fail**

Run: `.venv/bin/python -m pytest tests/test_pricing.py -q`
Expected: FAIL (module `app.postprocess.pricing` not found).

- [ ] **Step 3: Implement `pricing.py`**

Create `python-worker/app/postprocess/pricing.py`:

```python
"""USD cost estimation for transcription + LLM processing.

Pure functions, no I/O. Default rates ship in code; the Settings UI can
override them per provider via `merge_rates`.
"""
from __future__ import annotations

# USD. Approximate public rates verified 2026-05-29 — VERIFY before relying on
# them. Sources: assemblyai.com, deepgram.com pricing pages.
DEFAULT_STT_RATE_PER_MIN: dict[str, float] = {
    "assemblyai": 0.0035,   # Universal-3 Pro ~$0.21/hr
    "deepgram": 0.0043,     # Nova-3 pre-recorded
    "openai": 0.0060,       # whisper-1
    "groq": 0.0007,         # whisper distil
    "local_whisper": 0.0,   # on-device, free
}

DEFAULT_LLM_FALLBACK_RATE_PER_1M = 3.00  # blended $/1M tokens, fallback only


def merge_rates(overrides: dict[str, float] | None) -> dict[str, float]:
    """Return defaults with valid (non-None, non-negative) overrides applied."""
    rates = dict(DEFAULT_STT_RATE_PER_MIN)
    for key, value in (overrides or {}).items():
        if isinstance(value, (int, float)) and value >= 0:
            rates[key] = float(value)
    return rates


def transcription_cost(
    minutes: float, provider: str, stems: int, rates: dict[str, float]
) -> float:
    """audio_minutes × per-minute rate × number of stems transcribed."""
    rate = rates.get(provider, 0.0)
    return float(minutes) * rate * int(stems)


def processing_cost(
    actual_cost: float | None, tokens: int, fallback_rate_per_1m: float
) -> float:
    """OpenRouter-reported actual cost when present; else tokens × fallback."""
    if actual_cost is not None:
        return float(actual_cost)
    return (int(tokens) / 1_000_000.0) * float(fallback_rate_per_1m)
```

- [ ] **Step 4: Run, expect pass**

Run: `.venv/bin/python -m pytest tests/test_pricing.py -q`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/postprocess/pricing.py python-worker/tests/test_pricing.py
git commit -m "feat(worker): pricing.py — rate table + pure cost functions"
```

---

## Task 2: LLM usage capture in `llm_client.py`

**Files:**
- Modify: `python-worker/app/postprocess/llm_client.py`
- Create: `python-worker/tests/test_llm_usage.py`

Context: `complete_json` currently discards `resp.usage`. Three modules
(`sentiment.py`, `insights.py`, `markdown.py`) each create their own `LLMClient`,
so usage is aggregated through a module-level log that the pipeline reads. To get
OpenRouter's actual dollar cost (not just tokens), request it via
`extra_body={"usage": {"include": True}}` — OpenRouter then returns `usage.cost`.
A non-OpenRouter endpoint ignores/omits it, so cost stays `None` and the fallback
applies.

- [ ] **Step 1: Write the failing tests**

Create `python-worker/tests/test_llm_usage.py`:

```python
from app.postprocess import llm_client


def test_usage_log_starts_empty_after_reset():
    llm_client.reset_usage()
    u = llm_client.get_usage()
    assert u.total_tokens == 0
    assert u.actual_cost is None


def test_record_usage_accumulates_tokens():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=None)
    llm_client.record_usage(tokens=250, cost=None)
    u = llm_client.get_usage()
    assert u.total_tokens == 350
    assert u.actual_cost is None


def test_record_usage_sums_actual_cost_when_any_present():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=0.001)
    llm_client.record_usage(tokens=100, cost=0.002)
    u = llm_client.get_usage()
    assert u.total_tokens == 200
    assert round(u.actual_cost, 6) == 0.003


def test_actual_cost_none_if_no_call_reported_cost():
    llm_client.reset_usage()
    llm_client.record_usage(tokens=100, cost=None)
    llm_client.record_usage(tokens=100, cost=0.002)
    u = llm_client.get_usage()
    # Mixed: at least one real cost present → sum the reported ones
    assert round(u.actual_cost, 6) == 0.002


def test_extract_usage_reads_tokens_and_cost_from_response_obj():
    class U:
        total_tokens = 1234
        cost = 0.0042
    class Resp:
        usage = U()
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 1234
    assert cost == 0.0042


def test_extract_usage_handles_missing_cost():
    class U:
        total_tokens = 50
    class Resp:
        usage = U()
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 50
    assert cost is None


def test_extract_usage_handles_missing_usage():
    class Resp:
        usage = None
    tokens, cost = llm_client._extract_usage(Resp())
    assert tokens == 0
    assert cost is None
```

- [ ] **Step 2: Run, expect fail**

Run: `.venv/bin/python -m pytest tests/test_llm_usage.py -q`
Expected: FAIL (`reset_usage`/`record_usage`/`get_usage`/`_extract_usage` undefined).

- [ ] **Step 3: Implement the usage log + capture**

In `python-worker/app/postprocess/llm_client.py`, add after the imports (below `OPENROUTER_BASE_URL`):

```python
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
```

Then, inside `complete_json`, request the cost and record usage. Change the
`create(...)` call + the lines that follow to:

```python
            resp = self._client.chat.completions.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                # OpenRouter returns usage.cost when asked; ignored by others.
                extra_body={"usage": {"include": True}},
            )
            tokens, cost = _extract_usage(resp)
            record_usage(tokens, cost)
            raw = resp.choices[0].message.content or ""
```

- [ ] **Step 4: Run, expect pass**

Run: `.venv/bin/python -m pytest tests/test_llm_usage.py -q`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/postprocess/llm_client.py python-worker/tests/test_llm_usage.py
git commit -m "feat(worker): capture LLM token+cost usage for cost tracking"
```

---

## Task 3: Schema fields on `JobRequest` + `JobResult`

**Files:**
- Modify: `python-worker/app/schemas/models.py`
- Modify: `python-worker/tests/test_schemas.py`

- [ ] **Step 1: Write the failing test**

Add to `python-worker/tests/test_schemas.py` (new test functions; keep existing):

```python
def test_jobrequest_defaults_cost_rate_fields():
    from app.schemas.models import JobRequest
    req = JobRequest(job_id="x", command="transcribe", audio_path="/a.wav")
    assert req.stt_rates_per_min == {}
    assert req.llm_fallback_rate_per_1m is None


def test_jobrequest_accepts_rate_fields():
    from app.schemas.models import JobRequest
    req = JobRequest.model_validate_json(
        '{"job_id":"x","command":"transcribe","audio_path":"/a.wav",'
        '"stt_rates_per_min":{"assemblyai":0.01},"llm_fallback_rate_per_1m":2.5}'
    )
    assert req.stt_rates_per_min["assemblyai"] == 0.01
    assert req.llm_fallback_rate_per_1m == 2.5


def test_jobresult_defaults_cost_fields_none():
    from app.schemas.models import JobResult
    r = JobResult(job_id="x", status="completed")
    assert r.cost_transcription is None
    assert r.cost_processing is None
    assert r.cost_currency == "USD"
    assert r.audio_minutes is None
    assert r.llm_tokens is None
```

- [ ] **Step 2: Run, expect fail**

Run: `.venv/bin/python -m pytest tests/test_schemas.py -k cost -q`
Expected: FAIL (unknown fields).

- [ ] **Step 3: Add the fields**

In `python-worker/app/schemas/models.py`, add to `JobRequest` (after `remote_provider`):

```python
    stt_rates_per_min: dict[str, float] = Field(default_factory=dict)
    llm_fallback_rate_per_1m: float | None = None
```

Add to `JobResult` (after `duration_sec`):

```python
    cost_transcription: float | None = None
    cost_processing: float | None = None
    cost_currency: str = "USD"
    audio_minutes: float | None = None
    llm_tokens: int | None = None
```

(`Field` is already imported in this module.)

- [ ] **Step 4: Run, expect pass**

Run: `.venv/bin/python -m pytest tests/test_schemas.py -k cost -q`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/schemas/models.py python-worker/tests/test_schemas.py
git commit -m "feat(worker): add cost rate inputs + cost outputs to job schemas"
```

---

## Task 4: Compute costs in `_run_pipeline`

**Files:**
- Modify: `python-worker/app/cli.py`
- Create: `python-worker/tests/test_pipeline_cost.py`

Context: `_run_pipeline` knows `duration_sec` (`segments[-1].end`), the engine,
and the provider. Stems = 2 when both `<base>_mic.wav` and `<base>_system.wav`
exist (the stem path in `_transcribe_and_attribute`), else 1. LLM cost is $0 for
local engines; otherwise actual-or-fallback from the usage log.

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_pipeline_cost.py`:

```python
from app.cli import _compute_costs
from app.schemas.models import JobRequest


def _req(**kw):
    base = dict(job_id="x", command="transcribe", audio_path="/tmp/none.wav")
    base.update(kw)
    return JobRequest(**base)


def test_local_engine_is_free(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    req = _req(engine="local_whisper", llm_engine="local_experimental")
    costs = _compute_costs(req, duration_sec=600.0)
    assert costs["cost_transcription"] == 0.0
    assert costs["cost_processing"] == 0.0
    assert round(costs["audio_minutes"], 4) == 10.0


def test_remote_stems_double_transcription(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 2)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    req = _req(engine="remote", remote_provider="assemblyai", llm_engine="claude")
    costs = _compute_costs(req, duration_sec=600.0)
    # 10 min × 0.0035 × 2 stems
    assert round(costs["cost_transcription"], 6) == 0.07


def test_processing_uses_actual_cost(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    llm_client.record_usage(tokens=5000, cost=0.0123)
    req = _req(engine="remote", remote_provider="deepgram", llm_engine="claude")
    costs = _compute_costs(req, duration_sec=60.0)
    assert costs["cost_processing"] == 0.0123
    assert costs["llm_tokens"] == 5000


def test_processing_fallback_when_no_actual(monkeypatch):
    import app.cli as cli
    monkeypatch.setattr(cli, "_count_stems", lambda path: 1)
    from app.postprocess import llm_client
    llm_client.reset_usage()
    llm_client.record_usage(tokens=2_000_000, cost=None)
    req = _req(engine="remote", remote_provider="deepgram",
               llm_engine="claude", llm_fallback_rate_per_1m=3.0)
    costs = _compute_costs(req, duration_sec=60.0)
    assert round(costs["cost_processing"], 6) == 6.0
```

- [ ] **Step 2: Run, expect fail**

Run: `.venv/bin/python -m pytest tests/test_pipeline_cost.py -q`
Expected: FAIL (`_compute_costs`/`_count_stems` undefined).

- [ ] **Step 3: Implement the helpers + wire into the pipeline**

In `python-worker/app/cli.py`, add these imports near the top (with the other `app.*` imports):

```python
from app.postprocess import pricing
from app.postprocess.llm_client import get_usage, reset_usage
```

Add two module-level helpers (place them just above `_run_pipeline`):

```python
def _count_stems(audio_path: str) -> int:
    """2 when mic+system stems exist (both transcribed), else 1."""
    base = os.path.splitext(audio_path)[0]
    mic = f"{base}_mic.wav"
    system = f"{base}_system.wav"
    return 2 if os.path.exists(mic) and os.path.exists(system) else 1


def _compute_costs(request: JobRequest, duration_sec: float | None) -> dict:
    """USD cost breakdown for this job, plus raw usage for later recompute."""
    minutes = (duration_sec or 0.0) / 60.0
    provider = request.remote_provider if request.engine == "remote" else "local_whisper"
    rates = pricing.merge_rates(request.stt_rates_per_min)
    cost_t = pricing.transcription_cost(
        minutes, provider, _count_stems(request.audio_path), rates
    )

    usage = get_usage()
    if request.llm_engine.startswith("local"):
        cost_p = 0.0
    else:
        fallback = request.llm_fallback_rate_per_1m
        if fallback is None:
            fallback = pricing.DEFAULT_LLM_FALLBACK_RATE_PER_1M
        cost_p = pricing.processing_cost(usage.actual_cost, usage.total_tokens, fallback)

    return {
        "cost_transcription": round(cost_t, 6),
        "cost_processing": round(cost_p, 6),
        "cost_currency": "USD",
        "audio_minutes": round(minutes, 4),
        "llm_tokens": usage.total_tokens,
    }
```

At the very start of `_run_pipeline` (right after `warnings: list[str] = []`), reset the usage log so each job starts clean:

```python
    reset_usage()
```

In `_run_pipeline`, where the final `JobResult(...)` is built (the success path
that already passes `duration_sec=duration_sec`), spread the cost dict into it.
Change that return to:

```python
    costs = _compute_costs(request, duration_sec)
    return JobResult(
        job_id=request.job_id,
        status="completed",
        raw_transcript_path=raw_path,
        markdown_path=md_path,
        analysis_path=analysis_path,
        duration_sec=duration_sec,
        warnings=warnings,
        **costs,
    )
```

- [ ] **Step 4: Run, expect pass**

Run: `.venv/bin/python -m pytest tests/test_pipeline_cost.py -q`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full worker suite (no regressions)**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add python-worker/app/cli.py python-worker/tests/test_pipeline_cost.py
git commit -m "feat(worker): compute per-session transcription + processing cost"
```

---

# PHASE B — Swift (macOS app)

## Task 5: Migration v5 + `Session` cost fields

**Files:**
- Modify: `macos-app/Sources/Persistence/Database.swift`
- Modify: `macos-app/Sources/Session/SessionManager.swift` (the `Session` struct)
- Modify: `macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift`

- [ ] **Step 1: Write the failing migration test**

Add to `macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift` (new test; match the file's existing style for opening an in-memory/temp `AppDatabase`):

```swift
func testV5AddsCostColumns() throws {
    let db = try makeTestDatabase()   // existing helper used by other tests
    let columns = try db.dbPool.read { d in
        try Row.fetchAll(d, sql: "PRAGMA table_info(session)").map { $0["name"] as String }
    }
    XCTAssertTrue(columns.contains("cost_transcription"))
    XCTAssertTrue(columns.contains("cost_processing"))
    XCTAssertTrue(columns.contains("cost_currency"))
}
```

If `DatabaseMigrationTests.swift` has no `makeTestDatabase()` helper, use the same database-construction pattern the other tests in that file already use to obtain an `AppDatabase`.

- [ ] **Step 2: Run, expect fail**

Run: `cd macos-app && swift test --filter DatabaseMigrationTests`
Expected: FAIL (columns absent).

- [ ] **Step 3: Register migration v5**

In `macos-app/Sources/Persistence/Database.swift`, immediately after the
`migrator.registerMigration("v4_notesLanguage") { ... }` block and before
`return migrator`, add:

```swift
        migrator.registerMigration("v5_costColumns") { db in
            try db.alter(table: "session") { t in
                t.add(column: "cost_transcription", .double)
                t.add(column: "cost_processing", .double)
                t.add(column: "cost_currency", .text)
            }
        }
```

- [ ] **Step 4: Add fields to the `Session` struct**

In `macos-app/Sources/Session/SessionManager.swift`, in `struct Session`, add
after `var analysisPath: String? = nil`:

```swift
    var costTranscription: Double? = nil
    var costProcessing: Double? = nil
    var costCurrency: String? = nil
```

And in its `CodingKeys`, after `case analysisPath = "analysis_path"`:

```swift
        case costTranscription = "cost_transcription"
        case costProcessing = "cost_processing"
        case costCurrency = "cost_currency"
```

- [ ] **Step 5: Run, expect pass**

Run: `cd macos-app && swift test --filter DatabaseMigrationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos-app/Sources/Persistence/Database.swift macos-app/Sources/Session/SessionManager.swift macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift
git commit -m "feat(app): migration v5 — per-session cost columns"
```

---

## Task 6: Settings rate fields + load + reset

**Files:**
- Modify: `macos-app/Sources/Settings/SettingsManager.swift`
- Create: `macos-app/Tests/CallCaptureTests/PricingSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/PricingSettingsTests.swift`:

```swift
import XCTest
@testable import CallCapture

@available(macOS 14.2, *)
final class PricingSettingsTests: XCTestCase {
    func testDefaultRatesSeeded() {
        let s = makeSettings()   // construct SettingsManager on a temp DB (see note)
        XCTAssertEqual(s.sttRateAssemblyAI, 0.0035, accuracy: 1e-9)
        XCTAssertEqual(s.sttRateDeepgram, 0.0043, accuracy: 1e-9)
        XCTAssertEqual(s.sttRateOpenAI, 0.0060, accuracy: 1e-9)
        XCTAssertEqual(s.sttRateGroq, 0.0007, accuracy: 1e-9)
        XCTAssertEqual(s.llmFallbackRatePer1M, 3.00, accuracy: 1e-9)
    }

    func testRatePersistsAndReloads() {
        let s = makeSettings()
        s.sttRateAssemblyAI = 0.01
        let reloaded = reloadSettings(s)   // new SettingsManager on the same DB
        XCTAssertEqual(reloaded.sttRateAssemblyAI, 0.01, accuracy: 1e-9)
    }

    func testResetRestoresDefaults() {
        let s = makeSettings()
        s.sttRateAssemblyAI = 0.99
        s.resetPricingToDefaults()
        XCTAssertEqual(s.sttRateAssemblyAI, 0.0035, accuracy: 1e-9)
    }
}
```

Note: use the same temp-`AppDatabase` construction pattern the existing
`SessionManager*Tests` use to build a `SettingsManager`. Add the two small
helpers (`makeSettings`, `reloadSettings`) at the bottom of this test file using
that pattern.

- [ ] **Step 2: Run, expect fail**

Run: `cd macos-app && swift test --filter PricingSettingsTests`
Expected: FAIL (rate properties / `resetPricingToDefaults` undefined).

- [ ] **Step 3: Add rate fields + reset + load**

In `macos-app/Sources/Settings/SettingsManager.swift`, add these properties
(after `var localLLMBaseURL` or near the other persisted settings):

```swift
    // MARK: - Pricing (USD). Defaults mirror python-worker/app/postprocess/pricing.py.
    var sttRateAssemblyAI: Double = 0.0035 { didSet { persist("stt_rate_assemblyai", String(sttRateAssemblyAI)) } }
    var sttRateDeepgram: Double = 0.0043 { didSet { persist("stt_rate_deepgram", String(sttRateDeepgram)) } }
    var sttRateOpenAI: Double = 0.0060 { didSet { persist("stt_rate_openai", String(sttRateOpenAI)) } }
    var sttRateGroq: Double = 0.0007 { didSet { persist("stt_rate_groq", String(sttRateGroq)) } }
    var llmFallbackRatePer1M: Double = 3.00 { didSet { persist("llm_fallback_rate_per_1m", String(llmFallbackRatePer1M)) } }

    /// STT $/min keyed by the worker's provider names, for the JobRequest.
    var sttRatesPerMin: [String: Double] {
        [
            "assemblyai": sttRateAssemblyAI,
            "deepgram": sttRateDeepgram,
            "openai": sttRateOpenAI,
            "groq": sttRateGroq,
            "local_whisper": 0.0,
        ]
    }

    func resetPricingToDefaults() {
        sttRateAssemblyAI = 0.0035
        sttRateDeepgram = 0.0043
        sttRateOpenAI = 0.0060
        sttRateGroq = 0.0007
        llmFallbackRatePer1M = 3.00
    }
```

In `loadAll()`, add (after the existing `if let raw = rows["local_llm_base_url"]...` line):

```swift
        if let raw = rows["stt_rate_assemblyai"], let v = Double(raw) { sttRateAssemblyAI = v }
        if let raw = rows["stt_rate_deepgram"], let v = Double(raw) { sttRateDeepgram = v }
        if let raw = rows["stt_rate_openai"], let v = Double(raw) { sttRateOpenAI = v }
        if let raw = rows["stt_rate_groq"], let v = Double(raw) { sttRateGroq = v }
        if let raw = rows["llm_fallback_rate_per_1m"], let v = Double(raw) { llmFallbackRatePer1M = v }
```

- [ ] **Step 4: Run, expect pass**

Run: `cd macos-app && swift test --filter PricingSettingsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Settings/SettingsManager.swift macos-app/Tests/CallCaptureTests/PricingSettingsTests.swift
git commit -m "feat(app): editable pricing rates in SettingsManager"
```

---

## Task 7: Pricing section in `SettingsView`

**Files:**
- Modify: `macos-app/Sources/Settings/SettingsView.swift`

- [ ] **Step 1: Add the Pricing section**

In `macos-app/Sources/Settings/SettingsView.swift`, add a new section (follow the
existing section style — `Section`/`GroupBox` as used elsewhere in the file).
Bind a `@Bindable var settings` (the view already holds a `SettingsManager`; use
`@Bindable` if needed for the bindings). Insert this section near the other config
sections:

```swift
        Section("Pricing (USD)") {
            LabeledContent("AssemblyAI $/min") {
                TextField("0.0035", value: $settings.sttRateAssemblyAI, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Deepgram $/min") {
                TextField("0.0043", value: $settings.sttRateDeepgram, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("OpenAI $/min") {
                TextField("0.0060", value: $settings.sttRateOpenAI, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Groq $/min") {
                TextField("0.0007", value: $settings.sttRateGroq, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Local Whisper") { Text("$0.00").foregroundStyle(.secondary) }
            LabeledContent("LLM fallback $/1M tokens") {
                TextField("3.00", value: $settings.llmFallbackRatePer1M, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            Text("OpenRouter reports actual cost; the fallback rate is used only when it can't.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset to defaults") { settings.resetPricingToDefaults() }
        }
```

If the file uses a `Form`/`TabView` layout, place the section consistently with the
others. If `settings` is not already `@Bindable`, change its declaration in this
view from `let settings: SettingsManager` / `var settings` to
`@Bindable var settings: SettingsManager` (or use `@Bindable var settings = settings`
inside `body`) so the `$settings.…` bindings compile.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd macos-app && swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/Settings/SettingsView.swift
git commit -m "feat(app): Pricing settings section with editable rates + reset"
```

---

## Task 8: Flow rates into `JobRequest`, decode cost from `JobResult`

**Files:**
- Modify: `macos-app/Sources/Bridge/Models.swift`

- [ ] **Step 1: Add rate fields to `JobRequest` + decode cost on `JobResult`**

In `macos-app/Sources/Bridge/Models.swift`, add to `struct JobRequest` (after `notesLanguage`):

```swift
    let sttRatesPerMin: [String: Double]
    let llmFallbackRatePer1M: Double
```

Add to its `CodingKeys`:

```swift
        case sttRatesPerMin = "stt_rates_per_min"
        case llmFallbackRatePer1M = "llm_fallback_rate_per_1m"
```

Every `JobRequest(...)` initializer in this file must now pass these. For the two
static factories that aren't config-driven (`transcribe(audioPath:…)` and
`prepareEmotion()`), pass empty/default values:

```swift
            sttRatesPerMin: [:],
            llmFallbackRatePer1M: 3.0
```

In `transcribe(session:settings:)`, pass the settings-derived values:

```swift
            sttRatesPerMin: settings.sttRatesPerMin,
            llmFallbackRatePer1M: settings.llmFallbackRatePer1M
```

Add to `struct JobResult` (after `durationSec`):

```swift
    let costTranscription: Double?
    let costProcessing: Double?
    let costCurrency: String?
```

Add to `JobResult` `CodingKeys`:

```swift
        case costTranscription = "cost_transcription"
        case costProcessing = "cost_processing"
        case costCurrency = "cost_currency"
```

Update `JobResult.error(jobId:message:)` to pass `costTranscription: nil,
costProcessing: nil, costCurrency: nil` so it still compiles.

- [ ] **Step 2: Build**

Run: `cd macos-app && swift build`
Expected: Build complete. (Fix any other `JobRequest(`/`JobResult(` call sites the
compiler flags by passing the new fields.)

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/Bridge/Models.swift
git commit -m "feat(app): pass pricing rates to worker, decode cost from result"
```

---

## Task 9: Persist cost from `JobResult` to the session row

**Files:**
- Modify: `macos-app/Sources/Session/SessionManager.swift`

- [ ] **Step 1: Persist the cost fields**

Find the method in `SessionManager.swift` that updates a `Session` from a
completed `JobResult` (it already writes `transcriptRawPath`, `transcriptMarkdownPath`,
`analysisPath`, `durationSec`, and `status` after transcription — search for where
`result.durationSec` / `result.markdownPath` are read). In that method, set the
cost fields on the `Session` (or the `UPDATE`) from the result before saving:

```swift
        session.costTranscription = result.costTranscription
        session.costProcessing = result.costProcessing
        session.costCurrency = result.costCurrency
```

If that method writes via a raw `UPDATE` SQL rather than saving the `Session`
record, add the three columns to the `SET` clause and bind
`result.costTranscription`, `result.costProcessing`, `result.costCurrency`.
The `Session` struct's GRDB persistence (via its `Codable`/`CodingKeys` → column
names `cost_transcription` etc.) handles saves automatically if it uses
`session.save(db)`.

- [ ] **Step 2: Build**

Run: `cd macos-app && swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/Session/SessionManager.swift
git commit -m "feat(app): persist transcription+processing cost on the session"
```

---

## Task 10: Display — detail breakdown + list badge + formatting

**Files:**
- Modify: `macos-app/Sources/UI/SessionDetailView.swift`
- Modify: `macos-app/Sources/UI/SessionRowView.swift`
- Create: `macos-app/Tests/CallCaptureTests/CostFormatTests.swift`

- [ ] **Step 1: Write the failing formatter test**

Create `macos-app/Tests/CallCaptureTests/CostFormatTests.swift`:

```swift
import XCTest
@testable import CallCapture

@available(macOS 14.2, *)
final class CostFormatTests: XCTestCase {
    func testFormatsToFourDecimals() {
        XCTAssertEqual(CostFormat.usd(0.0123), "$0.0123")
        XCTAssertEqual(CostFormat.usd(0.07), "$0.0700")
    }

    func testZeroRendersAsZero() {
        XCTAssertEqual(CostFormat.usd(0.0), "$0.0000")
    }

    func testNilRendersDash() {
        XCTAssertEqual(CostFormat.usd(nil), "—")
    }

    func testTotalSumsParts() {
        XCTAssertEqual(CostFormat.total(0.07, 0.0123), 0.0823, accuracy: 1e-9)
        XCTAssertNil(CostFormat.total(nil, nil))
    }
}
```

- [ ] **Step 2: Run, expect fail**

Run: `cd macos-app && swift test --filter CostFormatTests`
Expected: FAIL (`CostFormat` undefined).

- [ ] **Step 3: Add the `CostFormat` helper**

Create the helper inside `macos-app/Sources/UI/SessionDetailView.swift` (top-level,
file scope), so both views can use it:

```swift
/// USD cost formatting for the cost UI. 4 decimals (sub-cent calls are common).
enum CostFormat {
    static func usd(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.4f", value)
    }

    /// Sum of the two parts, or nil if both are nil.
    static func total(_ a: Double?, _ b: Double?) -> Double? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `cd macos-app && swift test --filter CostFormatTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Add the breakdown row to `SessionDetailView`**

In `SessionDetailView.swift`, add a cost row inside the metadata/details area
(e.g. after the `Duration` row in `metadataSection`), reading from `current`:

```swift
                if current.costTranscription != nil || current.costProcessing != nil {
                    detailRow(
                        "Cost",
                        "Transcription \(CostFormat.usd(current.costTranscription)) · "
                        + "Processing \(CostFormat.usd(current.costProcessing)) · "
                        + "Total \(CostFormat.usd(CostFormat.total(current.costTranscription, current.costProcessing)))"
                    )
                }
```

(`detailRow(_:_:)` already exists in this file.)

- [ ] **Step 6: Add the total badge to `SessionRowView`**

In `macos-app/Sources/UI/SessionRowView.swift`, show a small total when present.
Add to the row's trailing content (next to the status badge / date):

```swift
            if let total = CostFormat.total(session.costTranscription, session.costProcessing) {
                Text(CostFormat.usd(total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 7: Build + run swift tests**

Run: `cd macos-app && swift build && swift test`
Expected: Build complete; all tests pass.

- [ ] **Step 8: Commit**

```bash
git add macos-app/Sources/UI/SessionDetailView.swift macos-app/Sources/UI/SessionRowView.swift macos-app/Tests/CallCaptureTests/CostFormatTests.swift
git commit -m "feat(app): show cost breakdown in detail + total badge in list"
```

---

## Task 11: End-to-end verification

**Files:** none (manual verification)

- [ ] **Step 1: Full worker suite**

Run: `cd python-worker && .venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 2: Full Swift suite + build**

Run: `cd macos-app && swift build && swift test`
Expected: all pass.

- [ ] **Step 3: Launch + record a short remote-engine session, confirm UI**

Run: `./run-dev.sh`, record a brief call with a **remote** engine + OpenRouter LLM,
let it process, open the session. Expected: the detail view shows a
`Transcription $X · Processing $Y · Total $Z` row and the list row shows the total
badge. A `local_whisper` + local LLM session shows `$0.0000`.

- [ ] **Step 4: Commit any fixes uncovered, then done.**

---

## Self-Review (completed)

- **Spec coverage:** cost model + stem doubling (T4), defaults-in-code + merge (T1), LLM actual-vs-fallback + usage capture (T2, T4), schema rate inputs/cost outputs (T3), migration v5 (T5), editable Settings rates + reset (T6, T7), rates→worker + cost decode (T8), persistence (T9), detail breakdown + list badge + 4-dp formatting + `—` for nil (T10). Testing §7 mapped across T1–T10. New-sessions-only and raw-usage-stored are inherent (no backfill task; `audio_minutes`/`llm_tokens` returned in `JobResult` per T3 — persisted columns deferred per spec §6, the two cost columns + currency are persisted in T5/T9).
- **Placeholders:** none — every code step is concrete.
- **Type consistency:** worker provider keys (`assemblyai/deepgram/openai/groq/local_whisper`) match `sttRatesPerMin` keys in T6/T8; `cost_transcription/cost_processing/cost_currency` snake_case consistent across schema (T3), DB columns (T5), `Session`/`JobResult` CodingKeys (T5/T8); `CostFormat.usd/total` used identically in T10.

## Notes for the implementer

- Raw usage `audio_minutes`/`llm_tokens` are returned in `JobResult` (T3) but only the
  two cost columns + currency are persisted (spec §6 default). If you later want to
  recompute, add columns in a follow-up migration — out of scope here.
- The worker is one-job-per-process, so the module-level usage log (T2) needs no
  locking; `reset_usage()` at pipeline start (T4) guards re-use.
- If `swift test` helpers for a temp DB differ from what T5/T6 assume, mirror the exact
  construction the existing `SessionManagerDeleteTests`/`DatabaseMigrationTests` use.
