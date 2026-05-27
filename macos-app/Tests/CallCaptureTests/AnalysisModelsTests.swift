import Foundation
import Testing
@testable import CallCapture

@Suite("ConversationAnalysis decoding")
struct AnalysisModelsTests {
    private func decode(_ json: String) -> ConversationAnalysis? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationAnalysis.self, from: data)
    }

    @Test("decodes a full analysis payload")
    func full() throws {
        let json = #"""
        {
          "recording_type": "call_meeting",
          "num_speakers": 2,
          "speakers": [
            {"label":"You","is_self":true,"talk_seconds":30,"talk_ratio":0.6,"words":100,"words_per_min":140,"turns":5,"longest_monologue_sec":12,"dominant_emotion":"calm","valence":0.6,"arousal":0.2},
            {"label":"Speaker 1","is_self":false,"talk_ratio":0.4,"words":60,"words_per_min":120,"turns":4}
          ],
          "warnings": [],
          "sentiment": {"overall":"positive","overall_score":0.5,"by_speaker":{"You":{"label":"positive","score":0.6}},"arc":[{"t":10,"score":0.2}]},
          "insights": {"title":"Deal","summary":"Closed.","recommended_actions":["send proposal"],"action_items":["follow up Monday"],"dynamics":"You led."}
        }
        """#
        let a = decode(json)
        #expect(a != nil)
        #expect(a?.recordingType == "call_meeting")
        #expect(a?.numSpeakers == 2)
        #expect(a?.speakers.count == 2)
        #expect(a?.speakers.first?.isSelf == true)
        #expect(a?.speakers.first?.talkRatio == 0.6)
        #expect(a?.speakers.first?.dominantEmotion == "calm")
        #expect(a?.speakers[1].dominantEmotion == nil)      // absent -> nil
        #expect(a?.sentiment?.overall == "positive")
        #expect(a?.sentiment?.overallScore == 0.5)
        #expect(a?.sentiment?.bySpeaker["You"]?.score == 0.6)
        #expect(a?.sentiment?.arc.first?.t == 10)
        #expect(a?.insights?.recommendedActions == ["send proposal"])
        #expect(a?.insights?.actionItems == ["follow up Monday"])
        #expect(a?.hasContent == true)
    }

    @Test("partial payload falls back to defaults without throwing")
    func partial() throws {
        let a = decode("{}")
        #expect(a != nil)
        #expect(a?.recordingType == "call_meeting")
        #expect(a?.numSpeakers == 0)
        #expect(a?.speakers.isEmpty == true)
        #expect(a?.sentiment == nil)
        #expect(a?.insights == nil)
        #expect(a?.hasContent == false)
    }

    @Test("hasContent is true when only speakers are present")
    func hasContentSpeakers() throws {
        let a = decode(#"{"speakers":[{"label":"You","talk_ratio":1.0}]}"#)
        #expect(a?.hasContent == true)
    }

    @Test("load returns nil for a missing file")
    func missingFile() {
        let path = NSTemporaryDirectory() + "cc-missing-\(UUID().uuidString).json"
        #expect(ConversationAnalysis.load(fromPath: path) == nil)
    }

    @Test("load returns nil for malformed json")
    func malformed() throws {
        let path = NSTemporaryDirectory() + "cc-bad-\(UUID().uuidString).json"
        try "not json".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        #expect(ConversationAnalysis.load(fromPath: path) == nil)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("load decodes a written file")
    func loadFile() throws {
        let path = NSTemporaryDirectory() + "cc-ana-\(UUID().uuidString).json"
        try #"{"num_speakers":1,"speakers":[{"label":"You","talk_ratio":1.0}]}"#
            .data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        let a = ConversationAnalysis.load(fromPath: path)
        #expect(a?.numSpeakers == 1)
        #expect(a?.speakers.first?.label == "You")
        try? FileManager.default.removeItem(atPath: path)
    }
}
