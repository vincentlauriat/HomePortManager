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
            if try FleetStore().remove(named: name) {
                print("✓ \(name) removed from inventory")
            } else {
                print("'\(name)' was not in the inventory")
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
