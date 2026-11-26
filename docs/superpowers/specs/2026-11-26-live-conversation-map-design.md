# Live conversation map

Date: 2026-11-26.
Status: product direction accepted by the user; design prepared for implementation.
No live-transcription or topic-map implementation is shipped yet.

This replaces the scope of the June live-preview design. Live transcription
and a navigable conversation/topics tree are the main product priority for
following, revisiting and connecting ideas while a meeting continues.

## 1. The job to do

During a meeting, answer: **What are we discussing? How did we get here? What did
I miss while checking an earlier idea? What do I want to return to?**

The live meeting workspace becomes the main workflow. After-meeting notes are
the durable record of the same topics, decisions, questions and source audio.
Keep all existing roadmap options; prioritise this workflow after the safety
repairs needed to trust its transcript and preserve the user's data.

## 2. First usable version

| Capability | Required behaviour |
| --- | --- |
| Live transcript of both sides | Include the enabled microphone and captured system audio, with timestamps and clear partial/final text. Use **You** and a neutral remote label until actual speaker identity is known. Mic-off remains explicit. |
| Stable topic tree and live memos | Build short topic/subtopic labels and brief memos from committed transcript turns. Separate ideas, questions, decisions and follow-ups. Clicking a branch shows its memo and supporting turns. |
| Manual control | Add a thought or question without losing the live position; pin a topic; rename, move or merge suggested topics. Preserve manual text and corrections. |
| Catch up and return | Keep the current live topic visible while browsing history. **What did I miss?** summarises committed turns since the user left live follow mode; **Back to live** returns to the latest context. |
| Durable, checkable output | Save the live transcript, topic visits, manual notes and source references locally. Export the topic outline and timestamped evidence to Obsidian. Final processing refines the record while retaining corrections and provenance. |

The first version may use a nested outline; a spatial mind-map canvas is a later
view of the same information, not a prerequisite for usable navigation.

## 3. The screen

Use the existing native SwiftUI app styles and controls. Start with an expandable
topic outline on the left and the selected topic's memo/evidence on the right.
The full live transcript can expand below the detail; it need not compete with
the topic tree at all times. Keep the live-position cue and navigation controls
visible in either state.

Synthetic example:

```text
Recording 18:42   Current topic: Release plan > Testing
[What did I miss?]  [Add thought]  [Back to live]

Release plan                     Selected: Timing
  Timing                         Decision: aim for Friday
    Decision                     Source: 08:42 [show transcript]
  Testing  < live                 My note: ask about rollback
    Open question
Ideas to revisit
  Billing improvement
```

The initial usability choices are deliberately explicit:

1. Keep branches in a stable order. New evidence updates a branch in place;
   background processing does not reorder the tree or move keyboard focus.
2. When reading an earlier branch, hold that selection and scroll position.
   Show a quiet new-content count and the live-topic cue instead of forcing a jump.
3. Use short labels, expandable detail and text status labels. The interface
   does not rely on colour, animation or a large graph to explain state.
4. Make every control keyboard accessible: traverse/expand topics, add a note,
   open evidence and return to live. Use standard focus behaviour and support
   the system's text sizing and Reduce Motion settings.
5. Keep automatic suggestions editable and visibly distinguishable from the
   user's own thoughts. Pinning a note/topic prevents silent rewrites or moves.

## 4. A tree that can follow a real conversation

Topics recur and overlap. Give each topic a stable ID, an optional parent and
an ordered list of timestamped **visits**. Returning to pricing later adds a
visit to the same topic rather than creating a second indistinguishable branch.
An idea can link to another topic without needing two editable copies.

Each memo item has a type (idea, question, decision or follow-up), source-turn
IDs and origin (automatic suggestion or manual note). A question stays open
until evidence or a user action resolves it. A suggestion is not a confirmed
decision; unclear owners and dates stay unspecified.

Do not force an uncertain topic association. Keep an unassigned/new-discussion
bucket that can be corrected. Preserve the original utterances when topics
are renamed, moved or merged, so organisation cannot remove evidence.

## 5. Live processing and reliability

```text
microphone + system audio
        |
        +--> existing recording files and recovery path
        |
        +--> bounded off-audio-thread live transcription
                       |
                       +--> timestamped partial/final turns
                                      |
                                      +--> saved live transcript
                                      +--> incremental topic/memo updates
                                                     |
                                                     +--> stable outline + catch-up
```

