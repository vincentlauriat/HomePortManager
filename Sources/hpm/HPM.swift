import ArgumentParser
import Foundation
import HomePortKit

@main
struct HPM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hpm",
        abstract: "Manage the life cycle of Homeport instances.",
        subcommands: [
            MachineCmd.self, StatusCmd.self, ReleasesCmd.self, PrereqsCmd.self,
            InstallCmd.self, UpdateCmd.self, BackupCmd.self, RestoreCmd.self,
            ConfigCmd.self, RemoveCmd.self,
        ]
    )
}

// MARK: - Shared helpers

func makeManager() -> HomeportManager {
    let runner = DefaultProcessRunner()
    return HomeportManager(
        ssh: SSHClient(runner: runner),
        releases: ReleaseService(runner: runner),
        runner: runner,
        report: { print("  \($0)") }
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

/// Runs an operation per machine, prints a final summary, exits 1 if any failed.
func forEachMachine(_ machines: [Machine], _ operation: (Machine) throws -> Void) throws {
    var failures: [String: String] = [:]
    for machine in machines {
        print("── \(machine.name) ──")
        do {
            try operation(machine)
        } catch {
            failures[machine.name] = "\(error)"
            print("  ✗ \(error)")
        }
    }
    if machines.count > 1 {
        print("\nSummary:")
        for machine in machines {
            print("  \(failures[machine.name] == nil ? "✓" : "✗") \(machine.name)")
        }
    }
    if !failures.isEmpty { throw ExitCode(1) }
}
