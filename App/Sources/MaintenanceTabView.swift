import SwiftUI
import HomePortKit

/// The Maintenance tab (task 6): the HomePortExploit surface for one machine — its state,
/// the actions it serves, the destructive confirmation flow (UX-DR6), its Homeport config in
/// read-only, and its own action history.
///
/// Two machines out of three on the real fleet have no exploit service at all, so
/// `.notDeployed` is this tab's *most common* screen, not its error case — it gets the same
/// care as the available path (`stateCard`), not a red badge.
///
/// Every read here is polled fresh on each visit — `maintenanceCapabilities`/`maintenanceAudit`
/// document themselves as "never journaled", and the two direct `exploit` reads share that
/// doctrine — so, unlike Events/Metrics/Logs, nothing needs a store that survives the tab
/// switch `.id(machine.name)` would otherwise throw away: plain `@State`, reloaded by `.task`.
struct MaintenanceTabView: View {
    @ObservedObject var model: FleetModel
    let machine: Machine

    @State private var capabilities: ExploitAvailability?
    @State private var dockerServices: Result<[ExploitDockerService], ExploitAvailability>?
    @State private var configResult: Result<String?, ExploitAvailability>?
    @State private var auditResult: Result<[ExploitAuditEntry], ExploitAvailability>?
    @State private var selectedService = ""

    /// The dry-run just shown, awaiting its UX-DR6 confirmation. Carries the plan's action
    /// and result only — never the `HomeportManager` that produced it: the Global Constraint
    /// is "never a cached instance", and a manager kept in `@State` across the tap that opens
    /// this sheet and the tap that confirms it would be exactly that. `execute` builds its
    /// own, fresh, inside its own `Task.detached` — same as this dry-run did for its.
    @State private var pendingPlan: PendingMaintenancePlan?
    @State private var maintenanceBusy = false
    /// The last dry-run/execute failure, in the same shape — and the same visual surface,
    /// `LastActionErrorView` — every other action's failure gets. A pure display struct, not
    /// `model.lastError`: that dictionary belongs to `FleetModel.run`, and a maintenance
    /// action never runs through it (it has its own lane, its own busy flag, below).
    @State private var maintenanceReport: FleetModel.LastReport?
    /// A completed, `ok:true` execution's own message (fix round 1, I2) — kept apart from
    /// `maintenanceReport`: `FleetModel.LastReport.Kind` has only `failure`/`finding`, and
    /// `LastActionErrorView`'s `finding` headline reads "Last action reported problems", which
    /// would misdescribe a clean success. Server content, shown verbatim, never translated.
    @State private var maintenanceSuccess: String?
    /// A2 (task 6b): a transport timeout during `execute` — the server may have gone all the
    /// way despite the client giving up on the wait. Carries the action rather than a plain
    /// `Bool` (fix round, I4): `reloadUnlessRebooting` never re-polls on `.reboot`, so the
    /// banner's wording has to know whether it can truthfully point at "the history below" —
    /// see `MaintenanceUncertainView`.
    @State private var maintenanceUncertain: ExploitAction?

    /// Disables every maintenance button while either lane mutates this machine: the kit's
    /// per-machine lock (AD-12) is shared with `FleetModel.run`'s own actions, so a Backup in
    /// flight would otherwise make a dry-run here fail with a raw lock-contention error
    /// instead of simply being unavailable to start.
    ///
    /// n3 (fix round 2): `externalLock` was missing here. Not a regression — the mechanism was
    /// simply incomplete on its own terms: a ⌘1 then ⌘9 mid-action destroys this view (and
    /// `maintenanceBusy` with it) while `externalLock` — held by the surviving `Task` inside
    /// `withExternalLock`, not by this view — still names the machine. Without this term, the
    /// buttons re-enable and a second call hits the kit's raw lock, exactly the defect I4
    /// exists to prevent.
    private var busy: Bool {
        model.inFlight[machine.name] != nil || maintenanceBusy || model.externalLock.contains(machine.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if let maintenanceReport {
                LastActionErrorView(report: maintenanceReport)
            }
            if let maintenanceSuccess {
                MaintenanceSuccessView(message: maintenanceSuccess)
            }
            if let maintenanceUncertain {
                MaintenanceUncertainView(isReboot: {
                    if case .reboot = maintenanceUncertain { return true }
                    return false
                }())
            }
            stateCard
            if case .available(let caps) = capabilities {
                actionsSection(caps: caps)
                homeportConfigSection
            }
            // Fix round 1, m3: pulled out of the `.available` guard above. History is its own
            // read (`maintenanceAudit`, fetched unconditionally in `load()`), not gated on the
            // machine currently being reachable — and `maintenance.execute.uncertain.detail`
            // points at "the history below" from a banner that can outlive `.available`: an
            // uncertain `execute` followed by `reloadUnlessRebooting` can turn a reachable
            // machine unreachable between the click and the re-poll. Keeping the card here
            // (it already renders `describe(state)` on a failed `auditResult`, same as before)
            // keeps that sentence true in both cases instead of having it point at a card that
            // just vanished.
            historySection
        }
        .task { await load() }
        .sheet(item: $pendingPlan) { plan in
            MaintenancePreviewSheet(machineName: machine.name, plan: plan) {
                runExecute(plan)
            }
        }
    }

