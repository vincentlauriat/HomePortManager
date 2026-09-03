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
        // m2 (revue finale) : sans cette option, `exploitPort` n'était réglable qu'en éditant
        // fleet.yaml à la main — la fonctionnalité de maintenance qu'il déclenche restait
        // inatteignable au premier essai.
        @Option(help: "HomePortExploit HTTP port on the machine (enables hpm maintenance / the Maintenance tab).") var exploitPort: Int?
        @Option(help: "Free-form note.") var notes: String?

        func run() throws {
            try FleetStore().add(Machine(name: name, ssh: ssh, port: port, notes: notes, exploitPort: exploitPort))
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
                let exploitPort = machine.exploitPort.map { "  exploitPort=\($0)" } ?? ""
                let notes = machine.notes.map { "  — \($0)" } ?? ""
                print("\(machine.name)  ssh=\(machine.ssh)  port=\(machine.port)\(exploitPort)\(notes)")
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
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Back up config + data — on demand, or as a scheduled Pi-side job.",
        subcommands: [Apply.self, Now.self]
    )

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Declare (if given options) and deploy the scheduled backup job — units + autonomous root script.")
        @Argument var machine: String
        @Option(help: "systemd OnCalendar expression (e.g. daily, *-*-* 03:30:00). Required the first time a job is declared for a machine.") var schedule: String?
        @Option(help: "Local archives kept on the machine (default: 3). Passing this alone on a machine's first-ever declaration still requires --schedule in the same invocation.") var retention: Int?

        func run() throws {
            let target = try FleetStore().machine(named: machine)
            let manager = makeManager()
            let store = BackupJobStore(root: manager.jobsRoot)
            let existing = try store.load(for: target.name)
            if let job = try Self.resolvedJob(schedule: schedule, retention: retention, existing: existing, machineName: target.name) {
                try store.save(job, for: target.name)
            }
            try manager.applyBackupJob(on: target)
        }

        /// The testable core of `run()`: validates `--schedule`/`--retention` and decides
        /// whether (and with what content) the store needs writing. nil means neither option
        /// was passed — a bare `hpm backup apply <m>` just redeploys the already-declared job
        /// unchanged. Also rejects a `--schedule` that could close a deployed script's
        /// heredoc early (`HomeportManager.validateBackupJobInputs`) before it ever reaches
        /// disk, not just before deployment.
        static func resolvedJob(schedule: String?, retention: Int?, existing: BackupJob?, machineName: String) throws -> BackupJob? {
            if let schedule, schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw HPMError("--schedule cannot be empty")
            }
            if let retention, retention < 1 {
                throw HPMError("--retention must be at least 1")
            }
            guard schedule != nil || retention != nil else { return nil }
            guard let resolvedSchedule = schedule ?? existing?.schedule else {
                throw HPMError("--schedule is required the first time a job is declared for '\(machineName)'")
            }
            try HomeportManager.validateBackupJobInputs(schedule: resolvedSchedule, machineName: machineName)
            return BackupJob(schedule: resolvedSchedule, retention: retention ?? existing?.retention ?? 3)
        }
    }

    struct Now: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Back up config + data right now (kept on the machine and on this Mac).")
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
            throw HPMError("no local backup found for '\(target.name)' in \(manager.localBackupDir(for: target.name)) — run: hpm backup now \(target.name)")
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

// MARK: - metrics

