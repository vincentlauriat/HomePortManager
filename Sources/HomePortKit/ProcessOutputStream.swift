import Foundation

/// A running command's output, delivered line by line until it ends or is stopped.
///
/// Deliberately built from a plain `AsyncStream` plus a stop closure rather than from a
/// `Process`: the follow plumbing is then exercisable by a test double that replays a fixed
/// array of lines, with no child process anywhere near the test.
///
/// `run` reports a transport failure by throwing; a stream cannot — by the time ssh dies the
/// call has long returned. `failure` is where that verdict lands instead: it is `nil` while
/// the stream is alive, and carries the verdict once `lines` has finished. A stream stopped
/// on purpose never sets it — a killed child exits non-zero and that is not a failure.
public final class ProcessOutputStream: @unchecked Sendable {
    public let lines: AsyncStream<String>

    private let lock = NSLock()
    private let onStop: () -> Void
    private let failureSource: () -> String?
    private var stopped = false

    public init(lines: AsyncStream<String>,
                failure: @escaping () -> String? = { nil },
                stop: @escaping () -> Void) {
        self.lines = lines
        self.failureSource = failure
        self.onStop = stop
    }

    /// Non-zero exit and whatever the command wrote on stderr, as produced — machine
    /// content, shown mono, never translated. `nil` while the stream is still running.
    public var failure: String? { failureSource() }

    /// Idempotent, and called from every exit an ssh process could otherwise survive: the
    /// consumer's `onTermination`, the store's prune, the view's disappearance, and `deinit`.
    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        onStop()
    }

    deinit {
        stop()
    }
}
