import ArgumentParser
import Foundation
import HomePortKit

/// `AsyncParsableCommand` rather than `ParsableCommand`: `events` is the first command
/// whose work is asynchronous (the Homeport API client, AD-3), and only an async root
/// awaits an async subcommand — under a synchronous `main()` the parsed command's `run()`
/// is called without an async context. Every other subcommand stays synchronous; the root
/// only changes how it is entered.
@main
struct HPM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hpm",
        abstract: "Manage the life cycle of Homeport instances.",
        subcommands: [
            MachineCmd.self, StatusCmd.self, ReleasesCmd.self, PrereqsCmd.self,
            InstallCmd.self, UpdateCmd.self, BackupCmd.self, RestoreCmd.self,
            ConfigCmd.self, RemoveCmd.self, LogsCmd.self, RestartCmd.self, DoctorCmd.self,
            TasksCmd.self, EventsCmd.self, UnlockCmd.self,
        ]
    )
}

// MARK: - Shared helpers

func makeManager(journal: Bool = true, report: @escaping Reporter = { print("  \($0)") }) -> HomeportManager {
    let runner = DefaultProcessRunner()
    // A broken state directory degrades the journal, never the action itself. Pure
    // reads pass `journal: false` and skip the store entirely: opening it would create
    // hpm.db, and only the first *action* may bring the database into existence.
    var history: HistoryStore?
    if journal {
        do {
            history = try HistoryStore()
        } catch {
            FileHandle.standardError.write(Data("warning: task journal unavailable — \(error)\n".utf8))
        }
    }
    return HomeportManager(
        ssh: SSHClient(runner: runner),
        releases: ReleaseService(runner: runner),
        runner: runner,
        history: history,
        report: report
    )
}

/// Destructive commands ask before acting; --yes bypasses for scripting.
func confirm(_ prompt: String, assumeYes: Bool) -> Bool {
    if assumeYes { return true }
    print("\(prompt) [y/N] ", terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

/// Resolves `[machine]` / `--all` into a target list (exactly one of the two).
func resolveTargets(machine: String?, all: Bool) throws -> [Machine] {
    let fleet = try FleetStore().load()
    if all {
        guard !fleet.machines.isEmpty else {
            throw HPMError("no machines declared — start with: hpm machine add <name> --ssh <host>")
        }
        return fleet.machines
    }
    guard let name = machine else {
        throw ValidationError("specify a machine name or --all")
    }
    return [try FleetStore().machine(named: name)]
}

/// Runs an operation per machine — concurrently when there are several — with output
/// buffered per machine so lines never interleave. Prints a final summary and exits 1
/// if any machine failed. Each machine gets its own manager wired to its buffer.
func forEachMachine(_ machines: [Machine], _ operation: @escaping (Machine, HomeportManager) throws -> Void) throws {
    let lock = NSLock()
    var failures: [String: String] = [:]
    var outputs: [String: String] = [:]

    let work: (Machine) -> Void = { machine in
        var buffer = ""
        let bufferLock = NSLock()
        let manager = makeManager { line in
            bufferLock.lock(); buffer += "  \(line)\n"; bufferLock.unlock()
        }
        var failure: String?
        do {
            try operation(machine, manager)
        } catch {
            failure = "\(error)"
        }
        lock.lock()
        outputs[machine.name] = buffer + (failure.map { "  ✗ \($0)\n" } ?? "")
        if let failure { failures[machine.name] = failure }
        lock.unlock()
    }

    if machines.count > 1 {
        DispatchQueue.concurrentPerform(iterations: machines.count) { work(machines[$0]) }
    } else {
        machines.forEach(work)
    }

    for machine in machines {
        print("── \(machine.name) ──")
        print(outputs[machine.name] ?? "", terminator: "")
    }
    if machines.count > 1 {
        print("\nSummary:")
        for machine in machines {
            print("  \(failures[machine.name] == nil ? "✓" : "✗") \(machine.name)")
        }
    }
    if !failures.isEmpty { throw ExitCode(1) }
}