    // MARK: - Loading

    /// One manager for the whole poll cycle, built fresh inside the detached task and
    /// discarded when it returns — never stashed in `@State` (Global Constraint). The four
    /// reads run concurrently: none of them locks (AD-16 draws the mutation line at the two
    /// `journaled` calls below), so there is nothing to serialize.
    private func load() async {
        let factory = model.makeManager
        let target = machine
        let snapshot = await Task.detached {
            let manager = factory { _ in }
            async let caps = manager.maintenanceCapabilities(of: target)
            async let audit = manager.maintenanceAudit(of: target, limit: 50)
            async let docker = manager.exploit.dockerServices(of: target)
            async let config = manager.exploit.homeportConfig(of: target)
            return await (caps, audit, docker, config)
        }.value
        guard !Task.isCancelled else { return }
        capabilities = snapshot.0
        auditResult = snapshot.1
        dockerServices = snapshot.2
        configResult = snapshot.3
        // A service picked before a re-poll (after an execute, say) that no longer serves
        // that name must not silently keep it selected — the button would just 422.
        if case .success(let services) = snapshot.2, !services.contains(where: { $0.name == selectedService }) {
            selectedService = ""
        }
    }

    /// A `Task.detached` boundary can only cross `Sendable` values — a thrown `Swift.Error`
    /// is not guaranteed to be one, so the closure resolves it to a message *before*
    /// returning, exactly like `FleetModel.fetchLogs` does for its own thrown error. Serves
    /// both halves of the flow: `planID == nil` is the dry-run, `planID` present is the
    /// confirmed execute — each call gets its own fresh manager either way.
    private func attempt(_ action: ExploitAction, planID: String?, target: Machine) async -> MaintenanceAttempt {
        let factory = model.makeManager
        return await Task.detached {
            let manager = factory { _ in }
            do {
                let outcome: ExploitOutcome
                if let planID {
                    outcome = try await manager.maintenanceRun(action, planID: planID, on: target)
                } else {
                    outcome = try await manager.maintenancePlan(action, on: target)
                }
                return .outcome(outcome)
            } catch {
                // The one thrown error this seam admits (LockContentionError) renders the
                // same generic way `FleetModel.run`'s own catch already does for its actions.
                return .failed("\(error)")
            }
        }.value
    }

    // MARK: - Actions

    /// Marks the machine as externally locked for the duration of `body` (I4): `FleetModel.run`
    /// checks `externalLock` before it would otherwise reach the kit's per-machine lock and
    /// throw a raw `LockContentionError`. Cleared by the caller's own `Task`, which — unlike
    /// `.task`'s task — is not cancelled when this view disappears (a tab switch mid-action),
    /// so the lock always clears when the action truly finishes, never left stuck by a
    /// navigation the in-flight `Task.detached` inside `attempt` does not even notice.
    private func withExternalLock<T>(_ body: () async -> T) async -> T {
        model.externalLock.insert(machine.name)
        defer { model.externalLock.remove(machine.name) }
        return await body()
    }

