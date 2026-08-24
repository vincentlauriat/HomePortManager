import Foundation

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunner {
    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult

    /// Runs a long-lived command and hands back its stdout as it arrives. Defaulted in the
    /// extension below so a double that only answers `run` stays a valid conformer.
    func stream(_ executable: String, _ arguments: [String], stdin: String?) throws -> ProcessOutputStream
}

public extension ProcessRunner {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, stdin: nil)
    }

    func stream(_ executable: String, _ arguments: [String]) throws -> ProcessOutputStream {
        try stream(executable, arguments, stdin: nil)
    }

    func stream(_ executable: String, _ arguments: [String], stdin: String?) throws -> ProcessOutputStream {
        throw HPMError("this runner cannot stream '\(executable)'")
    }
}

/// Holds the two concurrent drains' results. Each stream is written once on its own queue
/// and read only after `DispatchGroup.wait`, which is what orders the writes before the
/// read; the lock guards the two `async` blocks against each other.
private final class OutputCollector {
    enum Stream { case out, err }

    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func put(_ stream: Stream, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .out: out = data
        case .err: err = data
        }
    }

    var pair: (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}

public struct DefaultProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        try process.run()

        // Both pipes drain concurrently, and both drains start before stdin is written.
        //
        // Read sequentially, a child that fills stderr's ~64KiB buffer while the parent
        // blocks on stdout blocks in turn on its own write: it never reaches EOF on stdout,
        // the parent never returns, and the app freezes with no error to show. The commands
        // this app runs — `apt` and `ssh` under update, doctor and config-pull — are exactly
        // the verbose-on-stderr kind.
        //
        // Writing stdin before draining has the same shape: the child can fill either output
        // buffer before it has finished reading its input, so the write blocks forever.
        let collected = OutputCollector()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "fr.homeport.process-drain", attributes: .concurrent)
        queue.async(group: group) {
            collected.put(.out, outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        queue.async(group: group) {
            collected.put(.err, errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }

        group.wait()
        process.waitUntilExit()

        let (outData, errData) = collected.pair
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    public func stream(_ executable: String, _ arguments: [String], stdin: String?) throws -> ProcessOutputStream {
        let follow = ProcessFollow(executable: executable, arguments: arguments)
        let lines = AsyncStream<String> { continuation in
            follow.attach(continuation)
            // The consumer dropping the stream — a cancelled task, a released view — has to
            // kill the child. Without this an ssh outlives the tab that started it.
            continuation.onTermination = { _ in follow.stop() }
        }
        do {
            try follow.launch(stdin: stdin)
        } catch {
            follow.stop()
            throw error
        }
        return ProcessOutputStream(lines: lines,
                                   failure: { follow.failure },
                                   stop: { follow.stop() })
    }
}

/// The live half of `DefaultProcessRunner.stream`: one child process, its two pipes, and the
/// continuation they feed. Every mutable field is behind `lock`, and nothing that can call
/// back out — `yield`, `finish`, `terminate` — is ever done while holding it: `finish()` runs
/// `onTermination` synchronously on the calling thread, and `onTermination` calls `stop()`,
/// which takes this very lock.
private final class ProcessFollow: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()

    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var splitter = LineSplitter()
    /// Undecoded bytes: a chunk boundary can fall inside a multi-byte character, so decoding
    /// happens only up to the last newline — a byte a UTF-8 sequence can never contain.
    private var carry = Data()
    private var stderrText = ""
    private var stopped = false
    private var finished = false
    private var storedFailure: String?

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func attach(_ continuation: AsyncStream<String>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func launch(stdin: String?) throws {
        // Empty means end of file on a pipe, and Foundation keeps the handler armed and keeps
        // re-firing it on a descriptor that will never yield again: returning without
        // disarming spins a dispatch queue until `terminationHandler` runs. Whatever the
        // pipes still hold is drained there, so nothing is lost by going quiet here.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.lock()
            self.stderrText += String(decoding: data, as: UTF8.self)
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }
        if stdin != nil {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        if let stdin {
            // `write(_:)` raises an Objective-C exception Swift cannot catch, and a child that
            // died before reading — an ssh that failed to connect — makes this write EPIPE.
            // The throwing form turns that crash into a stream that simply ends.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        carry.append(data)
        var lines: [String] = []
        if let newline = carry.lastIndex(of: 0x0A) {
            let boundary = carry.index(after: newline)
            let head = Data(carry[..<boundary])
            carry = Data(carry[boundary...])
            lines = splitter.push(String(decoding: head, as: UTF8.self))
        }
        let continuation = self.continuation
        lock.unlock()
        for line in lines { continuation?.yield(line) }
    }

    /// The child is gone: read whatever the pipes still hold, publish the last lines, and
    /// end the stream. Handlers are cleared first so nothing races this drain.
    ///
    /// The `finished` claim comes *before* the two drains, not after: `stop()` closes both
    /// read handles, and the child it terminated then fires this handler — draining first
    /// would mean reading two descriptors `stop()` has already closed.
    private func processTerminated(status: Int32) {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil

        lock.lock()
        if let restOut { carry.append(restOut) }
        if let restErr { stderrText += String(decoding: restErr, as: UTF8.self) }
        var lines = splitter.push(String(decoding: carry, as: UTF8.self))
        carry = Data()
        if let tail = splitter.flush() { lines.append(tail) }
        // A process we killed exits non-zero by construction: that is our doing, not a fault.
        if !stopped, status != 0 {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            storedFailure = detail.isEmpty ? "exited with code \(status)" : "exit \(status): \(detail)"
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        for line in lines { continuation?.yield(line) }
        continuation?.finish()
        closeHandles()
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let alreadyFinished = finished
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        // Handlers off *before* the child is signalled and the handles close: a handler
        // firing on a closed descriptor is the crash this ordering exists to prevent.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        // The consumer must not hang waiting for a child that may take its time dying.
        continuation?.finish()
        if !alreadyFinished { closeHandles() }
    }

    private func closeHandles() {
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
    }
}
