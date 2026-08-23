import Foundation
import HomePortKit

/// Persists the name → block table so a machine keeps its identity across launches.
///
/// `UserDefaults`, deliberately not `hpm.db`: the visual identity is not part of the
/// central state the kit owns (journal, cursors, markers, job state, locks) and the CLI has
/// no use for it. The store is **append-only** — entries are merged, never filtered down to
/// the machines currently in `fleet.yaml`. `assignBlocks` derives the next colour from the
/// size of the store, so pruning a stale key would silently hand a live machine a colour
/// already in use.
@MainActor
final class MachineBlockStore {
    private static let defaultsKey = "MachineBlocks"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current table, plus a freshly assigned block for every unknown name. New entries are
    /// written back immediately; existing ones are left exactly as they were.
    @discardableResult
    func blocks(for names: [String]) -> [String: MachineBlock] {
        let existing = load()
        let assigned = assignBlocks(to: names, existing: existing)
        if assigned != existing { save(assigned) }
        return assigned
    }

    private func load() -> [String: MachineBlock] {
        let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        return raw.compactMapValues(MachineBlock.init(rawValue:))
    }

    private func save(_ blocks: [String: MachineBlock]) {
        defaults.set(blocks.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }
}
