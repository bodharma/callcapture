# Live Model Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick the live-notes and final-notes models from OpenRouter's current list with live prices, independent Artificial Analysis scores and per-hour cost estimates, and make every network feature degrade visibly when offline.

**Architecture:** A `ModelCatalogService` fetches `/api/v1/models` and `/api/v1/benchmarks?source=artificial-analysis`, joins them and caches a snapshot on disk; pure helpers compute hourly cost and score-derived tags; Settings gets a table picker per role. A `ConnectivityMonitor` (NWPathMonitor) gates network controls; the worker learns "offline" via `LLM_OFFLINE=1` and reports AI-notes fallbacks as job warnings that the session stores and shows.

**Tech Stack:** Swift 5.9/SwiftUI, URLSession, Network framework, GRDB, Swift Testing; Python worker (pytest). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-26-live-model-catalog-design.md`

## Global Constraints

- macOS 14.2; no new dependencies; OpenRouter key only via the existing `CredentialStore`/Keychain.
- Data API quota: 30 req/min, 500/day. Refetch each list at most once per 24 h unless the user presses Refresh.
- Attribution wherever scores appear, verbatim: `Source: Artificial Analysis (artificialanalysis.ai) via OpenRouter (openrouter.ai/rankings)` (use `meta.citation` when present).
- Estimates always carry "≈"; unscored models show "—" with help text "No independent score".
- Never switch a user's model or provider automatically (retired-slug migration only for slugs persisted before this change).
- Recording, local Whisper, live local speech, manual notes, playback, search and disk exports never depend on the network.
- Tests use fake transports; no real network or keys in tests (see `memory: ci-test-constraints`).

## Review Focus

1. OpenRouter lists routers/free models with price `"-1"`, `"0"` or missing fields → negative/unparseable prices are excluded; `$0` models show "free". Test in Task 1.
2. Benchmarks request fails (no key, 401, 429, offline) → model list and prices still load, scores show "—" with one inline reason; previous scores are kept. Test in Task 1.
3. Corrupt or unreadable cache file → treated as "no cache", refetch, no crash. Test in Task 1.
4. Network drops mid-meeting → live-notes request fails with an offline message, transcript continues, no retry storm. Test in Task 5.
5. Selected model no longer listed → Settings warns, live notes refuse to start with that reason instead of sending 404 requests. Test in Task 5.

## Precondition

Three verified-but-uncommitted fixes are in the working tree (retired-slug map + migration, live silence gate/`[BLANK_AUDIO]` filter, 404 message). Commit them separately, after the user confirms the live test, before Task 1.

---

### Task 1: Model catalog service (fetch, join, cache)

**Files:**
- Create: `macos-app/Sources/Settings/ModelCatalog.swift`
- Create: `macos-app/Tests/CallCaptureTests/ModelCatalogTests.swift`
- Create: `macos-app/Tests/CallCaptureTests/Fixtures/openrouter-models.json`, `.../openrouter-benchmarks-aa.json` (benchmarks fixture = the documented sample from the OpenRouter Data API page; replace with a real capture in Task 8)

**Interfaces:**
- Produces:
  - `struct ModelScores: Codable, Equatable, Sendable { let intelligence: Double?; let multilingual: Double?; let strategyAndOps: Double? }`
  - `struct CatalogModel: Codable, Equatable, Sendable, Identifiable { let id: String; let canonicalSlug: String?; let name: String; let promptPricePerToken: Double; let completionPricePerToken: Double; let contextLength: Int; let supportsJSON: Bool; var scores: ModelScores? }`
  - `struct ModelCatalogSnapshot: Codable, Equatable, Sendable { var models: [CatalogModel]; var modelsFetchedAt: Date; var scoresFetchedAt: Date?; var scoresCitation: String?; var scoresProblem: String?; func model(id: String) -> CatalogModel? }`
  - `struct ModelCatalogService: Sendable` with `typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`, `init(cacheURL: URL, transport: @escaping Transport = ModelCatalogService.urlSession, now: @escaping @Sendable () -> Date = Date.init)`, `func cached() -> ModelCatalogSnapshot?`, `func refresh(apiKey: String, force: Bool) async throws -> ModelCatalogSnapshot`, `static let maxAge: TimeInterval = 86_400`
  - `enum ModelCatalogError: LocalizedError { case offline, http(Int), invalidResponse }`

- [ ] **Step 1: Write failing tests** (`@Suite("Model catalog")`), all with a counting fake transport:
  - `decodesModels`: fixture → `supportsJSON == true` when `supported_parameters` has `response_format` or `structured_outputs`; prices parsed from strings; a `"-1"` priced router and a model missing `pricing` are absent; a `"0"` model is present with price 0.
  - `joinsScores`: AA `model_permaslug` equal to a model's `canonical_slug` (and, second, to its `id`) sets `scores`; an unmatched permaslug sets nothing; `scoresCitation == meta.citation`.
  - `freshCacheSkipsNetwork`: snapshot saved 1 h ago, `refresh(force: false)` makes 0 transport calls; `force: true` makes 2.
  - `scoresFailureKeepsModels`: benchmarks returns 401 → snapshot has models, previous scores kept (or nil on first fetch), `scoresProblem` set to "Scores need a valid OpenRouter key."; 429 → "Scores are rate-limited; try later.".
  - `modelsFailureThrows`: `/models` throws `URLError(.notConnectedToInternet)` → `refresh` throws `.offline`, cache file unchanged.
  - `corruptCacheIsIgnored`: garbage bytes at `cacheURL` → `cached() == nil`.
- [ ] **Step 2:** `cd macos-app && swift test --filter ModelCatalogTests` → FAIL (types missing).
- [ ] **Step 3: Implement** in `ModelCatalog.swift`. `/models` request has no auth header; benchmarks request sends `Authorization: Bearer <key>` and is skipped (problem "Scores need an OpenRouter key.") when the key is empty. Cache writes are atomic (`.atomic`) as JSON with ISO-8601 dates.
- [ ] **Step 4:** same command → PASS.
- [ ] **Step 5: Commit** `feat(settings): live OpenRouter model catalog with cached scores`.

### Task 2: Hourly cost estimate and score-derived tags

**Files:**
- Create: `macos-app/Sources/Settings/ModelRanking.swift`
- Create: `macos-app/Tests/CallCaptureTests/ModelRankingTests.swift`

**Interfaces:**
- Consumes: `CatalogModel` (Task 1).
- Produces: `enum LLMRole: String, CaseIterable, Sendable { case live, final }`; `enum ModelCostEstimate { static let finalInputTokensPerHour: Double; static let finalOutputTokensPerHour: Double; static let liveRequestsPerHour: Double; static let liveInputTokensPerRequest: Double; static let liveOutputTokensPerRequest: Double; static func hourlyUSD(_ model: CatalogModel, role: LLMRole) -> Double; static let explanation: String }`; `enum ModelTags { static func tags(for model: CatalogModel, among models: [CatalogModel]) -> [String]; static let rules: String }`.

- [ ] **Step 1: Sanity-check the token model.** Measure `ConversationTopicService` instructions + a 10-topic context and `insights.py` prompt + a 1-hour transcript (~9,000 words) at ~4 chars/token. Start from the spec's values (final 13,000 in / 2,000 out per hour; live 450 req/h × 3,000 in / 800 out) and adjust only if the measurement differs by more than 2×; record the measured numbers in a comment.
- [ ] **Step 2: Write failing tests:** `hourlyUSD` for a model at $2/M in, $10/M out equals `13000*2e-6 + 2000*10e-6` (final) and `450*(3000*2e-6 + 800*10e-6)` (live) using the constants (assert via the constants, not literals, so tuning stays green); tags over 8 synthetic models: top-quartile (nearest-rank 75th percentile, ties included) Multilingual → `"Strong multilingual"`, Intelligence → `"Highest quality"`, cheapest-quartile live cost among `supportsJSON` models → `"Budget"`; a model with nil scores gets no score tags; a single scored model gets no quartile tags (needs ≥ 4 values).
- [ ] **Step 3:** `swift test --filter ModelRankingTests` → FAIL.
- [ ] **Step 4: Implement** `ModelRanking.swift`; `explanation`/`rules` are user-facing one-liners shown as help text.
- [ ] **Step 5:** PASS, then commit `feat(settings): hourly cost estimate and score-based model tags`.

### Task 3: Settings — live, final and local model selections

**Files:**
- Modify: `macos-app/Sources/Settings/SettingsManager.swift`, `macos-app/Sources/App/CallCaptureApp.swift` (LLM_MODEL env ~line 268, live configuration ~line 432), `macos-app/Sources/App/ContentView.swift:98-100`
- Modify: `macos-app/Sources/Settings/LLMModelCatalog.swift` (keep only `defaultSlug`, `retired`, `current(_:)`; delete curated lists, `option(for:)`, `custom`)
- Modify: `macos-app/Tests/CallCaptureTests/LLMModelCatalogTests.swift` (drop curated-list tests; keep retired/current/migration tests)
- Test: `macos-app/Tests/CallCaptureTests/ModelSelectionSettingsTests.swift`

**Interfaces:**
- Consumes: `LLMRole` (Task 2).
- Produces: `SettingsManager.liveLLMModel: String` (key `live_llm_model`), `SettingsManager.localLLMModel: String` (key `local_llm_model`), `func model(for role: LLMRole) -> String` (Local provider → `localLLMModel` for both roles; OpenRouter → `liveLLMModel` / `llmModel`).

- [ ] **Step 1: Write failing tests** (temp DB + `InMemoryCredentialStore`): first load with only `llm_model` persisted copies it into `live_llm_model` and persists it; later changing `llmModel` leaves `liveLLMModel` unchanged after reload; with provider `.local` and no `local_llm_model` row, `localLLMModel` is copied from `llm_model` once; switching provider never changes `llmModel`/`liveLLMModel`/`localLLMModel`; `model(for:)` returns the right value per provider/role; a retired persisted `live_llm_model` is migrated via `LLMModelCatalog.current`.
- [ ] **Step 2:** `swift test --filter ModelSelectionSettingsTests` → FAIL.
- [ ] **Step 3: Implement**; the copy-once writes happen after `isLoading = false`. Replace `settingsManager.llmModel` with `model(for: .final)` for `LLM_MODEL` and `model(for: .live)` for the live configuration and the menu caption.
- [ ] **Step 4:** full `swift test` → PASS (the old picker row still compiles until Task 4 replaces it; delete it there).
- [ ] **Step 5: Commit** `feat(settings): separate live, final and local model selections`.

### Task 4: Model picker UI

**Files:**
- Create: `macos-app/Sources/Settings/ModelPickerView.swift`
- Modify: `macos-app/Sources/Settings/SettingsView.swift` (Post-Processing section ~lines 80-130; remove `LLMModelPickerRow`)
- Modify: `macos-app/Sources/App/CallCaptureApp.swift` (AppModel: `let modelCatalog: ModelCatalogService` with cache at `<Application Support>/CallCapture/model-catalog.json`, `var catalogSnapshot: ModelCatalogSnapshot?`, `var catalogProblem: String?`, `func refreshModelCatalog(force: Bool) async`)

**Interfaces:**
- Consumes: Tasks 1-3; `ConnectivityMonitor.isOnline` arrives in Task 6 — until then pass `isOnline: true`.
- Produces: `struct ModelPickerView: View { let role: LLMRole; @Binding var selection: String; let snapshot: ModelCatalogSnapshot?; let isOnline: Bool; let refresh: () -> Void }`.

- [ ] **Step 1: Build the view.** OpenRouter provider: one row per role showing the selected model's name and `≈ $x / meeting hour`, opening a sheet with a sortable `Table` (Model, Live/h, Final/h, Intelligence, Multilingual, Strategy & Ops, Context, Best for), a search field, a "Works for live notes (JSON)" toggle (on by default for the live role), the citation footer, the `ModelCostEstimate.explanation` help, and "Model list as of <date> · Refresh". Selected slug absent from the snapshot → inline warning "<slug> is no longer offered by OpenRouter. Choose another model." No snapshot and offline → "Needs internet to load the model list" with the current selection shown. Local provider: the existing free-text field bound to `localLLMModel`. Settings `onAppear` calls `refreshModelCatalog(force: false)`.
- [ ] **Step 2:** `swift build` → succeeds; `swift test` → PASS.
- [ ] **Step 3: Commit** `feat(settings): live model picker with prices and scores`.

### Task 5: Live notes — usage accounting and model guard

**Files:**
- Modify: `macos-app/Sources/Live/ConversationTopicService.swift`, `macos-app/Sources/Live/ConversationMap.swift`, `macos-app/Sources/Live/LiveMeetingWorkspace.swift`, `macos-app/Sources/App/CallCaptureApp.swift` (live start)
- Test: `macos-app/Tests/CallCaptureTests/ConversationTopicServiceTests.swift`

**Interfaces:**
- Consumes: `ModelCatalogSnapshot.model(id:)` (Task 1), `model(for: .live)` (Task 3).
- Produces: `struct LiveNotesUsage: Codable, Equatable, Sendable { var requests = 0; var promptTokens = 0; var completionTokens = 0; var reportedCostUSD = 0.0; var unpricedRequests = 0 }`; `ConversationDocument.liveNotesUsage: LiveNotesUsage` (decodes as empty when absent in old `_live.json`); `ConversationTopicService.analyze(...)` returns `(update: ConversationTopicUpdate, usage: LiveNotesUsage)` for one request.

- [ ] **Step 1: Write failing tests:** request body contains `"usage": {"include": true}`; a response with `usage {prompt_tokens: 1200, completion_tokens: 300, cost: 0.0042}` adds 1 request/1200/300/0.0042 to the document; a response without `cost` increments `unpricedRequests`; old `_live.json` without the field loads; transport throwing `URLError(.notConnectedToInternet)` sets the error "Automatic notes paused: offline. Transcript and manual notes continue." and makes no further request for those turns (Review Focus 4); starting with a live model absent from a non-nil snapshot sets the configuration problem "<slug> is no longer offered by OpenRouter. Choose another live notes model in Settings." and sends nothing (Review Focus 5).
- [ ] **Step 2:** `swift test --filter ConversationTopicServiceTests` → FAIL.
- [ ] **Step 3: Implement**; the workspace shows "Live notes so far: ≈ $0.0042 · 1 request" (or "N requests, cost not reported").
- [ ] **Step 4:** PASS; full `swift test` PASS.
- [ ] **Step 5: Commit** `feat(live): track live-notes spend and refuse unlisted models`.

### Task 6: Connectivity monitor and offline gating

**Files:**
- Create: `macos-app/Sources/App/ConnectivityMonitor.swift`
- Modify: `macos-app/Sources/App/CallCaptureApp.swift` (AppModel owns `let connectivity = ConnectivityMonitor()`; `stopRecording` auto-process; live start), `ContentView.swift`, `UI/SessionDetailView.swift`, `Settings/SettingsView.swift`, `Settings/ModelPickerView.swift`
- Test: `macos-app/Tests/CallCaptureTests/ConnectivityGatingTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class ConnectivityMonitor { private(set) var isOnline: Bool; init(startMonitoring: Bool = true); func setOnline(_ online: Bool) }` and `static let offlineReason = "Offline — this needs an internet connection."`; `AppModel.networkBlockReason(engine: String) -> String?` (non-nil only when offline and `engine == "remote"`).

- [ ] **Step 1: Write failing tests:** `networkBlockReason` returns the reason for remote+offline, nil for local or online; with `setOnline(false)`, `AppModel.autoProcessDecision(for:)` (a pure helper returning `.transcribe`, `.transcribeOffline` or `.wait(reason)`) returns `.wait` for a remote-engine session, `.transcribeOffline` for local Whisper with the OpenRouter LLM provider, and `.transcribe` for local Whisper with the Local LLM provider (a local LLM server needs no internet); online always returns `.transcribe`.
- [ ] **Step 2:** `swift test --filter ConnectivityGatingTests` → FAIL.
- [ ] **Step 3: Implement** the monitor (NWPathMonitor on a private queue, publishing on the main actor) and gating: disabled controls with the reason as inline caption text (not colour-only) for Automatic memos, Download live model, Transcribe/Re-process/Retry on remote sessions, catalog Refresh and OpenRouter key test; `.wait` keeps the session `completed` and sets status "Saved. Cloud transcription waits for internet — or choose local Whisper and press Transcribe."; live start offline with memos on → memos off plus `markGap("Automatic notes off: offline. Local transcript and manual notes continue.")`; `.transcribeOffline` adds `LLM_OFFLINE=1` to the job env (never set for the Local provider). Manual Transcribe/Re-process uses the same decision.
- [ ] **Step 4:** PASS; `swift build` succeeds.
- [ ] **Step 5: Commit** `feat(app): offline-aware controls and auto-process`.

### Task 7: Visible AI-notes fallbacks (worker + session warnings)

**Files:**
- Modify: `python-worker/app/postprocess/llm_env.py` (`LlmEnv.offline: bool` from `LLM_OFFLINE == "1"`), `python-worker/app/analyze/insights.py`, `python-worker/app/analyze/sentiment.py`, `python-worker/app/cli.py` (`_run_pipeline` passes its `warnings` list)
- Modify: `macos-app/Sources/Persistence/Database.swift` (migration `v6_sessionWarning`: `session.warning_message TEXT`), `Persistence/SessionRecord.swift`, `Session/SessionManager.swift` (`Session.warningMessage: String?`, `func updateSessionWarning(id: String, message: String?)`), `App/CallCaptureApp.swift` (store `result.warnings.joined(separator: "\n")` or nil after a successful job), `UI/SessionDetailView.swift` (a "Warnings" box with a triangle icon and text)
- Test: `python-worker/tests/test_ai_notes_warnings.py`, `macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift`, `SessionManagerWarningTests.swift`

**Interfaces:**
- Produces: `analyze_insights(..., warnings: list[str] | None = None)` and `analyze_sentiment(..., warnings: list[str] | None = None)` append messages; exact copy: offline → `"AI notes skipped: offline. Re-process when online to generate them."`; LLM failure → `"AI notes failed ({reason}); rule-based notes were used."`; no key → `"AI notes need an LLM API key; rule-based notes were used."` (sentiment uses the same wording with "AI sentiment").

- [ ] **Step 1: Write failing tests:** Python — offline env makes no `LLMClient` call (patched to fail) and appends the offline message; a raised `LLMError("HTTP 404")` appends the failure message containing "HTTP 404"; a successful pipeline run returns those warnings in `JobResult.warnings` with `status == "completed"`. Swift — migration adds the column to an existing v5 DB; `updateSessionWarning` round-trips and nil clears it.
- [ ] **Step 2:** `cd python-worker && .venv/bin/python -m pytest -q tests/test_ai_notes_warnings.py` and `cd macos-app && swift test --filter 'DatabaseMigrationTests|SessionManagerWarningTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** both suites PASS, including the CI-equivalent venv (`pytest pytest-cov pydantic click numpy openai anthropic` only).
- [ ] **Step 5: Commit** `fix(worker): report AI-notes fallbacks; show session warnings`.

### Task 8: Verify, document, hand over

**Files:** `docs/FEATURES.md`, `docs/PENDING.md`, this plan, the benchmarks fixture.

- [ ] **Step 1:** Full `swift test`, Python suite locally and in the CI-equivalent venv, `swift build`.
- [ ] **Step 2: Manual check with the user's key** (user-run, or with their go-ahead): one real `/benchmarks?source=artificial-analysis` response saved, its field names/scales confirmed against the decoder, and committed as the fixture (strip nothing but the auth header; it contains no personal data).
- [ ] **Step 3:** Build/sign/install per PENDING "Local installs"; user checks: picker shows live prices/scores; offline (Wi-Fi off) shows disabled controls with reasons, recording + local Whisper still work, session shows the offline AI-notes warning.
- [ ] **Step 4:** Independent whole-branch review; fix material findings.
- [ ] **Step 5:** Update FEATURES/PENDING with what shipped and what was not verified; commit `docs: live model catalog and offline behaviour`.
