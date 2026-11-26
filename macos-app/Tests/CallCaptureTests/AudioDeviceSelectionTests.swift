import Testing
@testable import CallCapture

@Suite("Audio device selection")
struct AudioDeviceSelectionTests {
    private let builtIn = AudioDeviceInfo(id: 1, uid: "built-in", name: "Built-in")
    private let headphones = AudioDeviceInfo(id: 2, uid: "headphones", name: "Headphones")

    @Test("system default follows a newly connected headset")
    func followsDefaultChanges() {
        let devices = [builtIn, headphones]
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: nil, devices: devices, defaultDevice: builtIn
        )?.uid == "built-in")
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: nil, devices: devices, defaultDevice: headphones
        )?.uid == "headphones")
    }

    @Test("a connected manual choice survives a default change")
    func keepsOverride() {
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: "built-in", devices: [builtIn, headphones], defaultDevice: headphones
        )?.uid == "built-in")
    }

    @Test("an unplugged manual choice falls back to the current default")
    func disconnectedOverride() {
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: "headphones", devices: [builtIn], defaultDevice: builtIn
        )?.uid == "built-in")
    }

    @Test("an explicit device works when there is no system default")
    func overrideWithoutDefault() {
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: "built-in", devices: [builtIn], defaultDevice: nil
        )?.uid == "built-in")
    }

    @Test("a missing or stale default never selects an arbitrary device")
    func unavailableDefault() {
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: nil, devices: [builtIn], defaultDevice: nil
        ) == nil)
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: nil, devices: [builtIn], defaultDevice: headphones
        ) == nil)
    }

    @Test("no devices means no capture source")
    func noDevices() {
        #expect(AudioDeviceEnumerator.resolveDevice(
            preferredUID: "headphones", devices: [], defaultDevice: nil
        ) == nil)
    }
}
