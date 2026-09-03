import Foundation

/// The maintenance actions HomePortExploit runs on the Pi, seen from the fleet: story 1.2
/// asks that *every* action on the fleet be journaled, so a delegated action goes through
/// the same seam as an SSH one — the journal (`hpm.db`) and the per-machine lock (AD-12).
///
/// No contract failure is an error here: the states of `ExploitAvailability` and the cases
/// of `ExploitOutcome` are values the caller renders. Only `LockContentionError` — another
/// process holding the machine — comes back as a thrown error.
extension HomeportManager {
    /// A read (AD-16): never locked, and never journaled either. The app polls it on every
    /// tab visit, and an entry per poll would bury the actions the journal exists for —
    /// the same reason `status` and `logs` stay out of the seam.
    public func maintenanceCapabilities(of machine: Machine) async -> ExploitAvailability {
        await exploit.capabilities(of: machine)
    }

    /// A read, like `maintenanceCapabilities`: the audit trail lives on the Pi, and reading
    /// it must not wait on whoever holds the machine.
    public func maintenanceAudit(of machine: Machine,
                                 limit: Int) async -> Result<[ExploitAuditEntry], ExploitAvailability> {
        await exploit.audit(of: machine, limit: limit)
    }

    /// The dry-run writes on the Pi — `apt-update`'s preview runs `sudo apt-get update`,
    /// which rewrites the package lists and takes apt's own locks. Run alongside another
    /// apt operation it fails, or makes the other one fail. So it locks like an execution:
    /// AD-16 draws the line at GET versus POST, not at "plan" versus "run".
    public func maintenancePlan(_ action: ExploitAction, on machine: Machine) async throws -> ExploitOutcome {
        try await journaled("maintenance-plan", on: machine, locking: true) {
            let outcome = await exploit.dryRun(action, on: machine)
            report("dry-run \(action.name) sur \(machine.name) — \(Self.summary(of: outcome))")
            return outcome
        }
    }

    public func maintenanceRun(_ action: ExploitAction, planID: String,
                               on machine: Machine) async throws -> ExploitOutcome {
        try await journaled("maintenance-run", on: machine, locking: true) {
            let outcome = await exploit.execute(action, planID: planID, on: machine)
            report("\(action.name) sur \(machine.name) — \(Self.summary(of: outcome))")
            return outcome
        }
    }

    /// The delegated body says nothing on the report stream of its own — the narrative
    /// comes back as a return value, not as lines. Without this summary the journal entry
    /// would close with an empty `output`: a record of *when* an action ran and nothing of
    /// what it did.
    ///
    /// It carries the verdict because the `status` cannot: nothing throws here, so the seam
    /// closes every entry as `.success`, including a refused or unreachable outcome.
    static func summary(of outcome: ExploitOutcome) -> String {
        switch outcome {
        case .completed(let result):
            return "\(result.ok ? "ok" : "échec") — \(result.message)"
        case .staleToken:
            return "jeton de plan expiré ou déjà consommé — refaire le dry-run"
        case .unknownAction:
            return "action absente du catalogue de cette machine"
        case .unavailable(let state):
            return "indisponible — \(state)"
        }
    }
}