    private func runPreview(_ action: ExploitAction) {
        guard !busy else { return }
        maintenanceBusy = true
        maintenanceReport = nil
        maintenanceSuccess = nil
        maintenanceUncertain = nil
        let target = machine
        Task {
            let result = await withExternalLock { await attempt(action, planID: nil, target: target) }
            maintenanceBusy = false
            switch result {
            case .failed(let message):
                maintenanceReport = FleetModel.LastReport(kind: .failure, message: message)
            case .outcome(let outcome):
                switch outcome {
                case .completed(let planResult):
                    pendingPlan = PendingMaintenancePlan(action: action, machine: target, result: planResult)
                case .staleToken:
                    maintenanceReport = FleetModel.LastReport(
                        kind: .failure, message: String(localized: "maintenance.preview.staleToken"))
                case .unknownAction:
                    maintenanceReport = FleetModel.LastReport(
                        kind: .failure, message: String(localized: "maintenance.unknownAction"))
                case .unavailable(let state):
                    maintenanceReport = FleetModel.LastReport(kind: .failure, message: describe(state))
                // A2 (task 6b): unreachable in practice — `maintenancePlan` always dry-runs,
                // and `ExploitAPIClient.post` produces this outcome only for the `execute`
                // phase (see `ExploitOutcome.executionTimedOut`). Kept for exhaustiveness, but
                // not by setting `maintenanceUncertain` (fix round 1, m2): that banner reads
                // "the server may have completed the action" — true for a stuck `execute`,
                // a lie for a dry-run, which never consumes a plan and is always safe to
                // retry. An `assertionFailure` plus a plain `.failure` report is honest about
                // an invariant break instead of defending it with a message that misdescribes
                // what happened.
                //
                // The message is built here, not via `describe(_:)` (fix round 2, task 6c-A):
                // `describe` promises to be the only phrasing of each *reachable* state, and
                // this branch is not one — feeding it a state the machine isn't in violates
                // that contract. It also must not reuse `describe(.unreachable(...))`'s wording,
                // which names causes (machine off, service stopped, ACL) that do not apply
                // here and would misdirect the reader. The only true fact is that nothing ran.
                case .executionTimedOut:
                    assertionFailure("executionTimedOut from a dry-run: ExploitAPIClient.post only "
                                     + "produces it for the execute phase")
                    maintenanceReport = FleetModel.LastReport(
                        kind: .failure,
                        message: String(localized: "maintenance.preview.inconsistentState"))
                }
            }
        }
    }

