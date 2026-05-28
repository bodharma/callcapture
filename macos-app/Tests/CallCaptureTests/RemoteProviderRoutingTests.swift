import Foundation
import Testing
@testable import CallCapture

@Suite("RemoteProvider auto routing")
struct RemoteProviderRoutingTests {
    @Test("english/auto/latin languages route to AssemblyAI")
    func englishToAssemblyAI() {
        #expect(RemoteProvider.resolveAuto(forLanguage: "auto") == .assemblyai)
        #expect(RemoteProvider.resolveAuto(forLanguage: "en") == .assemblyai)
        #expect(RemoteProvider.resolveAuto(forLanguage: "es") == .assemblyai)
        #expect(RemoteProvider.resolveAuto(forLanguage: "fr") == .assemblyai)
        #expect(RemoteProvider.resolveAuto(forLanguage: "ja") == .assemblyai)
    }

    @Test("slavic / cyrillic / other extras route to Deepgram")
    func slavicToDeepgram() {
        #expect(RemoteProvider.resolveAuto(forLanguage: "uk") == .deepgram)
        #expect(RemoteProvider.resolveAuto(forLanguage: "ru") == .deepgram)
        #expect(RemoteProvider.resolveAuto(forLanguage: "pl") == .deepgram)
        #expect(RemoteProvider.resolveAuto(forLanguage: "cs") == .deepgram)
        #expect(RemoteProvider.resolveAuto(forLanguage: "ar") == .deepgram)
    }

    @Test("unknown languages also fall back to Deepgram (multi)")
    func unknownLanguageToDeepgram() {
        #expect(RemoteProvider.resolveAuto(forLanguage: "xx") == .deepgram)
        #expect(RemoteProvider.resolveAuto(forLanguage: "") == .deepgram)
    }
}
