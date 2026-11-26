import type { LiveSnapshot } from "../api/liveTypes";

/** A live meeting with a nested topic, one memo, two turns and a partial line. */
export function liveFixture(overrides: Partial<LiveSnapshot> = {}): LiveSnapshot {
  return {
    active: true,
    sessionID: "S1",
    title: "Weekly sync",
    audioFileName: "S1.wav",
    status: "Live notes (en)",
    processingStatus: "Local speech active · You / Remote audio",
    followsLive: true,
    selectedTopicID: "timing",
    currentTopicID: "timing",
    catchUpText: "",
    partials: { system: "and then we ship" },
    microphoneEnabled: true,
    speechRunning: true,
    mappedThroughSeconds: 4,
    speechLanguage: "en",
    notesLanguage: "en",
    resolvedNotesLanguage: "en",
    canChooseNotesLanguage: false,
    notesLanguageChoices: ["en", "uk", "pl", "de", "fr", "es"],
    usage: { requests: 3, promptTokens: 900, completionTokens: 120, reportedCostUSD: 0.012, unpricedRequests: 0 },
    warnings: [],
    turns: [
      { id: "t1", source: "system", start: 1, end: 2, text: "Can we ship Friday?", language: "en" },
      { id: "t2", source: "mic", start: 3, end: 4, text: "If staging is green.", language: "en" },
    ],
    topics: [
      {
        id: "release",
        title: "Release plan",
        summary: "Shipping this week.",
        pinned: false,
        memos: [{ id: "m1", kind: "decision", text: "Ship Friday", manual: false, pinned: false, turnIDs: ["t2"] }],
        turnIDs: ["t1"],
        visits: [{ start: 1, end: 2, turnIDs: ["t1"] }],
        manualTitle: false,
        manualParent: false,
        isUnassigned: false,
      },
      {
        id: "timing",
        parentID: "release",
        title: "Timing",
        summary: "",
        pinned: true,
        memos: [
          { id: "m2", kind: "question", text: "Who owns the rollback plan?", manual: false, pinned: false, turnIDs: [] },
          { id: "m3", kind: "note", text: "Ask about the migration window.", manual: true, pinned: false, turnIDs: [] },
        ],
        turnIDs: ["t2"],
        visits: [{ start: 3, end: 4, turnIDs: ["t2"] }],
        manualTitle: false,
        manualParent: false,
        isUnassigned: false,
      },
    ],
    offlineMessage: "Automatic notes paused: offline. Transcript and manual notes continue.",
    ...overrides,
  };
}

export const systemIdle = { online: true, recording: false, version: "1.0", recordingState: "idle" };
export const systemRecording = { online: true, recording: true, version: "1.0", recordingState: "recording" };
