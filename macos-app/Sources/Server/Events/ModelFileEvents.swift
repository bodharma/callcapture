import Foundation

/// Changes written by model-layer code the app doesn't otherwise observe, whichever
/// window made them: speaker names (`SpeakerNames.save`) and saved live maps
/// (`LiveMeetingModel.persist` while not recording). The app forwards them to the web UI.
enum ModelFileEvents {
    enum Change: Sendable, Equatable {
        case speakerNames(audioPath: String)
        case liveMap(sessionID: String)
    }

    private static let observers = NSLockedValue<[UUID: @Sendable (Change) -> Void]>([:])

    static func notify(_ change: Change) {
        for observer in observers.get().values {
            observer(change)
        }
    }

    @discardableResult
    static func observe(_ observer: @escaping @Sendable (Change) -> Void) -> UUID {
        let id = UUID()
        observers.mutate { $0[id] = observer }
        return id
    }

    static func remove(_ id: UUID) {
        observers.mutate { $0[id] = nil }
    }

    /// Posts `sessionChanged` for renamed speakers (when `sessionIDForAudio` knows the
    /// file) and `liveDocument` for edited saved maps.
    @discardableResult
    static func forward(to hub: EventHub, sessionIDForAudio: @escaping @Sendable (String) -> String?) -> UUID {
        observe { change in
            switch change {
            case .speakerNames(let audioPath):
                if let id = sessionIDForAudio(audioPath) { hub.post(.sessionChanged(id: id)) }
            case .liveMap(let sessionID):
                if !sessionID.isEmpty { hub.post(.liveDocument(sessionID: sessionID)) }
            }
        }
    }
}
