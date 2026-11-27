# Regenerate AI notes, and filters for the AI notes model table

Date: 2026-11-27. Status: both features and their options chosen by the user (small change).

## Why

1. The last session (3 h 14 min, Ukrainian) got rule-based notes because the AI notes reply was cut at 2 048 tokens. The cut-off is fixed (output budget now scales with length, `d5f40f1`), but regenerating that session's notes today means Re-process: a second cloud transcription (~$1.67) plus ~10 minutes. The user wants a cheap "Regenerate AI notes" that reuses the saved transcript.
2. The Settings → AI notes model table has only search and "JSON-capable only". The user wants filters: Provider, Max cost per hour, Ukrainian quality, Context length, and "Good for".

## Goals

- **Regenerate AI notes** on a session that already has a transcript: rerun only sentiment, insights, the Markdown note and the analysis file from the saved transcript. No transcription, no audio upload. Speaker renames survive. Transcription cost stays; processing cost is replaced by the new run's cost. The session's warning is replaced by the new run's warnings.
- Available from the web session page (next to Re-process) and through the API; disabled with a short inline reason before any click when it can't run (recording, another job running, offline with a cloud notes model, no saved transcript), using the same pure-policy pattern as Re-process.
- **Model table filters** (web, signal-room style, no new libraries): Provider (from the model id prefix / catalog), Max cost per hour (for the role being chosen, final or live), Ukrainian quality (minimum Artificial Analysis multilingual score; models without a score hidden unless "include unscored" is on), Context length (minimum: any / 32k / 128k / 200k / 1M), Good for (the existing Swift tags: Highest quality, Strong multilingual, Budget). Filters combine with search and "JSON-capable only". A "Clear filters" action; a count of shown vs total models. Values that need computing (cost per hour, tags) keep coming from Swift.

## Non-goals

- Changing models, prompts or the transcription pipeline.
- Live speech through OpenRouter (separate decision, still open).
- Persisting filter choices across launches.

## Constraints

- No new runtime libraries (web or Swift). Python: no new packages.
- Tests: no real network, recordings or Keychain; synthetic transcripts only. Never read the user's real sessions while building or testing.
- Offline rule: unavailable actions are disabled with a short inline reason before any click.
- Attribution for Artificial Analysis scores stays visible wherever scores are used, including the Ukrainian quality filter.

## Approaches

- **Regenerate:** (a) a new worker command that loads the saved transcript and runs the post-transcription half of the pipeline — chosen; (b) Re-process with a "skip transcription" flag — rejected as it overloads one job with two meanings; (c) run notes in Swift — rejected, the analysis code lives in Python.
- **Filters:** client-side filtering over the catalog the app already serves — chosen (the catalog is small); server-side query params — unnecessary.
