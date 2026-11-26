import Darwin
import Foundation

/// Pipes the app writes to a child process through.
///
/// On macOS, writing to a pipe whose reader has exited delivers SIGPIPE, which kills the whole app by
/// default. `F_SETNOSIGPIPE` on the write end turns that into an `EPIPE` error the caller can handle,
/// without ignoring SIGPIPE process-wide.
enum PipeSafety {
    /// Call right after the pipe is created, before anything is written.
    static func suppressSIGPIPE(on pipe: Pipe) {
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
}
