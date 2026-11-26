import type { RecordingState } from "./events";

// JSON shapes of the app's sessions API (see Task 5's route table). Optional
// fields are omitted by the server when absent.

export interface SessionCosts {
  transcription?: number;
  processing?: number;
  total?: number;
  currency?: string;
}

export interface SessionDTO {
  id: string;
  title: string;
  sourceApp: string;
  startedAt: string;
  endedAt?: string;
  durationSec?: number;
  /**
   * recording, completed, transcribing, transcribed, error, failed or
   * interrupted; typed loosely so a newer server value can't break the UI.
   */
  status: string;
  recordingType: string;
  language: string;
  notesLanguage: string;
  engine?: string;
  warning?: string;
  /** Why the last processing run failed. */
  error?: string;
  costs: SessionCosts;
  audioFileName: string;
  hasAudio: boolean;
  hasTranscript: boolean;
  hasNote: boolean;
  hasAnalysis: boolean;
  hasLiveMap: boolean;
}

export interface SearchHit {
  id: string;
  sessionId: string;
  title: string;
  /** Seconds into the transcript; absent for title and note hits. */
  time?: number;
  excerpt: string;
}

export interface TranscriptLine {
  start: number;
  end: number;
  text: string;
  /** The worker's label; rename by it. */
  speaker?: string;
  /** What to display. */
  name?: string;
}

export interface NoteDTO {
  markdown: string | null;
}

export interface SpeakerDTO {
  label: string;
  name: string;
  renamed: boolean;
}

export type MarkerKind = "decision" | "question" | "note";

export interface TapeMarker {
  id: string;
  time: number;
  kind: MarkerKind;
  text: string;
}

export interface SpeakerStats {
  label: string;
  name: string;
  isSelf: boolean;
  talkSeconds: number;
  talkRatio: number;
  words: number;
  wordsPerMin: number;
  turns: number;
  longestMonologueSec: number;
  dominantEmotion?: string;
  valence?: number;
  arousal?: number;
}

export interface Insights {
  title: string;
  summary: string;
  keyPoints: string[];
  actionItems: string[];
  recommendedActions: string[];
  dynamics: string;
  opportunities: string[];
  reflections: string[];
  outline: string[];
  keyConcepts: string[];
  qa: string[];
  takeaways: string[];
}

export interface AnalysisDTO {
  recordingType: string;
  numSpeakers: number;
  warnings: string[];
  speakers: SpeakerStats[];
  sentiment?: {
    overall: string;
    overallScore: number;
    bySpeaker: Record<string, { label: string; score: number }>;
    arc: { t: number; score: number }[];
  };
  insights?: Insights;
}

export interface SystemStatus {
  online: boolean;
  /** True from the moment a recording starts until it has stopped: playback would be recorded. */
  recording: boolean;
  version: string;
  /** idle, starting, recording, stopping or processing (older apps omit it). */
  recordingState?: RecordingState;
  /** Why the last recording start or stop failed, as the menu shows it. */
  problem?: string;
}
