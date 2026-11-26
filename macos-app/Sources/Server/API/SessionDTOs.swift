import Foundation

// JSON shapes of the sessions API (camelCase keys, ISO 8601 dates). Optional
// fields are omitted when absent unless noted. Speaker names are applied here,
// the way the SwiftUI views apply them.

struct SessionDTO: Encodable {
    struct Costs: Encodable {
        let transcription: Double?
        let processing: Double?
        let total: Double?
        let currency: String?
    }

    let id: String
    let title: String
    let sourceApp: String
    let startedAt: Date
    let endedAt: Date?
    let durationSec: Double?
    let status: String
    let recordingType: String
    let language: String
    let notesLanguage: String
    let engine: String?
    let warning: String?
    /// Why the last processing run failed, as the session record holds it.
    let error: String?
    let costs: Costs
    let audioFileName: String
    let hasAudio: Bool
    let hasTranscript: Bool
    let hasNote: Bool
    let hasAnalysis: Bool
    let hasLiveMap: Bool

    init(_ session: Session) {
        id = session.id
        title = session.title
        sourceApp = session.sourceApp
        startedAt = session.startedAt
        endedAt = session.endedAt
        durationSec = session.durationSec
        status = session.status
        recordingType = session.recordingType
        language = session.language
        notesLanguage = session.notesLanguage
        engine = session.engineUsed
        warning = session.warningMessage.flatMap { $0.isEmpty ? nil : $0 }
        error = session.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
        costs = Costs(
            transcription: session.costTranscription, processing: session.costProcessing,
            total: CostFormat.total(session.costTranscription, session.costProcessing),
            currency: session.costCurrency)
        audioFileName = URL(fileURLWithPath: session.audioPath).lastPathComponent
        hasAudio = SessionFiles.exists(session.audioPath)
        hasTranscript = SessionFiles.exists(session.transcriptRawPath)
        hasNote = SessionFiles.exists(session.transcriptMarkdownPath)
        hasAnalysis = SessionFiles.exists(session.analysisPath)
        hasLiveMap = SessionFiles.exists(SavedLiveMap.path(audioPath: session.audioPath))
    }
}

/// `speaker` is the worker's label (rename by it); `name` is what to display.
struct TranscriptLineDTO: Encodable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let name: String?

    init(_ line: TranscriptLine, names: SpeakerNames) {
        (start, end, text, speaker) = (line.start, line.end, line.text, line.speaker)
        name = names.display(line.speaker)
    }
}

struct SpeakerDTO: Encodable {
    let label: String
    let name: String
    let renamed: Bool

    /// Labels in order of first appearance in the transcript, then any only the analysis knows.
    static func list(lines: [TranscriptLine], analysis: ConversationAnalysis?, names: SpeakerNames) -> [SpeakerDTO] {
        var seen = Set<String>()
        let labels = (lines.compactMap(\.speaker) + (analysis?.speakers.map(\.label) ?? []))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return labels.map { label in
            let name = names.display(label) ?? label
            return SpeakerDTO(label: label, name: name, renamed: name != label)
        }
    }
}

struct SearchHitDTO: Encodable {
    let id: String
    let sessionId: String
    let title: String
    /// Seconds into the transcript; absent for title and note hits.
    let time: Double?
    let excerpt: String

    init(_ hit: SearchHit) {
        (id, sessionId, title, time, excerpt) = (hit.id, hit.sessionID, hit.title, hit.time, hit.excerpt)
    }
}

/// `{"markdown": String | null}` (null always present).
struct NoteDTO: Encodable {
    let markdown: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(markdown, forKey: .markdown)
    }

    private enum CodingKeys: String, CodingKey { case markdown }
}

/// `202 {"started": true}` from `POST /reprocess`.
struct StartedDTO: Encodable {
    let started = true
}

struct VaultDTO: Encodable {
    let path: String
}

/// The worker's analysis with names applied to speakers and to insight text.
struct AnalysisDTO: Encodable {
    struct Speaker: Encodable {
        let label: String
        let name: String
        let isSelf: Bool
        let talkSeconds: Double
        let talkRatio: Double
        let words: Int
        let wordsPerMin: Double
        let turns: Int
        let longestMonologueSec: Double
        let dominantEmotion: String?
        let valence: Double?
        let arousal: Double?
    }

    struct Score: Encodable {
        let label: String
        let score: Double
    }

    struct ArcPoint: Encodable {
        let t: Double
        let score: Double
    }

    /// `bySpeaker` stays keyed by the original label; match it against `speakers`.
    struct Sentiment: Encodable {
        let overall: String
        let overallScore: Double
        let bySpeaker: [String: Score]
        let arc: [ArcPoint]
    }

    struct Insights: Encodable {
        let title: String
        let summary: String
        let keyPoints: [String]
        let actionItems: [String]
        let recommendedActions: [String]
        let dynamics: String
        let opportunities: [String]
        let reflections: [String]
        let outline: [String]
        let keyConcepts: [String]
        let qa: [String]
        let takeaways: [String]
    }

    let recordingType: String
    let numSpeakers: Int
    let speakers: [Speaker]
    let warnings: [String]
    let sentiment: Sentiment?
    let insights: Insights?

    init(_ analysis: ConversationAnalysis, names: SpeakerNames) {
        recordingType = analysis.recordingType
        numSpeakers = analysis.numSpeakers
        warnings = analysis.warnings
        speakers = analysis.speakers.map {
            Speaker(
                label: $0.label, name: names.display($0.label) ?? $0.label, isSelf: $0.isSelf,
                talkSeconds: $0.talkSeconds, talkRatio: $0.talkRatio, words: $0.words,
                wordsPerMin: $0.wordsPerMin, turns: $0.turns, longestMonologueSec: $0.longestMonologueSec,
                dominantEmotion: $0.dominantEmotion, valence: $0.valence, arousal: $0.arousal)
        }
        sentiment = analysis.sentiment.map {
            Sentiment(
                overall: $0.overall, overallScore: $0.overallScore,
                bySpeaker: $0.bySpeaker.mapValues { Score(label: $0.label, score: $0.score) },
                arc: $0.arc.map { ArcPoint(t: $0.t, score: $0.score) })
        }
        insights = analysis.insights.map { source in
            let text = { names.apply(to: $0) }
            let list = { (items: [String]) in items.map(text) }
            return Insights(
                title: text(source.title), summary: text(source.summary), keyPoints: list(source.keyPoints),
                actionItems: list(source.actionItems), recommendedActions: list(source.recommendedActions),
                dynamics: text(source.dynamics), opportunities: list(source.opportunities),
                reflections: list(source.reflections), outline: list(source.outline),
                keyConcepts: list(source.keyConcepts), qa: list(source.qa), takeaways: list(source.takeaways))
        }
    }
}
