// JSON shapes of the live map API (`GET /api/live`, `GET /api/sessions/:id/live`)
// and of the live events. Optional fields are omitted by the server when absent.

export type LiveSource = "mic" | "system";
export type MemoKind = "idea" | "question" | "decision" | "action" | "note";
export const MEMO_KINDS: readonly MemoKind[] = ["idea", "question", "decision", "action", "note"];

export interface LiveTurn {
  id: string;
  source: LiveSource;
  /** Seconds into the recording. */
  start: number;
  end: number;
  text: string;
  language?: string;
}

export interface LiveMemo {
  id: string;
  kind: MemoKind;
  text: string;
  /** Written or edited by the user; never rewritten by automatic notes. */
  manual: boolean;
  pinned: boolean;
  turnIDs: string[];
  /** Set on an automatic revision of a memo the user wrote, edited or pinned. */
  suggestedRevisionOf?: string;
}

export interface TopicVisit {
  start: number;
  end: number;
  turnIDs: string[];
}

export interface LiveTopic {
  id: string;
  parentID?: string;
  title: string;
  summary: string;
  pinned: boolean;
  memos: LiveMemo[];
  turnIDs: string[];
  visits: TopicVisit[];
  manualTitle: boolean;
  manualParent: boolean;
  /** The "Discussion" bucket for speech not assigned to a topic yet. */
  isUnassigned: boolean;
}

export interface LiveNotesUsage {
  requests: number;
  promptTokens: number;
  completionTokens: number;
  reportedCostUSD: number;
  unpricedRequests: number;
}

export interface LiveSnapshot {
  /** The meeting is being recorded now. */
  active: boolean;
  sessionID: string;
  title: string;
  audioFileName: string;
  status: string;
  processingStatus: string;
  error?: string;
  followsLive: boolean;
  selectedTopicID?: string;
  currentTopicID?: string;
  catchUpText: string;
  partials: Partial<Record<LiveSource, string>>;
  microphoneEnabled: boolean;
  speechRunning: boolean;
  mappedThroughSeconds?: number;
  speechLanguage: string;
  notesLanguage: string;
  resolvedNotesLanguage?: string;
  canChooseNotesLanguage: boolean;
  notesLanguageChoices: string[];
  usage?: LiveNotesUsage;
  warnings: string[];
  turns: LiveTurn[];
  topics: LiveTopic[];
  /** The app's wording for automatic notes while offline. */
  offlineMessage: string;
}

/** `GET /api/live` while nothing is recorded; `lastSessionID` has the last meeting's map. */
export interface InactiveLive {
  active: false;
  lastSessionID?: string;
}

export type LiveResponse = LiveSnapshot | InactiveLive;

export function isSnapshot(value: LiveResponse | undefined): value is LiveSnapshot {
  return value !== undefined && "topics" in value;
}
