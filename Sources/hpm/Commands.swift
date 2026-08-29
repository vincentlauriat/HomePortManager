import ArgumentParser
import Foundation
import HomePortKit

// MARK: - machine

struct MachineCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine",
        abstract: "Manage the fleet inventory (~/.config/hpm/fleet.yaml).",
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Declare a machine.")
        @Argument(help: "Machine name (e.g. raspcorse).") var name: String
        @Option(help: "SSH destination (host alias or user@host).") var ssh: String
        @Option(help: "Homeport HTTP port on the machine.") var port: Int = 80
        @Option(help: "Free-form note.") var notes: String?

        func run() throws {
            try FleetStore().add(Machine(name: name, ssh: ssh, port: port, notes: notes))
            print("✓ \(name) added")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List declared machines.")
        func run() throws {
            let machines = try FleetStore().load().machines
            guard !machines.isEmpty else {
                print("No machines. Add one with: hpm machine add <name> --ssh <host>")
                return
            }
            for machine in machines {
                let notes = machine.notes.map { "  — \($0)" } ?? ""
                print("\(machine.name)  ssh=\(machine.ssh)  port=\(machine.port)\(notes)")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a machine from the inventory (does not touch the machine).")
        @Argument var name: String
        func run() throws {
            guard try FleetStore().remove(named: name) else {
                print("'\(name)' was not in the inventory")
                return
            }
            print("✓ \(name) removed from inventory")
            // Best-effort, like every other hpm.db failure in this file: a base that does
            // not exist yet has no markers to drop, and a failure to clear one must not
            // turn a successful inventory removal into an error.
            if FileManager.default.fileExists(atPath: expandPath(HistoryStore.defaultPath)) {
                do {
                    let store = try HistoryStore()
                    Self.clearMarkers(for: name, in: store) { message in
                        FileHandle.standardError.write(Data(message.utf8))
                    }
                } catch {
                    // The name is interpolated once, never adjacent to another single
                    // quote: a template producing `'\(name)''s markers` reads as a typo,
                    // not a machine name (2ᵉ passe de revue, patch).
                    FileHandle.standardError.write(Data(
                        "warning: could not open hpm.db to clear notified/event markers for '\(name)' — \(error)\n".utf8))
                }
            }
        }

        /// The testable core: clears the events cursor and the notification marker
        /// independently, so one failing does not mask the other, and each warning names
        /// the marker that actually failed rather than a generic one that could be wrong
        /// about which side broke.
        static func clearMarkers(for name: String, in store: HistoryStore, report: (String) -> Void) {
            do {
                try store.clearEventCursor(machine: name)
            } catch {
                report("warning: could not clear the events cursor for '\(name)' — \(error)\n")
            }
            do {
                try store.clearNotifiedUpTo(machine: name)
            } catch {
                report("warning: could not clear the notified marker for '\(name)' — \(error)\n")
            }
        }
    }
}

// MARK: - status

struct StatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Fleet status.")
    @Argument(help: "Machine name (omit with --all).") var machine: String?
    @Flag(help: "All declared machines.") var all = false

    func run() throws {
        let targets = try resolveTargets(machine: machine, all: all || machine == nil)
        let manager = makeManager(journal: false)
        let latest = (try? manager.releases.latest().tag) ?? "?"

        // Query machines concurrently; each status is one ssh round-trip.
        var statuses = [String: MachineStatus]()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let status = try? makeManager(journal: false) { _ in }.status(of: targets[i])
            lock.lock(); statuses[targets[i].name] = status; lock.unlock()
        }

        var rows: [[String]] = [["NAME", "VERSION", "LATEST", "SERVICE", "UPTIME", "HEALTH", "DISK", "SSH", "LAST BACKUP"]]
        for target in targets {
            guard let status = statuses[target.name] else { continue }
            rows.append([
                status.name,
                status.installedVersion,
                latest,
                status.reachable ? (status.serviceActive ? "active" : "inactive") : "unreachable",
                formatUptime(status.uptimeSeconds),
                status.reachable ? (status.healthzOK ? "OK" : "FAIL") : "-",
                status.diskUsedPercent.map { "\($0)%" } ?? "-",
                status.sshLatencyMs.map { "\($0)ms" } ?? "-",
                status.lastBackup ?? "none",
            ])
        }
        printTable(rows)
    }
}

