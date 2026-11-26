import Foundation

/// Runs blocking work (file scans, audio decoding) on a GCD thread and awaits
/// it, so neither the server's event loops nor Swift's cooperative pool stall.
enum Blocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
