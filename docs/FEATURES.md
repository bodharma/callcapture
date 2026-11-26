# CallCapture feature backlog

Updated 2026-11-26. This is a proposed roadmap, not a list of shipped features.
The target is live meeting navigation: dependable capture, a readable live
transcript, and a stable conversation/topic tree with short memos, followed by
portable notes. The goal is to follow and revisit ideas while a meeting
continues. Feature count alone does not establish a lead.

## Main product priority: live conversation navigation

All five roadmap groups remain valid. After the correctness repairs required
to trust the transcript and protect saved data, prioritise a complete live
navigation workflow over adding more after-meeting analysis features.

| Required capability | Completion check |
| --- | --- |
| Live transcript of both sides | Enabled mic and system audio appear with aligned timestamps and clear partial/final text; missing engines fail explicitly |
| Stable topic tree and short live memos | Topics/subtopics collect ideas, questions, decisions and follow-ups; returning to a topic adds a visit to the existing branch |
| Browse without losing the meeting | Reading an earlier branch preserves focus/scroll; a live-topic cue and new-content count update quietly |
| Thoughts, bookmarks and catch-up | Manual/pinned notes survive automatic updates; What did I miss? covers speech since leaving live follow mode; Back to live restores context |
| Durable evidence and export | Memos cite transcript/audio; live bookmarks survive final processing or show an explicit unresolved anchor; save the outline and notes locally and to Obsidian |

See [the live conversation-map design](superpowers/specs/2026-11-26-live-conversation-map-design.md)
for the screen, accessibility choices, processing constraints and acceptance
scenarios. This extends and supersedes the June remote-only preview scope.
It is proposed work, not shipped functionality.

## Current upgrade: smart audio defaults

Output and microphone default to the Mac's current devices, with named manual
overrides and an explicit microphone-off option. Device/default changes refresh
the menu; disconnected overrides fall back before the next recording. Active
recordings retain their current devices. Overrides currently last for the app
session; persistent routing and mid-recording handover are separate work below.

## 1. Correctness and trustworthy local processing — first

| Proposed change | Why it matters | Completion check |
| --- | --- | --- |
| Replace canned local-transcription fallback with an actionable error | A missing engine must never invent a successful transcript | A missing dependency or missing audio cannot produce a completed job; existing audio is preserved |
| Ship a working local transcription engine in the notarized app | Local-first should work for people installing the release | A clean Mac can download a model and transcribe offline without a Python setup or cloud key |
| Preserve cloud speaker labels when local diarization is unavailable | Avoid collapsing several remote speakers into Speaker 1 | A multi-speaker provider response retains distinct labels through exported notes |
| Honour the selected Markdown profile | Meeting Notes, Full Transcript and Obsidian must have distinct effects | End-to-end output checks cover each selected profile, complete transcript text and notes language |
| Make vault exports collision-safe and atomic | Repeated titles or re-export must not destroy another note or user edits | Same-title sessions coexist; write failures leave existing notes intact; overwrite of edited notes is explicit |

LLM/analysis fallbacks should visibly say what was skipped. Tests must isolate
credentials rather than wait for access to the user's live Keychain.

## 2. Make every recording easy to check

Partly implemented locally on branch feat/session-review (see below): readable
transcript, linked playback with speed, search, rename speakers. Waveform, merge
speakers and capture health remain open.

| Proposed change | Why it matters | Completion check |
| --- | --- | --- |
| Readable speaker-labelled transcript and rendered Markdown | The session screen should be useful without opening raw files | The full recording is readable and selectable inside the app, with no 1,000-character preview limit |
| Transcript-linked playback, speed control and waveform | Quickly verify a questionable quote or name | Clicking a timestamp seeks to the correct mixed/stem audio position |
| Full-text search across transcripts and notes | Find decisions after the meeting is forgotten | Results show matching excerpts and open the matching session/time |
| Rename, merge and correct speakers | Speaker 1 is a starting point, not a useful permanent identity | Corrections persist and reach transcripts, insights and later exports |
| Capture health and interruption recovery | Notice silence, storage failures and incomplete recordings early | Mic/system meters are separate; failed preflight creates no session; interrupted audio remains recoverable |

## 3. Remove meeting administration

| Proposed change | Why it matters | Completion check |
| --- | --- | --- |
| Live conversation navigation (promoted to main priority above) | Follow and revisit meeting ideas while the conversation continues | Deliver both-side live text, a stable topic tree, short memos, catch-up and evidence without interrupting recording |
| Seamless wired/Bluetooth device handover | Headphone changes should not lose a participant | Mid-call connect/disconnect tests verify both channels, continuity and recoverable errors |
| Calendar context and start/stop prompts | Useful titles, attendee candidates and fewer missed recordings | Calendar access is optional; recording begins only through the user's configured choice |
| Saved device choices and reusable note templates | Avoid repeating configuration | Per-device/app choices survive relaunch; disconnected preferences visibly use a safe fallback |
| Local MCP and explicit integrations | Make meeting knowledge usable in the user's existing tools | Search/read tools cite sessions; external sends and changes are opt-in and reviewable |