/// Column-aligned plain-text table, shared by status and tasks.
func printTable(_ rows: [[String]]) {
    guard let header = rows.first else { return }
    let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
    for row in rows {
        print(zip(row, widths).map { $0.padding(toLength: $1 + 2, withPad: " ", startingAt: 0) }.joined())
    }
}

// MARK: - releases

struct ReleasesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "releases", abstract: "List available Homeport releases on GitHub.")
    func run() throws {
        for release in try makeManager(journal: false).releases.list() {
            let date = release.publishedAt.map { "  (\($0))" } ?? ""
            print("\(release.tag)\(date)")
        }
    }
}

// MARK: - prereqs

struct PrereqsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prereqs", abstract: "Check (and optionally fix) machine prerequisites.")
    @Argument var machine: String
    @Flag(help: "Install missing packages via apt-get.") var fix = false

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        let checks = try makeManager().prereqs(on: target, fix: fix)
        for check in checks {
            print("\(check.ok ? "✓" : "✗") \(check.name)\(check.ok ? "" : " — \(check.detail)")")
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode(1) }
    }
}

// MARK: - install / update

struct InstallCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install Homeport on a machine.")
    @Argument var machine: String
    @Option(help: "Tag to install (default: latest release).") var version: String?

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        try makeManager().install(on: target, version: version)
    }
}

struct UpdateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update Homeport (automatic backup first).")
    @Argument(help: "Machine name (omit with --all).") var machine: String?
    @Flag(help: "All declared machines.") var all = false
    @Option(help: "Tag to install (default: latest release).") var version: String?
    @Flag(name: .customLong("yes"), help: "Skip confirmation.") var assumeYes = false

    func run() throws {
        let targets = try resolveTargets(machine: machine, all: all)
        let names = targets.map(\.name).joined(separator: ", ")
        let tag = version ?? "the latest release"
        guard confirm("Update \(names) to \(tag)? A backup is taken first, then the service restarts.", assumeYes: assumeYes) else {
            print("Aborted.")
            return
        }
        try forEachMachine(targets) { target, manager in
            try manager.update(on: target, version: version)
        }
    }
}

// MARK: - backup / restore

struct BackupCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "backup", abstract: "Back up config + data (kept on the machine and on this Mac).")
    @Argument(help: "Machine name (omit with --all).") var machine: String?
    @Flag(help: "All declared machines.") var all = false

    func run() throws {
        let targets = try resolveTargets(machine: machine, all: all)
        try forEachMachine(targets) { target, manager in
            let path = try manager.backup(on: target)
            manager.report("✓ \(path)")
        }
    }
}

struct RestoreCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore config + data from a backup archive.")
    @Argument var machine: String
    @Flag(help: "Use the newest local archive (default).") var latest = false
    @Option(help: "Path to a specific archive.") var archive: String?
    @Flag(name: .customLong("yes"), help: "Skip confirmation.") var assumeYes = false

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        let manager = makeManager()
        let chosen = archive ?? manager.latestLocalBackup(for: target.name)
        guard let chosen else {
            throw HPMError("no local backup found for '\(target.name)' in \(manager.localBackupDir(for: target.name)) — run: hpm backup \(target.name)")
        }
        guard confirm("Restore \((chosen as NSString).lastPathComponent) onto \(target.name)? This replaces its config and data.", assumeYes: assumeYes) else {
            print("Aborted.")
            return
        }
        try manager.restore(on: target, archive: chosen)
    }
}

// MARK: - config

