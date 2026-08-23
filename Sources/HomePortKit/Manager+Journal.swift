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
    ///   runs unchanged — journal *and* lock degrade, they never block (the 1.2
    ///   doctrine: never an action refused because the base is inaccessible).
    /// - `locking` is declared at every call site, never deduced: a mutation of the
    ///   machine takes the per-machine lock (AD-12) before the entry opens, so a refused
    ///   attempt is never journaled; the contention error names the holder and is
    ///   rethrown untouched. Any *other* lock failure — the machinery, not a holder —
    ///   degrades like the journal: warn and run unlocked, never refuse for a broken
    ///   base. The same depth guard makes a composition one single lock.
    /// - The entry opens as `running` before the body and is closed at the end with the
    ///   captured report lines; on failure the error message joins the output and the
    ///   original error is rethrown untouched. The lock is released in `defer` either way.
    func journaled<T>(_ action: String, on machine: Machine, locking: Bool, _ body: () throws -> T) throws -> T {
        guard let history else { return try body() }
        let depthBefore = journal.enter()
        defer { journal.exit() }
        guard depthBefore == 0 else { return try body() }

        let pid = getpid()
        // The release is scoped to this exact acquisition (machine, pid, acquired_at):
        // if this action overruns the TTL and this same process reacquires the lock,
        // the late `defer` must not free the reacquired one.
        var lockStamp: Date?
        if locking {
            do {
                let stamp = Date()
                try history.acquireLock(machine: machine.name, pid: pid, now: stamp)
                lockStamp = stamp
            } catch let contention as LockContentionError {
                // The refusal the user must see — rethrown before any journal write.
                throw contention
            } catch {
                warnLockUnavailable(error)
            }
        }
        defer {
            if let lockStamp {
                do { try history.releaseLock(machine: machine.name, pid: pid, acquiredAt: lockStamp) }
                catch { warnLockStuck(machine.name, error) }
            }
        }

        // A journal write failure must never abort the action itself — but it must
        // leave a trace, or an entry silently never lands (or stays `running` forever,
        // beyond even what a lock takeover can reclaim while this process is alive).
        let id: Int64?
        do {
            id = try history.begin(action: action, machine: machine.name)
        } catch {
            id = nil
            warnJournalWriteFailure(error)
        }
        if lockStamp != nil, let id {
            do { try history.attachTask(machine: machine.name, pid: pid, taskID: id) }
            catch { warnJournalWriteFailure(error) }
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

    private func warnLockUnavailable(_ error: Error) {
        FileHandle.standardError.write(Data("warning: mutation lock unavailable, running without it — \(error)\n".utf8))
    }

    /// A stuck lock is not a journal problem: the operator must learn the machine may
    /// refuse mutations until the TTL — and that `hpm unlock` is the way out.
    private func warnLockStuck(_ machine: String, _ error: Error) {
        FileHandle.standardError.write(Data("warning: could not release the mutation lock on \(machine) — it frees after the \(Int(HistoryStore.lockTTL / 60)) min TTL, or with `hpm unlock \(machine)` — \(error)\n".utf8))
    }
}
