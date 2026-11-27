# Regenerate AI notes + model filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Regenerate a session's AI notes from its saved transcript, and filter the AI notes model table.

**Spec:** `docs/superpowers/specs/2026-11-27-regenerate-notes-and-model-filters-design.md`

## Global Constraints

- No new runtime libraries; no new Python packages.
- Tests use fakes and synthetic data only; never the user's real sessions.
- Offline/blocked actions: disabled with an inline reason before any click; reasons come from Swift pure policies.
- Artificial Analysis attribution stays visible wherever scores are used.

---

### Task 1: Regenerate AI notes

**Files:** `python-worker/app/cli.py` (+ a small module if the shared half is extracted), `python-worker/tests/…`, `macos-app/Sources/Bridge/Models.swift` (`JobRequest.regenerateNotes`), `macos-app/Sources/App/CallCaptureApp.swift` / `AppModel+Backend.swift` (start path), `macos-app/Sources/Server/…` (route, DTO field, pure policy in `SessionGuards.swift`), `web/src/features/sessions/…`, tests on all three sides.

- [ ] Worker: new command `regenerate_notes` (JSON request like `transcribe`, plus the saved transcript path). It loads the saved, speaker-attributed segments, then runs the existing post-transcription steps (emotion if the model is ready, sentiment, insights, speakers, analysis file, Markdown note) — extract that half of `_run_pipeline` into one function both commands call, so behaviour can't drift. If the saved transcript lacks what the analysis needs (e.g. speaker attribution), STOP and report NEEDS_CONTEXT with what's missing.
- [ ] Swift: `JobRequest.regenerateNotes(session:)`; an AppModel start path that reuses the transcription job plumbing (progress, stage "Regenerating notes", completion updates analysis/note paths, processing cost, warning) without touching the transcript or transcription cost; status during the run follows the existing in-progress convention so guards and the UI treat it as busy.
- [ ] Policy: `RegenerateNotesPolicy` (pure, in `SessionGuards.swift`): blocked while recording / another job / mid-transition, when the session has no saved transcript, and offline when the notes model is a cloud model — wording from `NetworkPolicy`. Both production and `FakeBackend` use it.
- [ ] API: `POST /api/sessions/:id/regenerate-notes` → 202 `{"started":true}`, 404 unknown id, 409 `{"error":code,"message":reason}`; session DTO gains `regenerateBlocked: String?` (and the existing events refresh it).
- [ ] Web: "Regenerate AI notes" action beside Re-process on the session page, shown when the session has a transcript; disabled with the inline reason; progress shows like Re-process.
- [ ] Tests: pytest (synthetic saved transcript → notes and analysis written, no transcription called, warnings returned); Swift (policy table, route 202/404/409, DTO field, job request shape); Vitest (button visibility, disabled reason, POST and progress).

### Task 2: Model table filters

**Files:** `web/src/features/settings/` (ModelTable, modelSort/filters module, tests), and the catalog DTO only if a field is missing (e.g. provider name).

- [ ] Filters: Provider (multi-select from the catalog), Max cost per hour (for the role being chosen), Ukrainian quality (minimum multilingual score + "include unscored"), Context length (any/32k/128k/200k/1M), Good for (Swift tags). Combine with search and "JSON-capable only"; "Clear filters"; "Showing N of M models".
- [ ] Pure filter function in TypeScript with unit tests for each filter and their combination; component tests for the controls (labelled, keyboard-usable, visible focus).
- [ ] The attribution line stays visible whenever the Ukrainian quality filter or score columns are shown.
