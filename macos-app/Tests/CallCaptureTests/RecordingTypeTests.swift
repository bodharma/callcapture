import Testing
@testable import CallCapture

@Suite("RecordingType")
struct RecordingTypeTests {
    @Test("call/meeting diarizes, others do not")
    func diarizeFlags() {
        #expect(RecordingType.callMeeting.diarize == true)
        #expect(RecordingType.voiceMemo.diarize == false)
        #expect(RecordingType.lecture.diarize == false)
    }

    @Test("raw values are stable for persistence")
    func rawValues() {
        #expect(RecordingType.callMeeting.rawValue == "call_meeting")
        #expect(RecordingType.voiceMemo.rawValue == "voice_memo")
        #expect(RecordingType.lecture.rawValue == "lecture")
    }

    @Test("all cases have non-empty display names")
    func displayNames() {
        for type in RecordingType.allCases {
            #expect(!type.displayName.isEmpty)
        }
    }
}
