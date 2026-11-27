import type { AnalysisDTO, SessionDTO, TranscriptLine } from "../api/types";

export function sessionFixture(overrides: Partial<SessionDTO> = {}): SessionDTO {
  return {
    id: "S1",
    title: "Weekly sync, release plan",
    sourceApp: "Zoom",
    startedAt: "2026-11-26T10:00:00Z",
    endedAt: "2026-11-26T10:46:12Z",
    durationSec: 2772,
    status: "transcribed",
    recordingType: "call_meeting",
    language: "uk",
    notesLanguage: "en",
    costs: { transcription: 0.1, processing: 0.02, total: 0.12, currency: "USD" },
    audioFileName: "S1.wav",
    hasAudio: true,
    hasTranscript: true,
    hasNote: true,
    hasAnalysis: true,
    hasLiveMap: false,
    canDelete: true,
    ...overrides,
  };
}

export const transcriptFixture: TranscriptLine[] = [
  { start: 0, end: 4, text: "Morning, everyone.", speaker: "Speaker 1", name: "Olena" },
  { start: 910, end: 915, text: "Who owns the rollback plan?", speaker: "Speaker 2", name: "Speaker 2" },
];

export const analysisFixture: AnalysisDTO = {
  recordingType: "call_meeting",
  numSpeakers: 2,
  warnings: [],
  speakers: [
    {
      label: "Speaker 1",
      name: "Olena",
      isSelf: false,
      talkSeconds: 1000,
      talkRatio: 0.6,
      words: 2000,
      wordsPerMin: 120,
      turns: 40,
      longestMonologueSec: 90,
    },
    {
      label: "Speaker 2",
      name: "Speaker 2",
      isSelf: false,
      talkSeconds: 600,
      talkRatio: 0.4,
      words: 1200,
      wordsPerMin: 110,
      turns: 35,
      longestMonologueSec: 60,
    },
  ],
  insights: {
    title: "Weekly sync",
    summary: "The team agreed to ship on Friday if staging is green by Thursday.",
    keyPoints: ["Staging must be green by Thursday."],
    actionItems: ["Olena confirms the migration window."],
    recommendedActions: [],
    dynamics: "",
    opportunities: [],
    reflections: [],
    outline: [],
    keyConcepts: [],
    qa: [],
    takeaways: [],
  },
};