    /// UX-DR6's confirmation always dismisses on tap before the mutation runs — the same
    /// optimistic pattern `ConfirmationSheet` already uses for every other destructive
    /// action in this app — so the outcome surfaces afterward through `maintenanceReport`
    /// and the history/state re-poll, not by keeping the sheet open.
    private func runExecute(_ plan: PendingMaintenancePlan) {
        // Without this guard (fix round 1, I1) a double-click on "Execute" — a plausible
        // reflex on a red, hesitated-over button — fires twice before `dismiss()` removes it:
        // two `execute` calls with the *same* `plan_id`. The kit burns the token on the first
        // attempt (ExploitAPIClient.swift), the second gets `.staleToken`, and the screen
        // would announce "preview expired" for an action that just succeeded — on a reboot,
        // the user would then trigger a second one.
        guard !busy, let planID = plan.result.planID else { return }
        maintenanceBusy = true
        maintenanceReport = nil
        maintenanceSuccess = nil
        maintenanceUncertain = nil
        Task {
            let result = await withExternalLock {
                await attempt(plan.action, planID: planID, target: plan.machine)
            }
            maintenanceBusy = false
            switch result {
            case .failed(let message):
                maintenanceReport = FleetModel.LastReport(kind: .failure, message: message)
            case .outcome(let outcome):
                switch outcome {
                case .completed(let execResult):
                    // A completed-but-`ok:false` execution is a finding, not a failure to run
                    // it — same vocabulary `LastActionErrorView` already carries for doctor's
                    // failing checks. A completed, `ok:true` one is not a finding (that kind's
                    // own headline is "reported problems" — wrong for a clean success) but it
                    // still gets the server's own message rather than silence (fix round 1,
                    // I2): the only visible feedback before this was the buttons re-enabling.
                    if execResult.ok {
                        maintenanceReport = nil
                        maintenanceSuccess = execResult.message
                    } else {
                        maintenanceReport = FleetModel.LastReport(kind: .finding, message: execResult.message)
                        maintenanceSuccess = nil
                    }
                    reloadUnlessRebooting(plan.action)
                case .staleToken:
                    maintenanceReport = FleetModel.LastReport(
                        kind: .failure, message: String(localized: "maintenance.execute.staleToken"))
                case .unknownAction:
                    maintenanceReport = FleetModel.LastReport(
                        kind: .failure, message: String(localized: "maintenance.unknownAction"))
                case .unavailable(let state):
                    maintenanceReport = FleetModel.LastReport(kind: .failure, message: describe(state))
                // A2 (task 6b): the server, unlike the client, goes all the way — plan_id
                // consumed, audit line written, update actually run. Rendering this as a
                // failure would reproduce I1 (task 6) one layer down; worse, a retry would hit
                // `.staleToken`, prompt a fresh dry-run, and execute a second time (grave on
                // docker-update: pull + recreate in flight). Neither `.failure` nor `.finding`
                // fits — both say something went wrong, and this might not have — so this gets
                // its own view (`MaintenanceUncertainView`), same doctrine as
                // `MaintenanceSuccessView` (fix round 1, I2) getting its own rather than being
                // forced into `LastReport.Kind`. Still re-polls (unless rebooting): the audit
                // line the server may have written is exactly what "check the history" means.
                // I4 (revue finale) : `maintenanceUncertain` porte l'action, pas juste un
                // `Bool` — `MaintenanceUncertainView` en a besoin pour ne pas prétendre que
                // "l'historique ci-dessous" porte déjà la réponse sur `.reboot`, le seul cas
                // que `reloadUnlessRebooting` ne recharge jamais (voir son commentaire).
                case .executionTimedOut:
                    maintenanceUncertain = plan.action
                    reloadUnlessRebooting(plan.action)
                }
            }
        }
    }

    /// Re-polls so History (and capabilities/config) pick up whatever the server actually
    /// recorded — shared by a completed execution (fix round 1, I2) and by A2's uncertain
    /// outcome (task 6b), since both cases: the server may have done something this client
    /// hasn't seen yet. `reboot`/`poweroff` are the one exception — they make the machine
    /// unreachable on purpose (or, for A2, plausibly did), and re-polling right away would
    /// fold the whole tab onto the "unreachable … Tailscale ACL" card, under a report that
    /// has nothing to do with it.
    ///
    /// I4 (revue finale) : sur ce cas, `maintenance.execute.uncertain.detail` ne peut donc pas
    /// dire "consultez l'historique ci-dessous" — cette liste reste l'instantané d'AVANT
    /// l'exécution, elle ne peut par construction pas porter l'entrée que la phrase désigne.
    /// Arbitrage retenu : reformuler ce cas plutôt que forcer le re-poll qu'on vient d'écarter
    /// deux lignes plus haut — un re-poll ici tirerait une requête HTTP contre une machine qui
    /// s'éteint, avec un délai `.read` (10 s) qui échouera très probablement, et remplacerait
    /// "pas encore d'entrée" par une carte `.unreachable`, un mensonge pire que l'actuel.
    /// `MaintenanceUncertainView(isReboot:)` porte cette distinction.
    private func reloadUnlessRebooting(_ action: ExploitAction) {
        switch action {
        case .reboot: break
        case .aptUpdate, .dockerUpdate: Task { await load() }
        }
    }

    // MARK: - State

    /// The tab's own severity vocabulary — distinct from `FleetRow.Severity` because
    /// `.notDeployed` needs a fourth, neutral value that severity's three cases don't carry:
    /// it is not a problem to fix, and colouring it like one would be a false alarm on two
    /// thirds of the real fleet, on every single visit to this tab.
    private func stateColor(for state: ExploitAvailability) -> Color {
        switch state {
        case .available: return Theme.semanticSuccess
        // `.cancelled` joins `.notDeployed` here, not the warning group below (fix round 1,
        // m2): the contract is explicit that a vanished caller is "never a signal on the
        // machine" (ExploitAPIContract.swift) — painting it as a warning would say the
        // opposite.
        case .notDeployed, .cancelled: return Theme.ink
        case .unreachable, .unexpectedResponse, .unavailable: return Theme.semanticWarning
        case .forbidden: return Theme.semanticCritical
        }
    }