/// The CLI twin of the Metrics tab (AD-13/FR11): the same reader, the same window, the same
/// numbers. Nothing here decides anything about a metric — `HomeportMetricsReader` and the
/// value types under it do, in the kit, where `swift test` covers them.
///
/// No `HistoryStore` anywhere in this command, unlike `events`: AD-6 keeps hpm.db for the
/// events cursor and the notification marker, and metrics have neither. There is nothing to
/// read from it and nothing to write to it.
struct MetricsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics", abstract: "Show the health metrics recorded by a machine's Homeport.")
    @Argument(help: "The machine to read.") var machine: String
    @Option(name: [.customShort("r"), .customLong("range")], help: "Window to read: \(MetricsRange.allCases.map(\.rawValue).joined(separator: ", ")) (default: \(HomeportMetricsReader.defaultRange.rawValue)).") var range: String?

    func run() async throws {
        // Parsed before anything else touches the fleet or the network: an unknown range is
        // a typo on the command line, and it must cost nothing to find out.
        let range = try Self.parseRangeOption(self.range)
        let target = try FleetStore().machine(named: machine)

        switch await HomeportMetricsReader(api: HomeportAPIClient()).read(target, range: range) {
        case .unavailable(let reason):
            print(unavailableLine(reason, machine: target.name))
        case .unreachable(let detail):
            print("\(target.name) is unreachable — \(detail)")
        case .cancelled:
            // The command's own task was cancelled — no verdict was reached, so nothing is
            // printed as though one had been.
            return
        case .window(let window):
            print(Self.header(for: window))
            printTable(Self.rows(for: window))
        }
    }

    /// A range outside the four is a typo, not a value served by a machine: the contract's
    /// own answer to an unknown range is a 400 (§7), and there is no neighbouring value to
    /// fall back on. The message is built from the enum so it cannot drift from it.
    static func parseRangeOption(_ raw: String?) throws -> MetricsRange {
        guard let raw else { return HomeportMetricsReader.defaultRange }
        guard let parsed = MetricsRange(rawValue: raw.lowercased()) else {
            throw HPMError("--range must be one of: \(MetricsRange.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return parsed
    }

    /// The grid as served, announced before the table unrolls: at 24 h it is 1 440 lines,
    /// and the header is what makes that volume predictable rather than surprising.
    static func header(for window: MetricsWindow) -> String {
        "range \(window.range.rawValue)  step \(window.stepS)s  from \(HistoryStore.iso8601String(from: window.from))  to \(HistoryStore.iso8601String(from: window.to))  points \(window.pointCount)"
    }

    /// The table's exact shape, pulled out of `run` so the format can be checked without
    /// exercising any I/O. One line per grid slot — the same content as the curve, which is
    /// what FR11 asks of a CLI twin; a current/min/max summary would be a *different*
    /// content. Newest first, like every other table in hpm.
    static func rows(for window: MetricsWindow) -> [[String]] {
        var rows: [[String]] = [["DATE", "CPU%", "MEM%", "DISK%", "TEMP°C"]]
        for index in stride(from: window.pointCount - 1, through: 0, by: -1) {
            rows.append([HistoryStore.iso8601String(from: window.timestamp(at: index))]
                + window.series.map { MetricValue.text($0.points[index], absent: "-") })
        }
        return rows
    }

    /// Never an error, and never "broken": §8 sends every one of these to an update.
    private func unavailableLine(_ reason: APIUnavailableReason, machine: String) -> String {
        switch reason {
        case .notServed:
            return "\(machine) does not serve the Homeport v1 API yet — update it to see its metrics."
        case .incompatibleContract(let compatibility):
            return "\(machine) announces API contract \(compatibility.describedVersion), outside the range hpm consumes (\(HomeportAPIContract.supportedRange)) — update it to see its metrics."
        case .surfaceNotServed(let surface):
            return "\(machine) does not serve the '\(surface)' surface of the v1 API — update it to see its metrics."
        }
    }
}

// MARK: - maintenance

/// The CLI surface for the actions HomePortExploit delegates on the Pi (`hpm update` stays
/// "update Homeport to a tagged release" — this group is deliberately named apart from it).
/// Every state `describe(_:)` renders comes from `ExploitAPIContract.swift`, shared with the
/// SwiftUI tab: one formulation per state, never two that could drift apart.
struct MaintenanceCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintenance",
        abstract: "Run HomePortExploit maintenance actions on a machine.",
        subcommands: [Actions.self, Plan.self, Run.self, History.self]
    )

    /// Dry-runs `action` and renders it exactly once, so `Plan` and `Run` can never drift
    /// into two different diagnostics for the same outcome (fix round 1: `Run` used to
    /// collapse `staleToken`/`unknownAction`/`unavailable` into one generic "prévisualisation
    /// impossible", losing precisely the states this task exists to keep distinguishable).
    /// `nil` means the caller already printed everything there is to say and must exit 1.
    static func preview(_ action: ExploitAction, on target: Machine,
                        using manager: HomeportManager) async throws -> ExploitResult? {
        switch try await manager.maintenancePlan(action, on: target) {
        case .completed(let result):
            print(result.message)
            result.detail.displayLines.forEach { print("  \($0)") }
            return result
        case .staleToken:
            print("jeton de plan expiré ou déjà consommé — relancer la commande")
            return nil
        case .unknownAction:
            print("action absente du catalogue de cette machine")
            return nil
        case .unavailable(let state):
            print(describe(state))
            return nil
        // A2 (tâche 6b) : ce dénouement n'est produit que par la phase `execute`
        // (ExploitAPIClient.post) — un dry-run ne peut jamais l'atteindre. Gardé pour
        // l'exhaustivité et pour rester correct si cet invariant devait un jour se rompre.
        case .executionTimedOut:
            print("délai de transport dépassé — issue inconnue, voir l'historique de la machine")
            return nil
        }
    }

    struct Actions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What this machine serves, or why it serves nothing.")
        @Argument var machine: String

        // journal: false — a read, like `maintenanceCapabilities` itself documents ("never
        // journaled"). `makeManager()` would open `HistoryStore()` without SQLITE_OPEN_READONLY
        // and create hpm.db on a machine that has never run an action, plausibly on the very
        // first command typed against a freshly deployed service.
        func run() async throws {
            let target = try FleetStore().machine(named: self.machine)
            let state = await makeManager(journal: false).maintenanceCapabilities(of: target)
            print(describe(state))
            if case .available = state { return }
            throw ExitCode(1)
        }
    }

    struct Plan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Dry-run an action and show its preview, without executing it.")
        @Argument var machine: String
        @Argument var action: String
        @Option(help: "reboot | poweroff (reboot only).") var mode: String?
        @Option(help: "Docker service name (docker-update only).") var service: String?

        func run() async throws {
            let target = try FleetStore().machine(named: self.machine)
            let parsed = try ExploitAction(name: action, mode: mode, service: service)

            guard let preview = try await MaintenanceCmd.preview(parsed, on: target, using: makeManager()) else {
                throw ExitCode(1)
            }
            if !preview.ok { throw ExitCode(1) }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Dry-run, show the preview, confirm, then execute.")
        @Argument var machine: String
        @Argument var action: String
        @Option(help: "reboot | poweroff (reboot only).") var mode: String?
        @Option(help: "Docker service name (docker-update only).") var service: String?
        @Flag(name: .long, help: "Skip the interactive question. The preview is still shown.") var yes = false

        /// Always chains the dry-run first: it is the only way to obtain a `plan_id`, and
        /// the server refuses (409) without one. `--yes` only skips the interactive
        /// question — the preview always prints. A token is burned by the attempt, not by
        /// success (§ contract), so no `plan_id` is ever reused across invocations.
        func run() async throws {
            let target = try FleetStore().machine(named: self.machine)
            let manager = makeManager()
            let parsed = try ExploitAction(name: action, mode: mode, service: service)

            guard let preview = try await MaintenanceCmd.preview(parsed, on: target, using: manager) else {
                throw ExitCode(1)
            }
            guard preview.ok, let planID = preview.planID else { throw ExitCode(1) }

            if !yes {
                print("Exécuter ? [o/N] ", terminator: "")
                guard let answer = readLine()?.lowercased(), answer == "o" || answer == "oui" else {
                    print("annulé"); return
                }
            }
            switch try await manager.maintenanceRun(parsed, planID: planID, on: target) {
            case .completed(let result):
                print(result.message)
                if !result.ok { throw ExitCode(1) }
            case .staleToken:
                print("prévisualisation expirée (jeton valable 5 minutes) — relancer la commande")
                throw ExitCode(1)
            case .unknownAction:
                print("action absente du catalogue de cette machine")
                throw ExitCode(1)
            case .unavailable(let state):
                print(describe(state)); throw ExitCode(1)
            // A2 (tâche 6b) : le serveur, lui, va au bout (plan_id consommé, ligne d'audit
            // écrite, mise à jour réellement faite) — rendre ça comme un échec reproduirait
            // I1 (tâche 6) un étage plus bas. On ne sait pas, donc on renvoie vers ce qui
            // porte la réponse plutôt que d'inventer un verdict.
            case .executionTimedOut:
                print("délai de transport dépassé pendant l'exécution — issue inconnue : le serveur est peut-être allé au bout. Consultez « hpm maintenance history \(target.name) ».")
                throw ExitCode(1)
            }
        }
    }

    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "history", abstract: "Show the maintenance actions HomePortExploit has recorded for a machine.")
        @Argument var machine: String
        @Option(name: [.customShort("n"), .customLong("limit")], help: "Number of entries (default: 50).") var limit: Int?

        // journal: false — a read, like `maintenanceAudit` itself documents ("never
        // journaled, like maintenanceCapabilities"): must not bring hpm.db into existence.
        func run() async throws {
            let target = try FleetStore().machine(named: self.machine)
            let limit = try Self.validateLimitOption(self.limit)

            switch await makeManager(journal: false).maintenanceAudit(of: target, limit: limit) {
            case .success(let entries):
                guard !entries.isEmpty else {
                    print("Aucune action de maintenance enregistrée pour '\(target.name)'.")
                    return
                }
                printTable(Self.rows(for: entries))
            case .failure(let state):
                print(describe(state))
                throw ExitCode(1)
            }
        }

        /// §8 : « sans borne haute imposée côté serveur en v1 — un client ne demande pas une
        /// valeur déraisonnable. » Même doctrine que `EventsCmd.validateLimitOption`.
        static func validateLimitOption(_ raw: Int?) throws -> Int {
            let limit = raw ?? 50
            guard (1...1000).contains(limit) else {
                throw HPMError("--limit must be between 1 and 1000")
            }
            return limit
        }

        /// The table's exact shape, pulled out of `run` so the format can be checked
        /// without exercising any I/O — same doctrine as `EventsCmd.rows`/`MetricsCmd.rows`.
        static func rows(for entries: [ExploitAuditEntry]) -> [[String]] {
            var rows: [[String]] = [["DATE", "IDENTITY", "ACTION", "PARAMS", "DRY-RUN", "STATUS", "MESSAGE"]]
            for entry in entries {
                rows.append([
                    HistoryStore.iso8601String(from: entry.timestamp),
                    entry.identity,
                    entry.action,
                    entry.params,
                    entry.dryRun ? "yes" : "no",
                    entry.ok ? "ok" : "failed",
                    entry.message,
                ])
            }
            return rows
        }
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
