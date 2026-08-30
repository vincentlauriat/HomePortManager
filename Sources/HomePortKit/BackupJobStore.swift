import Foundation
import Yams

/// A declared scheduled-backup job: what to run and how much to keep on the machine
/// itself. Deliberately holds only *desired* state — never a result, never a lock (F8).
public struct BackupJob: Codable, Equatable {
    /// A systemd `OnCalendar=` expression (e.g. `daily`, `*-*-* 03:30:00`).
    public var schedule: String
    /// Local archives kept on the machine by the autonomous script (Pi-side rotation;
    /// distinct from the Mac's own 10, which `hpm backup sync` — story 3.2 — governs).
    public var retention: Int

    public init(schedule: String, retention: Int = 3) {
        self.schedule = schedule
        self.retention = retention
    }
}

/// Sole owner of `~/.config/hpm/jobs/<machine>.yaml` — the Mac-side desired state for a
/// machine's scheduled backup (F8). Never `hpm.db`, which only ever holds what was
/// observed. One file per machine, same shape as `FleetStore`'s single fleet.yaml.
public final class BackupJobStore {
    public static let defaultRoot = "~/.config/hpm/jobs"
    private let root: String

    public init(root: String = BackupJobStore.defaultRoot) {
        self.root = expandPath(root)
    }

    private func path(for machineName: String) -> String {
        "\(root)/\(machineName).yaml"
    }

    /// nil when nothing has ever been declared for this machine.
    public func load(for machineName: String) throws -> BackupJob? {
        let file = path(for: machineName)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        do {
            return try YAMLDecoder().decode(BackupJob.self, from: contents)
        } catch {
            throw HPMError("cannot parse \(file): \(error)")
        }
    }

    public func save(_ job: BackupJob, for machineName: String) throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let yaml = try YAMLEncoder().encode(job)
        try yaml.write(toFile: path(for: machineName), atomically: true, encoding: .utf8)
    }
}
