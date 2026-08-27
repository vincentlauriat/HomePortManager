import SwiftUI
import HomePortKit

/// The Updates tab (story 3.3): installed version against the latest tagged release, its
/// notes, and the one button that triggers a guided update.
///
/// No new mutation mechanic: setting `pendingAction` to `.update` opens the exact same
/// `ConfirmationSheet` the Summary action bar already wires up in `MachineDetailView`, which
/// runs `FleetModel.run(.update, on:)` — same lock (AD-12), same journal, same pin of
/// `latestTag` at confirmation time, same CLI parity (FR11) as `hpm update <machine>`. This
/// view only decides what to show and when the button is available.
struct UpdatesTabView: View {
    @ObservedObject var model: FleetModel
    let machine: Machine
    /// The parent sheet's own `@State`: this tab never owns a second confirmation flow.
    @Binding var pendingAction: FleetModel.Action?

    private var busy: Bool { model.inFlight[machine.name] != nil }

    /// Last known status for this machine — current if reachable, else the last reachable
    /// one, same helper the Summary tab's `versionValue` reads.
    private var display: (status: MachineStatus?, lastSeen: Date?) {
        model.displayStatus(for: machine)
    }

    private enum State {
        /// No observation of this machine has ever landed — matches the I/O matrix's
        /// "machine injoignable" row (`model.statuses[machine.name]` absent).
        case unreachable
        /// `ReleaseService.list()`/`.latest()` failed (or has not resolved yet): no tag to
        /// compare against, so no update can be proposed either way.
        case releasesUnavailable
        case upToDate(installed: String)
        case available(installed: String, target: String)
    }

    /// Deliberately does **not** go through `MachineDetailView`'s `issues`/`machineIssues`:
    /// those are derived from the *live* `model.statuses[machine.name]`, which collapses to
    /// `[.unreachable]` — no `.updateAvailable` — the instant the machine drops offline. That
    /// would make a machine with a real pending update read as "up to date" the moment it
    /// goes unreachable, right next to a notice saying the data is stale. `updateTarget` is
    /// the same comparison `machineIssues` runs, called here against `display.status`
    /// (stale-aware) instead — one shared rule, two callers that need it at different
    /// staleness.
    private var state: State {
        guard let status = display.status else { return .unreachable }
        guard let latest = model.latestTag else { return .releasesUnavailable }
        if let target = updateTarget(installed: status.installedVersion, latest: latest) {
            return .available(installed: status.installedVersion, target: target)
        }
        return .upToDate(installed: status.installedVersion)
    }

    /// True when the version data on screen is the last *reachable* observation rather than
    /// a live one — `display.status` keeps showing it (same as Summary), but the badge or
    /// the proposed update must say so rather than read as current.
    private var isStale: Bool {
        display.status != nil && model.statuses[machine.name]?.reachable != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // A failure from an update triggered here must surface here too, exactly like
            // any other action on Summary (I/O matrix: "Échec d'exécution → lastError
            // affiché, comme les autres actions") — not only on the tab the user has since
            // navigated away from.
            if let report = model.lastError[machine.name] {
                LastActionErrorView(report: report)
            }
            switch state {
            case .unreachable:
                EmptyStateView(
                    title: "Unreachable",
                    message: "\(machine.name) is unreachable. Check Tailscale or retry.",
                    actionTitle: "Retry", action: { model.refresh() })
            case .releasesUnavailable:
                // Same verdict and same wording the menu bar's update button already
                // disables on (`MenuContent.updateLabel`) — one sentence, two surfaces.
                EmptyStateView(
                    title: "Releases unavailable",
                    message: "GitHub unreachable — latest version unknown",
                    actionTitle: "Retry", action: { model.refresh() })
            case .upToDate(let installed):
                if isStale { StaleDataNotice(model: model) }
                versionRow(installed: installed, target: nil)
                upToDateBadge
            case .available(let installed, let target):
                if isStale { StaleDataNotice(model: model) }
                versionRow(installed: installed, target: target)
                if let notes = model.latestReleaseNotes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notesSection(notes)
                }
                updateButton
            }
        }
    }

    // MARK: - Rows

    private func versionRow(installed: String, target: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("Version")
                .styled(Theme.eyebrow)
                .foregroundStyle(Theme.ink)
                .textCase(.uppercase)
            HStack(spacing: Theme.Spacing.xs) {
                // Machine output: shown as produced, never translated — same rule as
                // `MachineDetailView.versionValue`, which this row mirrors.
                Text(verbatim: installed).styled(Theme.data).foregroundStyle(Theme.ink)
                if let target {
                    Text(verbatim: "→ \(target)").styled(Theme.data)
                        .foregroundStyle(Theme.semanticWarning)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var upToDateBadge: some View {
        Text("Up to date")
            .styled(Theme.eyebrow)
            .foregroundStyle(Theme.semanticSuccess)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("Release notes")
                .styled(Theme.eyebrow)
                .foregroundStyle(Theme.ink)
                .textCase(.uppercase)
            // Release-authored Markdown, rendered rather than shown as raw `#`/`-`/`**`
            // source — but never translated, same "machine-authored content" rule as
            // report messages and log lines elsewhere in this app.
            Text(renderedNotes(notes))
                .styled(Theme.data)
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.data.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Falls back to the raw source on a parse failure rather than hiding the notes —
    /// unrendered Markdown is still more useful than nothing.
    private func renderedNotes(_ notes: String) -> AttributedString {
        (try? AttributedString(markdown: notes)) ?? AttributedString(notes)
    }

    private var updateButton: some View {
        Button {
            pendingAction = .update
        } label: {
            Text("Update now")
        }
        // `.destructive`, not `.critical`: the red ground stays reserved for the
        // confirmation sheet itself (UX-DR6) — same rule the Summary action bar follows.
        .buttonStyle(PillButtonStyle(kind: .destructive))
        .disabled(busy)
        .accessibilityLabel(Text("Update now"))
    }
}
