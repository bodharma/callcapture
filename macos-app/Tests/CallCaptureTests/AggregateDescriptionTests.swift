import CoreAudio
import Foundation
import Testing
@testable import CallCapture

/// `tapautostart` makes AudioDeviceStart wait until a tapped process plays audio
/// (CoreAudio AudioHardware.h). With a mic as clock master that silently produced
/// 0-frame recordings whenever nothing was playing, losing the mic too.
@Suite("Aggregate device description")
struct AggregateDescriptionTests {
    @available(macOS 14.2, *)
    @Test("with a microphone, IO starts immediately (no tap auto-start) and the mic is the clock master")
    func micStartsImmediately() {
        let tap = UUID()
        let description = AudioCaptureManager.aggregateDescription(
            aggregateUID: "agg", tapUUID: tap, micDeviceUID: "mic-uid")
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "mic-uid")
        let subDevices = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        #expect(subDevices?.first?[kAudioSubDeviceUIDKey] as? String == "mic-uid")
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        #expect(taps?.first?[kAudioSubTapUIDKey] as? String == tap.uuidString)
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
    }

    @available(macOS 14.2, *)
    @Test("tap-only keeps auto-start: with no real device the tap drives the aggregate")
    func tapOnlyAutoStarts() {
        let description = AudioCaptureManager.aggregateDescription(
            aggregateUID: "agg", tapUUID: UUID(), micDeviceUID: nil)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] == nil)
        #expect((description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])?.isEmpty == true)
    }
}