    private func stateLabel(for state: ExploitAvailability) -> LocalizedStringKey {
        switch state {
        case .available: return "maintenance.state.available"
        case .notDeployed: return "maintenance.state.notDeployed"
        case .cancelled: return "maintenance.state.cancelled"
        case .unreachable, .unexpectedResponse, .unavailable: return "maintenance.state.attention"
        case .forbidden: return "maintenance.state.forbidden"
        }
    }

    /// Pastille + libellé texte (UX-DR7): the pill never carries the state alone —
    /// `describe(state)` sits right beside it, in the one formulation `hpm maintenance`
    /// already uses, verbatim (never a second wording of the same state).
    private func statePill(_ state: ExploitAvailability) -> some View {
        Text(stateLabel(for: state))
            .styled(Theme.eyebrow)
            .foregroundStyle(stateColor(for: state))
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.pill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Rounded.pill)
                    .stroke(stateColor(for: state).opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var stateCard: some View {
        if let capabilities {
            switch capabilities {
            case .available:
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    statePill(capabilities)
                    Text(verbatim: describe(capabilities))
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(Theme.body.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.sm)
                    // I3 (fix round 1): the only reload affordance once this tab has
                    // something to reload — ⌘R only refreshes the fleet's SSH poll
                    // (`ControlCenterView`), never this tab's own four reads, and leaving the
                    // tab and coming back is the only other way to get `.task` to run again.
                    //
                    // n2 (fix round 2): "Retry" ("Réessayer") under a green "Available" pill
                    // announces a failure where none happened — a dedicated key, used only
                    // here. The `.unreachable`/`.unavailable`/`.forbidden` card below keeps
                    // "Retry": there, a retry is exactly what it is.
                    Button { Task { await load() } } label: { Text("maintenance.state.refresh") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .accessibilityElement(children: .combine)
            // `.notDeployed` and `.cancelled` are both neutral, not the warning group below
            // (fix round 1, m2 for `.cancelled` — the contract says a vanished caller is
            // "never a signal on the machine"): same card weight as `.available`
            // (task-6 brief: "soigne-le autant que le chemin nominal"), no Retry — there is
            // nothing here a re-poll would fix that the next `load()` will not retry on its
            // own regardless.
            case .notDeployed, .cancelled:
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    statePill(capabilities)
                    Text(verbatim: describe(capabilities))
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(Theme.body.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .notDeployed = capabilities {
                        Text("maintenance.notDeployed.hint")
                            .styled(Theme.body)
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(Theme.body.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xl)
                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
                .accessibilityElement(children: .combine)
            case .unreachable, .unexpectedResponse, .unavailable, .forbidden:
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    statePill(capabilities)
                    Text(verbatim: describe(capabilities))
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(Theme.body.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { Task { await load() } } label: { Text("Retry") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xl)
                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.lg))
                .accessibilityElement(children: .combine)
            }
        } else {
            ProgressView()
                .accessibilityLabel(Text("maintenance.loading"))
        }
    }

    // MARK: - Action cards

    private func actionsSection(caps: ExploitCapabilities) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Actions")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            if caps.serves(ExploitAction.aptUpdate.name) {
                aptUpdateCard
            }
            if caps.serves(ExploitAction.reboot(mode: .reboot).name) {
                rebootCard
            }
            if caps.serves(ExploitAction.dockerUpdate(service: "").name) {
                dockerUpdateCard
            }
        }
    }

