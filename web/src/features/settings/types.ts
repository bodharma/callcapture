// JSON shapes of the settings and catalog API (see SettingsRoutes.swift and
// CatalogRoutes.swift). Optional fields are omitted by the server when absent.

export type SecretKey = "openrouter" | "assemblyai" | "deepgram" | "remote";

export interface ModelState {
  ready: boolean;
  downloading: boolean;
  /** Why the last download failed. */
  error?: string;
}

export interface SettingsDTO {
  general: { autoProcessOnStop: boolean };
  recording: { outputDirectory: string; keepSeparateMicTrack: boolean };
  transcription: {
    engine: string;
    whisperModel: string;
    remoteProvider: string;
    models: { diarization: ModelState; emotion: ModelState };
  };
  aiNotes: {
    provider: string;
    finalModel: string;
    liveModel: string;
    localModel: string;
    localBaseURL: string;
    /** Why a chosen OpenRouter model may not work, worded by the app. */
    warnings: { final?: string; live?: string };
  };
  vault: { obsidianVault: string; folderPattern: string; markdownProfile: string };
  costs: {
    assemblyAIPerMin: number;
    deepgramPerMin: number;
    openAIPerMin: number;
    groqPerMin: number;
    llmFallbackPer1M: number;
  };
  secrets: Record<SecretKey, { set: boolean }>;
  /** The app's wording for controls that are off while offline. */
  offlineReasons: { refreshCatalog: string; testKey: string; download: string };
}

/** The panes PATCH accepts, with the settings each holds (read-only reports excluded). */
export interface SettingsPatch {
  general?: Partial<SettingsDTO["general"]>;
  recording?: Partial<SettingsDTO["recording"]>;
  transcription?: Partial<Omit<SettingsDTO["transcription"], "models">>;
  aiNotes?: Partial<Omit<SettingsDTO["aiNotes"], "warnings">>;
  vault?: Partial<SettingsDTO["vault"]>;
  costs?: Partial<SettingsDTO["costs"]>;
}

export interface ModelScores {
  /** Artificial Analysis Intelligence index, 0–100. */
  intelligence?: number;
  /** Artificial Analysis Multilingual index, 0–1. */
  multilingual?: number;
  /** Artificial Analysis Strategy and ops index, 0–100. */
  strategyAndOps?: number;
}

export interface CatalogModel {
  id: string;
  name: string;
  canonicalSlug?: string;
  promptPricePerToken: number;
  completionPricePerToken: number;
  contextLength: number;
  supportsJSON: boolean;
  scores?: ModelScores;
  /** Estimated USD per meeting hour, computed by the app. */
  hourlyUSD: { live: number; final: number };
  tags: string[];
}

export interface CatalogDTO {
  models: CatalogModel[];
  fetchedAt?: string;
  scoresFetchedAt?: string;
  /** Required wording for the benchmark scores; present whenever any model has scores. */
  attribution?: string;
  scoresProblem?: string;
  /** Why the last refresh failed; the cached models are still listed. */
  problem?: string;
  refreshing: boolean;
  costExplanation: string;
  tagRules: string;
}

export interface KeyTestResult {
  ok: boolean;
  message: string;
}
