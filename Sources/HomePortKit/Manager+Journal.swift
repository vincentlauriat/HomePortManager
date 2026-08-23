import Foundation

/// Depth counter and report-capture buffer for `journaled`. A manager runs one
/// user action at a time (one manager per machine in `forEachMachine`, one per
/// `run` in the app), but report lines can arrive from helper threads, so the
/// state is lock-protected anyway.
final class JournalState {
    private let lock = NSLock()
    private var depth = 0
    private var lines: [String] = []

    /// Returns the depth *before* entering — 0 means this is the user-invoked action.
    func enter() -> Int {
        lock.lock(); defer { lock.unlock() }
        let before = depth
        depth += 1
        if before == 0 { lines = [] }
        return before
    }

    func exit() {
        lock.lock(); defer { lock.unlock() }
        depth -= 1
    }

    /// Report lines only matter while a journaled action is in flight.
    func capture(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if depth > 0 { lines.append(line) }
    }

    func drain() -> String {
        lock.lock(); defer { lock.unlock() }
        let output = lines.joined(separator: "\n")
        lines = []
        return output
    }
}

extension HomeportManager {
    /// The journal seam: every user-initiated action wraps its body here, so CLI and
    /// app get identical journaling by construction (the kit is the common path).
    ///
    /// - A composed action (`update` → backup + install) journals **one** entry, at the
    ///   level the user invoked: nested calls see depth > 0 and run their body as-is.
    /// - `history == nil` (state directory unusable) is a complete no-op: the action
    ///   runs unchanged — the journal degrades, it never blocks.
    /// - The entry opens as `running` before the body and is closed at the end with the
    ///   captured report lines; on failure the error message joins the output and the
    ///   original error is rethrown untouched.
    func journaled<T>(_ action: String, on machine: Machine, _ body: () throws -> T) throws -> T {
        guard let history else { return try body() }
        let depthBefore = journal.enter()
        defer { journal.exit() }
        guard depthBefore == 0 else { return try body() }

        // A journal write failure must never abort the action itself — but it must
        // leave a trace, or an entry silently never lands (or stays `running` forever,
        // which not even 1.3 reclaims while this process is alive).
        let id: Int64?
        do {
            id = try history.begin(action: action, machine: machine.name)
        } catch {
            id = nil
            warnJournalWriteFailure(error)
        }
        do {
            let result = try body()
            if let id {
                do { try history.finish(id: id, status: .success, output: journal.drain()) }
                catch { warnJournalWriteFailure(error) }
            }
            return result
        } catch {
            if let id {
                let captured = journal.drain()
                let output = captured.isEmpty ? "\(error)" : "\(captured)\n\(error)"
                do { try history.finish(id: id, status: .failure, output: output) }
                catch { warnJournalWriteFailure(error) }
            }
            throw error
        }
    }

    private func warnJournalWriteFailure(_ error: Error) {
        FileHandle.standardError.write(Data("warning: task journal write failed — \(error)\n".utf8))
    }
}