    private func actionCard<Content: View>(title: LocalizedStringKey,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .styled(Theme.eyebrow)
                .foregroundStyle(Theme.ink)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(Theme.hairline, lineWidth: 1))
    }

    private var aptUpdateCard: some View {
        // Fix round 1, m4: a distinct card title — "Update packages" straight above a button
        // saying the same thing read as one label split in two, unlike the reboot/docker
        // cards, whose titles ("Power", "Docker service update") differ from their buttons.
        actionCard(title: "maintenance.aptUpdate.cardTitle") {
            Button { runPreview(.aptUpdate) } label: {
                Text(verbatim: "\(String(localized: "Update packages"))…")
            }
            .buttonStyle(PillButtonStyle(kind: .destructive))
            .disabled(busy)
            .accessibilityLabel(Text("Update packages"))
        }
    }

    private var rebootCard: some View {
        actionCard(title: "maintenance.reboot.title") {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ExploitAction.RebootMode.allCases, id: \.rawValue) { mode in
                    Button { runPreview(.reboot(mode: mode)) } label: {
                        Text(verbatim: "\(rebootModeText(mode))…")
                    }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
                    .disabled(busy)
                    .accessibilityLabel(Text(rebootModeKey(mode)))
                }
            }
        }
    }

    /// `Text` and `String(localized:)` take two different literal-key types
    /// (`LocalizedStringKey` vs `String.LocalizationValue`) that do not convert into one
    /// another — hence the two accessors below rather than one shared `LocalizedStringKey`.
    private func rebootModeKey(_ mode: ExploitAction.RebootMode) -> LocalizedStringKey {
        switch mode {
        case .reboot: return "maintenance.reboot.reboot"
        case .poweroff: return "maintenance.reboot.poweroff"
        }
    }

    private func rebootModeText(_ mode: ExploitAction.RebootMode) -> String {
        switch mode {
        case .reboot: return String(localized: "maintenance.reboot.reboot")
        case .poweroff: return String(localized: "maintenance.reboot.poweroff")
        }
    }

    @ViewBuilder
    private var dockerUpdateCard: some View {
        actionCard(title: "maintenance.dockerUpdate.title") {
            if let dockerServices {
                switch dockerServices {
                case .success(let services) where services.isEmpty:
                    Text("maintenance.docker.empty")
                        .styled(Theme.body)
                        .foregroundStyle(Theme.ink)
                case .success(let services):
                    HStack(spacing: Theme.Spacing.sm) {
                        Picker("maintenance.docker.service", selection: $selectedService) {
                            Text("maintenance.docker.pick").tag("")
                            ForEach(services) { service in
                                Text(verbatim: service.name).tag(service.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Button { runPreview(.dockerUpdate(service: selectedService)) } label: {
                            Text(verbatim: "\(String(localized: "maintenance.dockerUpdate.button"))…")
                        }
                        .buttonStyle(PillButtonStyle(kind: .destructive))
                        .disabled(busy || selectedService.isEmpty)
                        .accessibilityLabel(Text("maintenance.dockerUpdate.button"))
                    }
                case .failure(let state):
                    // Never a hard-coded fallback list (the known, parked defect of the
                    // Pi's own web UI) — the failure is said plainly instead.
                    Text(verbatim: describe(state))
                        .styled(Theme.data)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
            } else {
                // Fix round 1, m3: reused rather than three new keys — all three sections
                // load as part of the same poll cycle `maintenance.loading` already names.
                ProgressView()
                    .accessibilityLabel(Text("maintenance.loading"))
            }
        }
    }

    // MARK: - Homeport config (read-only)

    @ViewBuilder
    private var homeportConfigSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("maintenance.config.title")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            if let configResult {
                switch configResult {
                case .success(let content):
                    if let content {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(verbatim: content)
                                .styled(Theme.data)
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(Theme.data.lineSpacing)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Spacing.sm)
                                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
                            Text("maintenance.config.readOnlyHint")
                                .styled(Theme.caption)
                                .foregroundStyle(Theme.ink)
                        }
                    } else {
                        // 404 here means "no file on the Pi", never "server too old" —
                        // `homeportConfig(of:)`'s own doctrine, not shared with the other
                        // three reads (see its comment in ExploitAPIClient.swift).
                        Text("maintenance.config.notFound")
                            .styled(Theme.body)
                            .foregroundStyle(Theme.ink)
                    }
                case .failure(let state):
                    Text(verbatim: describe(state))
                        .styled(Theme.data)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
            } else {
                // Fix round 1, m3: reused rather than three new keys — all three sections
                // load as part of the same poll cycle `maintenance.loading` already names.
                ProgressView()
                    .accessibilityLabel(Text("maintenance.loading"))
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("maintenance.history.title")
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            if let auditResult {
                switch auditResult {
                case .success(let entries) where entries.isEmpty:
                    // Fix round 1, m5: its own title, not the section's — same pattern as
                    // `MachineDetailView.recentTasks`'s "Recent tasks" header above a "No
                    // tasks yet" empty state, rather than "Recent tasks" stacked on itself.
                    EmptyStateView(title: "maintenance.history.empty.title", message: "maintenance.history.empty")
                case .success(let entries):
                    DataTable(columns: historyColumns, rows: auditRows(entries),
                              rowLabel: { auditAnnouncement($0.entry) })
                case .failure(let state):
                    Text(verbatim: describe(state))
                        .styled(Theme.data)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
            } else {
                // Fix round 1, m3: reused rather than three new keys — all three sections
                // load as part of the same poll cycle `maintenance.loading` already names.
                ProgressView()
                    .accessibilityLabel(Text("maintenance.loading"))
            }
        }
    }

    /// `ExploitAuditEntry` is not `Identifiable` (Manager+Maintenance.swift task-5 brief:
    /// the server keeps no id, so a client that needs one builds its own) — position in this
    /// already-ordered slice is that identity.
    private func auditRows(_ entries: [ExploitAuditEntry]) -> [AuditRow] {
        entries.enumerated().map { AuditRow(id: $0.offset, entry: $0.element) }
    }

    private var historyColumns: [DataColumn<AuditRow>] {
        [
            DataColumn("Date", width: 150) { row in TaskDateText(date: row.entry.timestamp) },
            DataColumn("Action") { row in
                Text(verbatim: row.entry.action)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            },
            DataColumn("Dry run", width: 70) { row in
                Text(row.entry.dryRun ? "maintenance.history.yes" : "maintenance.history.no")
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
            },
            DataColumn("Status", width: 70) { row in
                Text(row.entry.ok ? "maintenance.history.ok" : "maintenance.history.failed")
                    .styled(Theme.data)
                    .foregroundStyle(row.entry.ok ? Theme.semanticSuccess : Theme.semanticCritical)
            },
            DataColumn("Message") { row in
                Text(verbatim: row.entry.message)
                    .styled(Theme.data)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            },
        ]
    }

    /// One VoiceOver announcement per history row — same shape as `taskAnnouncement`
    /// (FleetOverviewView.swift): action, then the localized status, then the timestamp
    /// spoken as a formatted date rather than a raw ISO 8601 string.
    private func auditAnnouncement(_ entry: ExploitAuditEntry) -> Text {
        Text(verbatim: entry.action)
            + Text(verbatim: ". ")
            + Text(entry.ok ? "maintenance.history.ok" : "maintenance.history.failed")
            + Text(verbatim: ". ")
            + Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
    }
}

/// Resolves a `Task.detached` boundary crossing that a thrown `Swift.Error` cannot make
/// safely on its own — see `MaintenanceTabView.attempt(_:planID:target:)`.
private enum MaintenanceAttempt: Sendable {
    case outcome(ExploitOutcome)
    case failed(String)
}

/// A completed, `ok:true` execution's own confirmation (fix round 1, I2) — same box
/// language as `LastActionErrorView`/`StaleDataNotice` (`surfaceSoft`, `Rounded.md`), but its
/// own headline and `semanticSuccess` ink: `LastActionErrorView`'s two kinds are both a form
/// of "something needs attention", which a clean success is not.
private struct MaintenanceSuccessView: View {
    /// Server content — the message HomePortExploit sent back — shown as produced, never
    /// translated, like every other machine-authored string in this app.
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("maintenance.execute.success")
                .styled(Theme.bodyStrong)
                .foregroundStyle(Theme.semanticSuccess)
            Text(verbatim: message)
                .styled(Theme.data)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.data.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(Theme.semanticSuccess.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A2's own box (task 6b): a transport timeout during `execute` — the server may have gone
/// all the way despite the client giving up on the wait. Neither `LastActionErrorView`'s
/// `.failure`/`.finding` (both say something went wrong; this might not have) nor
/// `MaintenanceSuccessView` (no server message was ever received to show) fits, so this gets
/// its own box, same doctrine as `MaintenanceSuccessView` itself (fix round 1, I2) — warning
/// ink rather than success or critical: not a confirmed failure, not a confirmed success
/// either. No dynamic content, unlike the other two: a timeout means no reply was ever read.
private struct MaintenanceUncertainView: View {
    /// I4 (revue finale) : `reloadUnlessRebooting` ne re-poll jamais après un `.reboot`/
    /// `.poweroff` — voir son commentaire. La formulation par défaut de `.detail` pointe vers
    /// "l'historique ci-dessous", qui n'est vrai que quand ce re-poll a bien eu lieu.
    let isReboot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("maintenance.execute.uncertain.title")
                .styled(Theme.bodyStrong)
                .foregroundStyle(Theme.semanticWarning)
            Text(isReboot ? "maintenance.execute.uncertain.detail.reboot" : "maintenance.execute.uncertain.detail")
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: Theme.Rounded.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Rounded.md)
                .stroke(Theme.semanticWarning.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// One dry-run's result, awaiting its UX-DR6 confirmation. Never carries the `HomeportManager`
/// that produced it (Global Constraint — see `MaintenanceTabView.pendingPlan`'s own comment).
private struct PendingMaintenancePlan: Identifiable {
    let id = UUID()
    let action: ExploitAction
    /// Frozen at dry-run time (fix round 1, m7): `MachineDetailView`'s `.id(machine.name)`
    /// keys on the *name*, not the value, so a `fleet.yaml` reload between the dry-run and
    /// the confirmation — purely theoretical, it takes an edit mid-flow — would otherwise
    /// have `runExecute` read whatever `exploitPort`/`ssh` the view's `machine` holds *now*,
    /// not the one the preview was actually run against.
    let machine: Machine
    let result: ExploitResult
}

/// `ExploitAuditEntry` plus the identity `DataTable` needs and the contract does not carry.
private struct AuditRow: Identifiable {
    let id: Int
    let entry: ExploitAuditEntry
}

/// The UX-DR6 confirmation for a maintenance action: the dry-run's own message and detail
/// lines (`result.detail.displayLines` — for `apt-update`, the real package list), never a
/// second, hand-written description of what is about to happen. Bespoke rather than
/// `ConfirmationSheet` (DesignComponents.swift): that component's `consequence` is a single
/// `LocalizedStringKey`, which cannot carry a dynamic, unlocalized list of server-authored
/// lines — but it reuses that component's exact visual language (padding, buttons, the one
/// critical ground in the app).
private struct MaintenancePreviewSheet: View {
    let machineName: String
    let plan: PendingMaintenancePlan
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// CLI parity (`MaintenanceCmd.Run.run()`): a dry-run that answered but is not `ok`, or
    /// carries no `plan_id`, never reaches execute — the sheet still shows why, just with
    /// nothing left to confirm.
    private var canExecute: Bool { plan.result.ok && plan.result.planID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .styled(Theme.sectionTitle)
                .foregroundStyle(Theme.ink)
            Text(verbatim: plan.result.message)
                .styled(Theme.body)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.body.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // `apt-update`'s detail is one line per pending package — 60 to 200 on a real
            // Pi, the nominal case this sheet exists for, not the exception. Unbounded, that
            // list pushes Cancel/Execute off the bottom of the sheet entirely (C1): the more
            // useful the preview, the less reachable the button that acts on it. Capped and
            // scrollable, the button bar always stays on screen.
            if !plan.result.detail.displayLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(Array(plan.result.detail.displayLines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .styled(Theme.data)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Spacer(minLength: 0)
                Button { dismiss() } label: { Text(canExecute ? "Cancel" : "Close") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                if canExecute {
                    // Dismiss-then-fire, same as `ConfirmationSheet`: the mutation's own
                    // outcome surfaces afterward (`maintenanceReport`, the history re-poll),
                    // not by keeping this sheet open.
                    Button { dismiss(); confirm() } label: { Text("maintenance.confirm.execute") }
                        .buttonStyle(PillButtonStyle(kind: .critical))
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420, alignment: .leading)
        .background(Theme.canvas)
    }

    private var title: LocalizedStringKey {
        switch plan.action {
        case .aptUpdate: return "Update packages on \(machineName)"
        case .reboot(.reboot): return "Reboot \(machineName)"
        case .reboot(.poweroff): return "Power off \(machineName)"
        case .dockerUpdate: return "Update Docker service on \(machineName)"
        }
    }
}
