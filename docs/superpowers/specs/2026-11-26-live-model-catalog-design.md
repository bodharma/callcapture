# Live model catalog and offline-aware features

Date: 2026-11-26. Status: approach chosen by the user ("go" on approach 1);
builder-checked; design awaiting approval.

## Intent

The Settings model picker is a hard-coded list that went stale: the selected
`anthropic/claude-sonnet-4` was retired by OpenRouter, so automatic live notes
failed with HTTP 404 and batch insights silently fell back to rule-based text
(every session shows LLM cost 0). The user wants to **choose models personally**
from the **currently active** models, see **what each costs** for this app's two
LLM jobs, and see **what each model is good at** from an independent source,
not from hand-written opinions. When there is no internet (a local meeting at
home), anything that needs the network must say so plainly, while everything
that works offline keeps working unhighlighted.

## Goals

1. **Live list.** Models come from OpenRouter `GET /api/v1/models` (public, no
   key): id, display name, prompt/completion price per token, context length,
   and `supported_parameters` (whether `response_format`/`structured_outputs`
   is supported). Only currently listed models are selectable.
2. **Independent quality data.** Scores come from OpenRouter
   `GET /api/v1/benchmarks?source=artificial-analysis` (needs the user's
   OpenRouter key, which the app already stores). Shown per model:
   **Intelligence** (0–100), **Multilingual** (0–1, the signal for Ukrainian/
   Russian/English calls), **Strategy & Ops** (0–100, closest to business
   meetings). Models without scores show "no independent score" — never a guess.
   Response fields per the OpenRouter Data API docs: `data[].model_permaslug`,
   `display_name`, `intelligence_index`, `multilingual_index` (0–1),
   `strategy_and_ops_index`, plus `meta.as_of` and `meta.citation`. Join to
   `/models` by exact match of `model_permaslug` against `canonical_slug`, then
   `id`; no fuzzy matching (unmatched → "no independent score"). The builder
   captures one real response with the user's key during manual verification
   and turns it into the test fixture; until then the documented sample is the
   fixture.
   Required attribution, shown wherever scores appear: "Source: Artificial
   Analysis (artificialanalysis.ai) via OpenRouter (openrouter.ai/rankings)".
3. **"Best for" labels derived from those scores, not opinions.** Rule-based
   tags computed across the listed models, e.g. top-quartile Multilingual →
   "Strong multilingual", top-quartile Intelligence → "Highest quality",
   cheapest quartile for the role → "Budget". The rule is shown on hover.
4. **Two model choices.** *Final notes model* (batch insights after a
   recording; the existing `llmModel` setting) and *Live notes model*
   (automatic live memos; new setting). On upgrade the live setting is
   **copied once** from the final model, so behaviour is unchanged; afterwards
   the two are independent, and changing the final model never reprices live
   notes. They run at very different rates:
   live memos send a request after each coalesced batch of committed turns
   (400 ms coalescing, one in flight), each carrying instructions plus the
   whole topic tree, i.e. hundreds of requests per meeting hour; final notes
   are one request per recording.
5. **Cost per meeting hour, per role.** Each model row shows an estimated
   cost per hour of meeting for the live role and for the final role, from the
   live prices and a documented token model (see Constraints). Always labelled
   as an estimate (≈).
