import Foundation

/// The kind of audio a session captured. Determines which processing runs
/// (diarization on/off) and which note template/insight prompt is used.
/// Metrics, sentiment, acoustic emotion, and insights run for every type.
enum RecordingType: String, Codable, CaseIterable, Sendable, Identifiable {
    case callMeeting = "call_meeting"
    case voiceMemo = "voice_memo"
    case lecture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .callMeeting: "Call / Meeting"
        case .voiceMemo: "Voice Memo"
        case .lecture: "Lecture"
        }
    }

    /// Whether speaker diarization runs for this type.
    var diarize: Bool {
        switch self {
        case .callMeeting: true
        case .voiceMemo: false
        case .lecture: false
        }
    }

    /// Identifier for the note template / LLM prompt template used downstream.
    var noteTemplate: String {
        switch self {
        case .callMeeting: "call_meeting"
        case .voiceMemo: "voice_memo"
        case .lecture: "lecture"
        }
    }
}
