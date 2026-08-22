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
        let manager = makeManager()
        let latest = (try? manager.releases.latest().tag) ?? "?"

        var rows: [[String]] = [["NAME", "VERSION", "LATEST", "SERVICE", "HEALTH", "LAST BACKUP"]]
        for target in targets {
            let status = try manager.status(of: target)
            rows.append([
                status.name,
                status.installedVersion,
                latest,
                status.reachable ? (status.serviceActive ? "active" : "inactive") : "unreachable",
                status.reachable ? (status.healthzOK ? "OK" : "FAIL") : "-",
                status.lastBackup ?? "none",
            ])
        }
        printTable(rows)
    }

    private func printTable(_ rows: [[String]]) {
        let widths = (0..<rows[0].count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        for row in rows {
            print(zip(row, widths).map { $0.padding(toLength: $1 + 2, withPad: " ", startingAt: 0) }.joined())
        }
    }
}

// MARK: - releases

struct ReleasesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "releases", abstract: "List available Homeport releases on GitHub.")
    func run() throws {
        for release in try makeManager().releases.list() {
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

    func run() throws {
        let targets = try resolveTargets(machine: machine, all: all)
        let manager = makeManager()
        try forEachMachine(targets) { try manager.update(on: $0, version: version) }
    }
}

// MARK: - backup / restore

struct BackupCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "backup", abstract: "Back up config + data (kept on the machine and on this Mac).")
    @Argument(help: "Machine name (omit with --all).") var machine: String?
    @Flag(help: "All declared machines.") var all = false

    func run() throws {
        let targets = try resolveTargets(machine: machine, all: all)
        let manager = makeManager()
        try forEachMachine(targets) { target in
            let path = try manager.backup(on: target)
            print("  ✓ \(path)")
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
            let diff = try makeManager().configDiff(on: target, file: file)
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