The capture callback must never wait for transcription, model work, network
I/O or the UI. Keep live processing bounded; if it cannot keep up, preserve
recording, show the lag/gap, and recover from saved audio. Never silently
discard speech while presenting a continuous transcript.

Build memos from finalised turns, not repeatedly changing partial hypotheses.
Batch a small amount of new text per update and coalesce superseded requests.
Cache the current memo/catch-up state so browsing does not trigger a fresh
model request on every click. If analysis fails, live text and manual notes
remain usable; if transcription fails, recording continues with an explicit
status and a retry/recovery path.

Preserve timeline alignment across mic/system streams. Source references use
stable turn identities and audio offsets; final transcription can revise words
and alignment without silently invalidating live bookmarks. A final pass must
retain the original live evidence and the user's edits, and explicitly mark
an anchor that cannot be reconciled.

Local-first remains the default goal. Cloud speech/analysis is an explicit
provider choice with visible data flow and usage. Before choosing a live engine,
verify the packaged runtime, model availability, Ukrainian/English and mixed
speech, both audio channels, latency and memory on the target Mac. The old
AssemblyAI-only language guard and English treatment of `auto` are not carried
forward as requirements. No current provider's language support or cost is
assumed from the June document.

Generated topic labels, memos and catch-up use the session's chosen **notes
language**. Preserve the spoken transcript in its original language and manual
text exactly as entered. Changing output language must not replace manual edits
or invalidate topic identities and evidence links.

For notes-language Auto, use an explicitly selected speech language; if speech
is Auto/mixed, use the first confidently detected speech language, display the
resolved choice and hold it stable until the user changes it. If no language can
be resolved confidently, defer generated memos and offer the existing language
picker while transcript/recording continue. This is an explicit initial design
choice to avoid language changes moving or repeatedly renaming the map.

If a selected engine cannot support the chosen speech language or mixed-language
mode, explain the limitation and offer recording plus manual notes. Never
silently substitute English, switch to a cloud provider, or present unsupported
live processing as successful.

## 6. Acceptance scenarios

1. A synthetic conversation goes timing -> testing -> timing. The tree retains
   one Timing topic with two visits and evidence for each memo; unresolved
   questions remain visibly open.
2. The user reads Timing while Testing continues. Selection, focus and scroll
   stay fixed; the live cue updates. Catch-up covers speech since leaving live
   follow mode; Back to live restores the latest context.
3. The user pins and edits a note, then an automatic update revises the topic.
   The note survives unchanged. Conflicting suggestions remain reviewable.
4. Either live processor stalls or loses connectivity. Audio capture continues;
   gaps/lag are shown; retry does not duplicate transcript turns, memos or cost
   records. No fake transcript can be reported as successful.
5. Both sides use English/Ukrainian, with a repeated technical term. Verify
   capture, transcription, speaker/source distinction, topic navigation,
   notes-language choice and export against labelled source audio separately.
   Generated labels/memos/catch-up follow notes language; spoken/manual text
   retain original wording. With an unsupported language/mixed mode, show the
   limitation and keep recording/manual notes available without a silent
   language or provider substitution.

Latency targets to validate, not measured claims: useful text within 1-3 seconds
of a completed utterance; a memo/topic update within 5-10 seconds of committed
speech; cached topic navigation immediate. Measure on the actual target Mac
before selecting an engine or promising these targets.

## 7. Delivery order

| Stage | Concrete result |
| --- | --- |
| Foundation | Remove false-success transcripts, preserve source/speaker evidence and protect saved/exported notes. |
| Usable live navigation | Both-side live transcription, a stable tree, short memos, manual thoughts, catch-up and durable timestamps in one native meeting workspace. |
| Real-call validation | Exercise the five scenarios with synthetic/authorised audio; check wired/Bluetooth behaviour and the user's actual navigation preferences. |
| Broader roadmap | Add the remaining automation, integrations, richer views and comparative benchmarks from docs/FEATURES.md. |

The next implementation plan should define the live-engine spike and a small
vertical slice against these scenarios. It must not revive the remote-only,
disposable-preview scope as if it satisfied the conversation-map requirement.
