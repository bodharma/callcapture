import Foundation

/// Transcription engine selection: local Whisper or a remote API provider.
enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case localWhisper = "local_whisper"
    case remote

    var displayName: String {
        switch self {
        case .localWhisper: "Local Whisper"
        case .remote: "Remote API"
        }
    }
}

/// Whisper model size for local transcription.
enum WhisperModel: String, Codable, CaseIterable, Sendable {
    case base
    case small
    case medium

    var displayName: String {
        switch self {
        case .base: "Base (fastest)"
        case .small: "Small (balanced)"
        case .medium: "Medium (accurate)"
        }
    }
}

/// Remote transcription provider when using a cloud API.
enum RemoteProvider: String, Codable, CaseIterable, Sendable {
    /// Picks AssemblyAI or Deepgram per recording based on `session.language`.
    /// Requires BOTH API keys configured.
    case auto
    case assemblyai
    case deepgram
    case groq
    case openai

    var displayName: String {
        switch self {
        case .auto: "Auto (by language — AssemblyAI + Deepgram)"
        case .assemblyai: "AssemblyAI (diarization, sentiment, summaries, topics)"
        case .deepgram: "Deepgram (diarization, sentiment, topics)"
        case .groq: "Groq (fast Whisper)"
        case .openai: "OpenAI Whisper"
        }
    }

    /// Short label used in tight UI contexts (SecureField, badges) — the long
    /// `displayName` overflows row width in macOS `.formStyle(.grouped)` and
    /// can collapse the bound field to zero width, hiding it entirely.
    var shortName: String {
        switch self {
        case .auto: "Auto"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .deepgram: "Deepgram"
        case .assemblyai: "AssemblyAI"
        }
    }

    /// Whether this provider returns rich audio analytics beyond the raw
    /// transcript (speaker diarization, sentiment, topics, summarization, …).
    /// Used to surface a hint in Settings and to widen the post-processing
    /// pipeline later if/when we ingest the provider-supplied analytics.
    var hasAnalytics: Bool {
        switch self {
        case .groq, .openai: false
        case .auto, .deepgram, .assemblyai: true
        }
    }
}

extension RemoteProvider {
    /// Languages that route to AssemblyAI when `.auto` is selected. Anything
    /// else goes to Deepgram Nova-3 (broader multilingual coverage with
    /// diarization + sentiment).
    static let assemblyAIPreferredLanguages: Set<String> = [
        "auto", "en", "es", "fr", "de", "it", "pt", "nl", "ja", "zh", "ko", "hi",
    ]

    /// Resolve `.auto` to a concrete provider for the given Whisper language
    /// code (i.e. the `Session.language` value).
    static func resolveAuto(forLanguage language: String) -> RemoteProvider {
        Self.assemblyAIPreferredLanguages.contains(language) ? .assemblyai : .deepgram
    }
}

/// LLM engine for post-processing transcripts.
enum LLMEngine: String, Codable, CaseIterable, Sendable {
    case claude
    case openai
    case localExperimental = "local_experimental"

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .localExperimental: "Local (Experimental)"
        }
    }
}

/// Where LLM post-processing runs.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openrouter
    case local

    var displayName: String {
        switch self {
        case .openrouter: "OpenRouter (cloud)"
        case .local: "Local (Ollama)"
        }
    }
}

/// Markdown output profile for transcript formatting.
enum MarkdownProfile: String, Codable, CaseIterable, Sendable {
    case meetingNotes = "meeting_notes"
    case fullTranscript = "full_transcript"
    case obsidian

    var displayName: String {
        switch self {
        case .meetingNotes: "Meeting Notes"
        case .fullTranscript: "Full Transcript"
        case .obsidian: "Obsidian"
        }
    }
}