## 4. Build a reason to choose CallCapture

| Proposed change | Why it matters | Completion check |
| --- | --- | --- |
| Excellent Ukrainian/English and mixed-language handling | Optimise for a concrete daily workflow | The same bilingual evaluation set measures recognition, names and separate notes-language correctness |
| Evidence-linked summaries and action items | Make conclusions checkable | Each material claim links to supporting transcript spans; unsupported claims are omitted or marked uncertain |
| Custom vocabulary and editable corrections | Technical terms and names drive many useful improvements | A glossary improves held-out terms without injecting absent words into silence |
| Cautious conversation coaching | Make dynamics useful without pretending to know a person's mental state | Suggestions show observable evidence; acoustic estimates are labelled estimates and can be disabled |
| Commitments across recurring meetings | Help finish work after the call | Users can confirm owners/dates, track completion and trace a carried-over item to its source |

## 5. Prove quality and keep installation dependable

| Proposed change | Why it matters | Completion check |
| --- | --- | --- |
| Reproducible comparison with Daisy, Biscotti, Anarlog and Meetily | Establish actual wins rather than infer accuracy from a feature list | Identical authorised recordings and labelled references measure word/speaker errors, missed commitments and unsupported claims |
| Clean-install and hardware regression coverage | Development builds can conceal release defects | Signed builds are checked on supported macOS versions, built-in/wired/Bluetooth devices and a clean user profile |
| Useful progress, cancellation and retry | Long processing should be understandable and recoverable | Cancellation preserves audio; retry cannot silently switch engines or duplicate external charges |
| In-app updates and model management | Remove installation and disk-space surprises | Updates preserve sessions/settings; model downloads resume and verify integrity before use |
| Measured resource use and per-session usage | Make speed and cost claims credible | Report model, hardware, duration, peak memory, latency and estimated versus provider-reported cost separately |

## Implemented locally, unreleased (2026-11-26, branch feat/smart-audio-defaults)

Committed on branch feat/smart-audio-defaults (5 commits, not yet pushed or released);
nothing below is in a released build.

**Live conversation map (local).** Mic ("You") and system ("Remote audio") PCM is
offered to a bounded buffer (24 s, never blocks capture) and sent to a persistent
local Whisper worker (`call-capture-worker live`, NDJSON over stdio): 3 s provisional
previews, 6 s finals with 1 s lookback, stable `source-sampleOffset` request IDs shared
by preview and final. Finals are committed once (dedup by ID). A topic tree with
visits/memos is built from them; automatic notes are optional (explicit provider+model,
one request at a time, no automatic retry after failure). Manual notes, topic
add/rename/move/merge/pin and memo edit/pin never get overwritten by automatic updates.
"What did I miss?" shows raw evidence since leaving live follow mode; "Back to live"
restores it. Auto notes language can be chosen once when speech language is unresolved.
Persistence: `<audio>_live.json` (atomic, never overwrites an existing map, offsets
capped at 7 days, damaged files rejected); Markdown export never overwrites.
Single writer: the active/stopped session model and the history sheet share one
instance per saved map. Worker/model failure, backlog (>12 s, shown by an independent
monitor) or stop timeout only add warnings; recording and the saved audio are untouched.
Missing model -> explicit error; `prepare-live-model` is a separate user action.

**Other correctness work in this change.** Smart audio defaults; fake batch fallback
removed; cloud speaker labels preserved; profile selection repaired (Meeting Notes omits
the source transcript, Full Transcript includes every turn, Obsidian keeps frontmatter);
SettingsManager takes an injected `CredentialStore` (Keychain in production, memory in tests).

**Receipts.** Python: 239 passed, 83% coverage. Swift full suite: 107 tests / 28 suites
passed (domain, worker protocol, controller routing, stderr fd-leak, lag, ownership, credentials).
Frozen worker: built with pywhispercpp and six native dylibs; CLI + real English local
speech worked (3.341 s audio in 0.606 s warmed process; cold launch 10.376 s).
Synthetic quality (M3 Max 36 GiB, pywhispercpp 1.4.1, one clip each): base English accurate;
Ukrainian had a Friday-word error; mixed auto transliterated English; medium dropped
Ukrainian from the mixed clip (not a verified upgrade). Two persistent 6 s sources,
previews+finals (4 serial inferences): base 0.295 s, medium 2.133 s after warmup, one repeat.

**Reproduce.** `cd python-worker && .venv/bin/python -m pytest -q`;
`cd macos-app && swift test`; frozen: `cd python-worker && .venv/bin/python -m PyInstaller
--noconfirm --distpath <tmp>/dist --workpath <tmp>/build packaging/call-capture-worker.spec`
then `packaging/smoke_test.sh <tmp>/dist/call-capture-worker/call-capture-worker`.

**Not verified (no permission/hardware used):** real microphone/system capture, the GUI
workspace and history sheet, provider (cloud/LLM) note quality and cost, sustained load,
Ukrainian/mixed quality at scale, a published release/cask containing local Whisper.
Auto/mixed language is marked experimental in the UI. No superiority claim is made.