6. **Actual live-notes spend** *(designer's call, cuttable)*. Record the
   prompt/completion tokens (and OpenRouter-reported cost when present) of
   each live-memo request in the session, and show "Live notes so far: $X"
   in the live window and the session's cost line. Today live-memo spend is
   not tracked at all, and goal 5's estimate needs a reality check.
7. **No silent fallbacks.** If the selected model is no longer listed, Settings
   and the live window say so and live memos stay off with that reason; the
   app never switches models on its own (the existing retired-slug migration
   map remains only for slugs persisted before this change). When batch
   insights fall back to rule-based text, the worker adds a warning to the job
   result and the session detail shows it.
8. **Offline-aware UI, app-wide.** A connectivity monitor (`NWPathMonitor`,
   Network framework) drives an `isOnline` state. Network-dependent controls are
   disabled with a short inline reason; offline-capable features look normal.
   - Need network: cloud transcription (Transcribe/Re-process/Retry when the
     effective engine is remote, and auto-process on stop), LLM final notes via
     OpenRouter, automatic live notes, model-catalog refresh, live Whisper model
     download, OpenRouter key test.
   - Work offline: recording, local Whisper transcription, live local speech,
     manual notes/topics, playback, search, exports to disk.
   - Auto-process on stop while offline with a remote engine: the recording is
     kept, status says it waits for a connection or local transcription, and
     nothing is sent; the user can transcribe later (no automatic background
     queue in this version).
   - Offline with local Whisper and OpenRouter notes (the home-meeting case):
     transcription runs locally; the app tells the worker it is offline so it
     skips the LLM call (no timeout wait), writes rule-based notes and returns
     the warning "AI notes skipped: offline. Re-process when online to generate
     them." Re-process with local Whisper is free, so no separate notes-only
     command or deferred-notes state is built in this version.
   - "Online" from the monitor is a hint, not a guarantee: request failures
     still produce explicit messages (host unreachable, 401, 404 model gone).

## Local LLM provider

Catalog, prices, scores, the "no longer listed" check and offline gating apply
only to the OpenRouter provider. Under the Local provider both roles use the
existing free-text model name, stored separately from the two OpenRouter
selections so switching providers never overwrites them. Local notes are not
network-gated (the server is usually on this Mac); failures still surface as
explicit messages.

## Non-goals

- Running models on the user's recordings to compare them ("try on my
  recording"); a possible later addition.
- Catalogs for the local LLM server (Ollama etc.); the local-provider path keeps
  its current free-text model field.
- LMArena/other leaderboards (no official API).
- Automatic model selection or switching.

## Anti-goals (failure even if it "works")

- Silently changing the user's model or provider, or silently degrading notes.
- Showing an estimate as if it were a measured price.
- Blocking or degrading recording because the network is down.
- Burning the Data API quota (30 req/min, 500/day): fetch at most once per day
  per list unless the user presses Refresh.
- Showing quality scores without the required attribution.

## Constraints

- macOS 14.2, Swift/SwiftUI, no new dependencies (URLSession, Network).
- OpenRouter key stays in the Keychain via the existing `CredentialStore`.
- Cache both responses on disk (Application Support/CallCapture) with a fetch
  timestamp; offline or on failure, show the cached list labelled
  "as of <date>"; with no cache and no network, show the current selection only
  with an inline "needs internet to load the model list".
- Token model for estimates (constants in one place, easy to tune, stated in
  the UI tooltip): final notes ≈ 13k input + 2k output tokens per meeting hour;
  live notes ≈ 450 requests/hour × (3k input + 0.8k output). The builder
  should sanity-check these against the real prompt sizes in
  `ConversationTopicService` and `insights.py` and adjust the constants.
- Tests use a fake transport; no real network in tests (CI has none of the
  user's keys). CI constraints in `memory: ci-test-constraints` apply.

## Approaches considered

1. **OpenRouter only (chosen).** `/models` for the live list and prices,
   `/benchmarks?source=artificial-analysis` for scores; one provider, one key
   the user already has, small quota needs.
2. **Artificial Analysis API directly.** More fields, but a separate account
   and key, and prices are paid-tier only. No advantage over 1.
3. **Curated catalog with live prices.** Rejected: hand-written quality claims
   go stale, which is the original problem.

## Screen sketch (Settings → Post-Processing)

```text
Final notes model   [Claude Sonnet 5.5          v]   ≈ $0.05 / meeting hour
Live notes model    [Claude Haiku 5.5           v]   ≈ $0.42 / meeting hour
                     Model list as of 26 Nov 14:58 · [Refresh]

 Choose model (search: ______ )        [x] Works for live notes (JSON)
 Model              Live/h   Final/h  Intell.  Multiling.  Strategy  Best for
 Claude Haiku 5.5   $0.42    $0.003   54       0.81        48        Budget
 Claude Sonnet 5.5  $8.40    $0.05    66       0.88        63        Highest quality, Strong multilingual
 Gemini 2.5 Flash   $1.70    $0.01    51       0.84        —         Strong multilingual
 ...
 Scores: Artificial Analysis via OpenRouter · estimates use a token model (i)

Offline:  [Refresh] disabled · "Offline — showing the list saved 26 Nov 14:58."
```

Numbers above are illustrative only.

## Left to the builder

Exact layout (table vs. list), sorting defaults, quartile thresholds, cache file
format, how the connectivity state is injected into views, and where the
disabled-reason text sits for each control, within the rules above.
