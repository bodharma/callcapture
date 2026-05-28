import Foundation

/// Spoken-language choice for transcription. The raw value is the Whisper
/// language code (or "auto" for auto-detection) that gets forwarded to the
/// worker's local engine via `JobRequest.language`.
///
/// The curated list covers languages a typical user is most likely to
/// encounter; the underlying whisper.cpp supports ~100 codes, but a `Picker`
/// over all of them would be unusable. Add new cases as needed.
enum SpokenLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case english = "en"
    case ukrainian = "uk"
    case russian = "ru"
    case polish = "pl"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case czech = "cs"
    case swedish = "sv"
    case turkish = "tr"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .english: "English"
        case .ukrainian: "Ukrainian"
        case .russian: "Russian"
        case .polish: "Polish"
        case .german: "German"
        case .french: "French"
        case .spanish: "Spanish"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .dutch: "Dutch"
        case .czech: "Czech"
        case .swedish: "Swedish"
        case .turkish: "Turkish"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chinese: "Chinese"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        }
    }
}