## Implemented locally, unreleased (2026-11-26, branch feat/session-review)

Built on the five feat/smart-audio-defaults commits; unreleased. Plan:
[session review](superpowers/plans/2026-11-26-session-review.md).

- **Full transcript with playback.** The detail view shows every transcript line (no
  1,000-character preview) with speaker and timestamp; clicking a timestamp seeks the
  mixed recording and plays; speed 0.75-2x; the current line is highlighted. Playback is
  paused and blocked from just before capture starts until capture has stopped (it stays
  blocked after a failed stop), because the system tap captures every process, including ours.
  The note renders in full (inline Markdown).
- **Rename speakers.** Click a speaker label to name it. Names live in
  `<audio>_speakers.json`, keyed by the worker's label. Names follow the label, not the
  voice: Re-process normally reproduces the same labels, but a different engine or diarizer
  can renumber speakers, so re-check names after switching. Applied
  to the transcript, insights, search and every export (Save to Vault, Markdown, text,
  JSON). `Speaker …` labels are replaced as whole labels anywhere; `You` only in speaker
  positions, so prose like "You should" is untouched. Deleted with the session.
- **Search everything.** The sidebar search covers every session (not only the 50 recent):
  titles, dates, transcript lines (with speaker names) and note lines, case- and
  diacritic-insensitive. Results show an excerpt and time; opening one positions the player
  at that line without autoplay. Linear scan, no index.
- **Export fix.** Exporting over an existing file chosen in the save panel now replaces it
  atomically (previously the copy failed when the file existed).

**Receipts.** Swift: 123 tests / 31 suites passed (new: transcript decoding/lookup, CRLF,
speaker-name replacement and persistence, search incl. Cyrillic, caps, damaged files, dates).
Python: 239 passed. Independent code review: one medium finding (playback could bleed
into a starting recording, since app state flips only after capture starts) and five low
ones (search spinner race, detail rebuild on same-session hit, player reload, timer frozen
while scrolling, lossy JSON export without renames); all fixed. The playback block has no
automated test.
**Not verified:** the GUI, actual playback/seek/speed, search UX and focus scrolling were not
exercised (no app launch). Not checked against real recordings.

## Implemented locally, unreleased (2026-11-26, branch feat/live-model-catalog)

Design: [live model catalog](superpowers/specs/2026-11-26-live-model-catalog-design.md);
plan: [plan](superpowers/plans/2026-11-26-live-model-catalog.md).

- **Live model list.** Settings → Post-Processing chooses a *Final notes model* and a
  separate *Live notes model* from OpenRouter's current list (`/api/v1/models`), cached
  for 24 h, in a sortable, searchable table: per-meeting-hour cost for each role (≈,
  token model in `ModelCostEstimate`), Artificial Analysis Intelligence / Multilingual /
  Strategy & Ops scores via OpenRouter `/api/v1/benchmarks` (attributed), score-derived
  tags (Highest quality, Strong multilingual, Budget), context size and a JSON filter.
  A selection OpenRouter no longer offers is flagged; the hard-coded list is gone (four
  retired Claude slugs migrate to successors).
- **Live notes spend.** Each automatic-notes request records tokens and OpenRouter's
  reported cost; the live window shows "Live notes so far". An unlisted live model is
  refused before any request.
- **Offline.** A network monitor disables network-only controls with an inline reason
  (automatic memos, live model download, cloud Transcribe/Re-process/Retry, catalog
  refresh, key test). Recording, local Whisper, live local speech and manual notes are
  unaffected. Auto-process keeps cloud recordings until online; local Whisper offline
  writes rule-based notes and says so.
- **No silent AI fallbacks.** Offline, missing key or an LLM error (e.g. a retired
  model's 404) now adds a session warning shown in the detail view (DB `v6_sessionWarning`).
- **Live transcript hygiene.** Silent windows skip Whisper; `[BLANK_AUDIO]`-style
  annotations are stripped.

**Receipts.** Swift 153 tests / 37 suites; Python 254 (also in the CI-equivalent venv).
**Not verified:** GUI (picker sheet, offline captions), a real `/benchmarks` response
(the test fixture is the documented sample; capture one with the user's key), the
token-model constants against measured live spend.

## Reference releases used for prioritisation

| Application | Inspected release |
| --- | --- |
| CallCapture | [v0.2.1](https://github.com/bodharma/callcapture/releases/tag/v0.2.1), plus local/GitHub main at 6bfe3f3 |
| Daisy | [v1.0.8.55](https://github.com/ca33u/daisy-app/releases/tag/v1.0.8.55) |
| Biscotti | [v1.0.0](https://github.com/scosman/Biscotti/releases/tag/v1.0.0) |
| Anarlog | [desktop_v1.4.36](https://github.com/fastrepl/anarlog/releases/tag/desktop_v1.4.36) |
| Meetily | [v0.5.0](https://github.com/Zackriya-Solutions/meetily/releases/tag/v0.5.0) |

These were source/release comparisons, not executed accuracy or performance
benchmarks. Meetily's advertised Pro features were not credited to its community
release. No feature here implies release, quality or superiority has been verified.