struct ConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage /etc/homeport files (pull, diff, push).",
        subcommands: [Pull.self, Diff.self, Push.self]
    )

    struct Pull: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch config files locally.")
        @Argument var machine: String
        func run() throws {
            let target = try FleetStore().machine(named: machine)
            let manager = makeManager()
            let files = try manager.configPull(from: target)
            print("Pulled to \(manager.configDir(for: target.name)):")
            files.forEach { print("  \($0)") }
        }
    }

    struct Diff: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Diff local copies against the machine.")
        @Argument var machine: String
        @Argument(help: "One file (default: every pulled file).") var file: String?
        func run() throws {
            let target = try FleetStore().machine(named: machine)
            let diff = try makeManager(journal: false).configDiff(on: target, file: file)
            print(diff.isEmpty ? "No differences." : diff)
        }
    }

    struct Push: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Push local copies to the machine (shows the diff first).")
        @Argument var machine: String
        @Argument(help: "One file (default: every pulled file).") var file: String?
        @Flag(name: .customLong("yes"), help: "Skip confirmation.") var assumeYes = false

        func run() throws {
            let target = try FleetStore().machine(named: machine)
            let manager = makeManager()
            let diff = try manager.configDiff(on: target, file: file)
            guard !diff.isEmpty else {
                print("Nothing to push — local and remote are identical.")
                return
            }
            print(diff)
            guard confirm("Apply these changes to \(target.name)?", assumeYes: assumeYes) else {
                print("Aborted.")
                return
            }
            try manager.configPush(to: target, file: file)
        }
    }
}

// MARK: - logs / restart / doctor

struct LogsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show the homeport service journal.")
    @Argument var machine: String
    @Option(name: [.customShort("n"), .customLong("lines")], help: "Number of lines.") var lines: Int = 50
    @Flag(name: [.customShort("f"), .customLong("follow")], help: "Stream live (Ctrl-C to quit).") var follow = false

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        if follow {
            // Live stream: hand the terminal to ssh directly (Ctrl-C stops it).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-t", target.ssh, "sudo journalctl -u homeport.service -n \(lines) -f --no-pager"]
            try process.run()
            process.waitUntilExit()
        } else {
            print(try makeManager(journal: false).logs(on: target, lines: lines), terminator: "")
        }
    }
}

struct RestartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart the homeport service and verify healthz.")
    @Argument var machine: String

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        try makeManager().restart(on: target)
    }
}

struct DoctorCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Full diagnosis: prereqs, service, healthz, version coherence, disk, config drift.")
    @Argument var machine: String

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        let checks = try makeManager().doctor(on: target)
        for check in checks {
            print("\(check.ok ? "✓" : "✗") \(check.name)\(check.ok ? "" : " — \(check.detail)")")
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode(1) }
    }
}

// MARK: - tasks

struct TasksCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks", abstract: "Show the journal of actions run from this Mac.")
    @Option(name: [.customShort("m"), .customLong("machine")], help: "Only this machine's tasks.") var machine: String?
    @Option(name: [.customShort("n"), .customLong("limit")], help: "Number of entries (default: 50).") var limit: Int?
    @Option(help: "Show one entry in full, with its captured output.") var id: Int64?

    /// Read-only by design: `hpm tasks` never purges (the app does, at startup). Unlike
    /// the write path, an unreadable journal is a real error here and propagates.
    func run() throws {
        if id != nil, machine != nil {
            throw HPMError("--id shows one entry in full; it cannot be combined with --machine")
        }
        if id != nil, limit != nil {
            throw HPMError("--id shows one entry in full; it cannot be combined with --limit")
        }
        let limit = self.limit ?? 50
        guard (1...HistoryStore.retentionCap).contains(limit) else {
            throw HPMError("--limit must be between 1 and \(HistoryStore.retentionCap) (the journal never holds more)")
        }
        // A listing must not bring the database into existence: the first *action*
        // creates hpm.db, never a read on a virgin machine.
        guard FileManager.default.fileExists(atPath: expandPath(HistoryStore.defaultPath)) else {
            // A missing base and a missing row are the same lookup failure for --id:
            // both must exit non-zero, not pass an absence off as a quiet success.
            if let id {
                throw HPMError("no task with id \(id) — list them with: hpm tasks")
            }
            print(machine.map { "No tasks recorded for '\($0)'." } ?? "No tasks recorded yet.")
            return
        }
        let store = try HistoryStore()
        if let id {
            guard let entry = try store.task(id: id) else {
                throw HPMError("no task with id \(id) — list them with: hpm tasks")
            }
            print("ID:       \(entry.id)")
            print("Date:     \(HistoryStore.iso8601String(from: entry.startedAt))")
            print("Finished: \(entry.finishedAt.map(HistoryStore.iso8601String(from:)) ?? "-")")
            print("Machine:  \(entry.machine)")
            print("Action:   \(entry.action)")
            print("Status:   \(entry.status.rawValue)")
            print("Output:")
            print(entry.output.isEmpty ? "  (empty)" : entry.output.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n"))
            return
        }

        // The table never renders outputs; skip the column like the app's list read does.
        let entries = try store.tasks(machine: machine, limit: limit, includeOutput: false)
        guard !entries.isEmpty else {
            print(machine.map { "No tasks recorded for '\($0)'." } ?? "No tasks recorded yet.")
            return
        }
        var rows: [[String]] = [["ID", "DATE", "MACHINE", "ACTION", "STATUS"]]
        for entry in entries {
            rows.append([
                String(entry.id),
                HistoryStore.iso8601String(from: entry.startedAt),
                entry.machine,
                entry.action,
                entry.status.rawValue,
            ])
        }
        printTable(rows)
    }
}

