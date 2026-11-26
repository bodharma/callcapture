import type { CatalogDTO, CatalogModel, ModelScores, SettingsDTO } from "./types";

interface ModelOptions {
  id: string;
  name: string;
  live: number;
  final: number;
  json?: boolean;
  scores?: ModelScores;
  tags?: string[];
}

export function catalogModel({ id, name, live, final, json = true, scores, tags = [] }: ModelOptions): CatalogModel {
  return {
    id,
    name,
    promptPricePerToken: 1e-7,
    completionPricePerToken: 4e-7,
    contextLength: 128_000,
    supportsJSON: json,
    scores,
    hourlyUSD: { live, final },
    tags,
  };
}

export function catalogFixture(overrides: Partial<CatalogDTO> = {}): CatalogDTO {
  return {
    models: [
      catalogModel({
        id: "anthropic/claude-haiku-5.5",
        name: "Claude Haiku 5.5",
        live: 0.32,
        final: 0.004,
        scores: { intelligence: 52, multilingual: 0.71, strategyAndOps: 48 },
        tags: ["Budget"],
      }),
      catalogModel({ id: "text/only", name: "Text Only", live: 0.05, final: 0.001, json: false }),
      catalogModel({
        id: "anthropic/claude-sonnet-5.5",
        name: "Claude Sonnet 5.5",
        live: 6.3,
        final: 0.08,
        scores: { intelligence: 81, multilingual: 0.9, strategyAndOps: 77 },
        tags: ["Highest quality", "Strong multilingual"],
      }),
      catalogModel({ id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash", live: 1.31, final: 0.014 }),
    ],
    fetchedAt: "2026-11-26T14:58:00Z",
    attribution: "Source: Artificial Analysis (artificialanalysis.ai) via OpenRouter (openrouter.ai/rankings).",
    refreshing: false,
    costExplanation: "≈ Estimate from OpenRouter's current prices and a token model.",
    tagRules: "Highest quality: top quarter by Intelligence.",
    ...overrides,
  };
}

export function settingsFixture(change: (settings: SettingsDTO) => void = () => {}): SettingsDTO {
  const settings: SettingsDTO = {
    general: { autoProcessOnStop: true },
    recording: { outputDirectory: "/Users/test/Library/Application Support/CallCapture", keepSeparateMicTrack: false },
    transcription: {
      engine: "local_whisper",
      whisperModel: "base",
      remoteProvider: "groq",
      models: { diarization: { ready: true, downloading: false }, emotion: { ready: false, downloading: false } },
    },
    aiNotes: {
      provider: "openrouter",
      finalModel: "anthropic/claude-sonnet-5.5",
      liveModel: "anthropic/claude-haiku-5.5",
      localModel: "",
      localBaseURL: "http://localhost:11434/v1",
      warnings: {},
    },
    vault: { obsidianVault: "/Users/test/Vault", folderPattern: "_meetings/{YYYY-MM}/", markdownProfile: "meeting_notes" },
    costs: { assemblyAIPerMin: 0.0035, deepgramPerMin: 0.0043, openAIPerMin: 0.006, groqPerMin: 0.0007, llmFallbackPer1M: 3 },
    secrets: { openrouter: { set: true }, assemblyai: { set: false }, deepgram: { set: false }, remote: { set: false } },
    offlineReasons: {
      refreshCatalog: "Offline — refreshing needs an internet connection.",
      testKey: "Offline — testing the key needs internet.",
      download: "Offline — downloading needs an internet connection. Downloaded models work offline.",
    },
  };
  change(settings);
  return settings;
}