// MARK: - events

/// The CLI twin of the Events tab (AD-13): the same reader, the same window, the same
/// severity filter. Nothing here decides anything about events — `HomeportEventsReader`
/// does, in the kit, where `swift test` covers it.
struct EventsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Show the events reported by a machine's Homeport.")
    @Option(name: [.customShort("m"), .customLong("machine")], help: "Only this machine (default: every declared machine).") var machine: String?
    @Option(name: [.customShort("s"), .customLong("severity")], help: "Only this severity: info, warning or critical.") var severity: String?
    @Option(name: [.customShort("n"), .customLong("limit")], help: "Number of events per machine (default: \(HomeportEventsReader.defaultLimit)).") var limit: Int?

    func run() async throws {
        let filter = try Self.parseSeverityOption(severity)
        let limit = try Self.validateLimitOption(limit)

        let targets: [Machine]
        if let name = machine {
            targets = [try FleetStore().machine(named: name)]
        } else {
            targets = try FleetStore().load().machines
            guard !targets.isEmpty else {
                throw HPMError("no machines declared — start with: hpm machine add <name> --ssh <host>")
            }
        }

        // Same doctrine as `tasks`: a listing must never bring hpm.db into existence. The
        // cursor is optional to a read — without it the window is identical, only the
        // cross-process reset detection is missing.
        var cursors: EventCursorStore?
        if FileManager.default.fileExists(atPath: expandPath(HistoryStore.defaultPath)) {
            do {
                cursors = try HistoryStore()
            } catch {
                FileHandle.standardError.write(Data("warning: events cursor unavailable — \(error)\n".utf8))
            }
        }
        // `advancingCursor: false`: reading a journal is not marking it read, and a CLI
        // that consumed the cursor would blind the app's next incremental poll. Moving the
        // read marker from here waits for story 2.2b, which gives it a second marker to
        // stay distinct from.
        let reader = HomeportEventsReader(api: HomeportAPIClient(), cursors: cursors)

        for target in targets {
            if targets.count > 1 { print("── \(target.name) ──") }
            switch await reader.read(target, mode: .window, limit: limit, advancingCursor: false) {
            case .unavailable(let reason):
                print(unavailableLine(reason, machine: target.name))
            case .unreachable(let detail):
                print("\(target.name) is unreachable — \(detail)")
            case .cancelled:
                // The command's own task was cancelled (e.g. the process is shutting
                // down) — no verdict was reached, so nothing is printed for this target
                // as though one had.
                continue
            case .window(let window):
                if window.cursorWasReset {
                    print("(the event history of \(target.name) started a new generation — reading it from the beginning)")
                }
                report(window.events.filtered(severity: filter), machine: target.name, filter: filter)
            }
        }
    }

    /// A severity outside the three is a typo in the command line, not an unknown value
    /// served by a machine: the client's "fold to warning" rule is about what a *server*
    /// sends, and applying it here would silently answer a different question.
    static func parseSeverityOption(_ raw: String?) throws -> EventSeverity? {
        guard let raw else { return nil }
        guard let parsed = EventSeverity(rawValue: raw.lowercased()) else {
            throw HPMError("--severity must be one of: \(EventSeverity.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return parsed
    }

    /// Defaults to the reader's own page size, then holds `--limit` to the contract's
    /// ceiling (§6) — a client-side check, since a server clamp cannot be relied on.
    static func validateLimitOption(_ raw: Int?) throws -> Int {
        let limit = raw ?? HomeportEventsReader.defaultLimit
        guard (1...1000).contains(limit) else {
            throw HPMError("--limit must be between 1 and 1000 (the contract's ceiling)")
        }
        return limit
    }

    /// Never an error, and never "broken": §8 sends every one of these to an update.
    private func unavailableLine(_ reason: APIUnavailableReason, machine: String) -> String {
        switch reason {
        case .notServed:
            return "\(machine) does not serve the Homeport v1 API yet — update it to see its events."
        case .incompatibleContract(let compatibility):
            return "\(machine) announces API contract \(compatibility.describedVersion), outside the range hpm consumes (\(HomeportAPIContract.supportedRange)) — update it to see its events."
        case .surfaceNotServed(let surface):
            return "\(machine) does not serve the '\(surface)' surface of the v1 API — update it to see its events."
        }
    }

    /// Newest first, like `hpm tasks` — the window itself is the contract's ascending
    /// order, reversed once, here, at the point of display.
    private func report(_ events: [HomeportEvent], machine: String, filter: EventSeverity?) {
        guard !events.isEmpty else {
            print(filter.map { "No \($0.rawValue) event on '\(machine)'." } ?? "No event on '\(machine)'.")
            return
        }
        printTable(Self.rows(for: events))
    }

    /// The table's exact shape, pulled out of `report` so the format can be checked
    /// without exercising any I/O.
    static func rows(for events: [HomeportEvent]) -> [[String]] {
        var rows: [[String]] = [["ID", "DATE", "SEVERITY", "KIND", "SUBJECT", "DETAIL"]]
        for event in events.reversed() {
            rows.append([
                String(event.id),
                HistoryStore.iso8601String(from: event.timestamp),
                event.severity.rawValue,
                event.kind,
                event.subject,
                event.detail ?? "-",
            ])
        }
        return rows
    }
}

// MARK: - unlock

struct UnlockCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlock", abstract: "Release a machine's mutation lock left by a dead or expired process.")
    @Argument var machine: String

    /// A skin over `HistoryStore.unlock`: the refusal/release/reclaim logic lives in the
    /// kit where `swift test` covers it. Same doctrine as `tasks`: an unlock must not
    /// bring the database into existence — no base means nothing to unlock.
    func run() throws {
        guard FileManager.default.fileExists(atPath: expandPath(HistoryStore.defaultPath)) else {
            print("Nothing to unlock for '\(machine)'.")
            return
        }
        // A live in-TTL holder makes unlock() throw, naming the pid and since when —
        // ArgumentParser renders the HPMError and exits non-zero.
        switch try HistoryStore().unlock(machine: machine) {
        case .nothingToUnlock:
            print("Nothing to unlock for '\(machine)'.")
        case .released(let holder, let orphanClosed):
            print("✓ lock on '\(machine)' released (was held by pid \(holder.pid) since \(HistoryStore.iso8601String(from: holder.acquiredAt)))")
            // Only when a `running` task was really closed: a purged or already-closed
            // orphan must not be reported as an action that happened.
            if orphanClosed {
                print("  its orphaned task was closed as interrupted — see: hpm tasks")
            }
        case .releasedCorrupt(let orphanClosed):
            print("✓ unreadable lock on '\(machine)' removed (its timestamp was corrupt)")
            if orphanClosed {
                print("  its orphaned task was closed as interrupted — see: hpm tasks")
            }
        }
    }
}

// MARK: - remove

struct RemoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Uninstall Homeport from a machine (final backup first).")
    @Argument var machine: String
    @Flag(name: .customLong("yes"), help: "Skip confirmation.") var assumeYes = false

    func run() throws {
        let target = try FleetStore().machine(named: machine)
        if !assumeYes {
            print("This will uninstall Homeport from '\(target.name)' (service, app, config, data).")
            print("Type the machine name to confirm: ", terminator: "")
            guard readLine() == target.name else {
                print("Aborted.")
                return
            }
        }
        try makeManager().remove(on: target)
    }
}
