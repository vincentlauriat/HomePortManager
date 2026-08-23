import SwiftUI
import AppKit
import HomePortKit

struct MenuContent: View {
    @ObservedObject var model: FleetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HomePort fleet").font(.headline)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
            }
            Divider()
            // The control center has no other entry point.
            Button { ControlCenterWindow.open(model: model) } label: {
                Label("Open the control center", systemImage: "macwindow")
            }
            .keyboardShortcut("o")
            .buttonStyle(.link)
            .accessibilityLabel(Text("Open the control center"))
            Divider()
            if model.machines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No machines declared.")
                    Text(verbatim: "hpm machine add <name> --ssh <host>")
                        .textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.machines, id: \.name) { machine in
                MachineRow(model: model, machine: machine)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var footer: some View {
        HStack {
            Button { model.machines.forEach { model.run(.backup, on: $0) } } label: {
                Text("Backup all")
            }
            .disabled(model.machines.isEmpty || !model.inFlight.isEmpty)
            Button { model.refresh() } label: { Text("Refresh") }
                .disabled(model.refreshing)
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: expandPath(FleetStore.defaultPath)))
            } label: {
                Text("Edit fleet")
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Text("Quit") }
        }
        .controlSize(.small)
    }
}

struct MachineRow: View {
    @ObservedObject var model: FleetModel
    let machine: Machine

    private var status: MachineStatus? { model.statuses[machine.name] }
    /// The same list the control center reads — including `.unreachable`, which is why the
    /// warning line no longer vanishes exactly when the machine has a problem.
    private var issues: [MachineIssue] {
        machineIssues(status, latest: model.latestTag)
    }
    private var reasons: [LocalizedStringKey] { statusReasons(issues) }
    private var busy: Bool { model.inFlight[machine.name] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text(verbatim: machine.name).fontWeight(.semibold)
                versionText.foregroundStyle(.secondary).font(.caption)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    actions
                }
            }
            if let status, status.reachable {
                Text("Uptime \(uptime) · Disk \(disk) · Backup \(backup)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 15)
            }
            // `LocalizedStringKey` is not Hashable: the position is the identity here.
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Label { Text(reason) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 15)
            }
            if let report = model.lastError[machine.name] {
                // Machine output: shown as produced, never translated. A finding (doctor's
                // failing checks on a succeeded run) warns; only a real failure reads red.
                Label { Text(verbatim: report.message) } icon: {
                    Image(systemName: report.kind == .failure ? "xmark.octagon" : "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(report.kind == .failure ? .red : .orange)
                .padding(.leading, 15)
                .lineLimit(3)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.run(.backup, on: machine) } label: {
                Image(systemName: "archivebox")
            }
            .help(Text("Backup now"))
            .accessibilityLabel(Text("Backup now"))
            Button {
                if confirm(String(localized: "Restart homeport on \(machine.name)?")) {
                    model.run(.restart, on: machine)
                }
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .help(Text("Restart service"))
            .accessibilityLabel(Text("Restart service"))
            Button {
                // Unreachable when `latestTag` is nil: the button is disabled in that case.
                guard let latest = model.latestTag else { return }
                if confirm(String(localized: "Update \(machine.name) to \(latest)? A backup is taken first.")) {
                    model.run(.update, on: machine)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            // P10: VoiceOver has to hear *why* the button is dead, exactly as the tooltip
            // says it — a fixed label announces an action that cannot be taken.
            .help(updateLabel)
            .accessibilityLabel(updateLabel)
            .disabled(model.latestTag == nil)
            Button { LogsWindow.open(for: machine, model: model) } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help(Text("Show logs"))
            .accessibilityLabel(Text("Show logs"))
        }
        .buttonStyle(.borderless)
        .disabled(status?.reachable != true)
    }

    /// The menu bar dot and the control center's pill must never say different things about
    /// the same machine: both colour a `severity`, and the severity comes from the kit.
    private var dotColor: Color {
        Theme.color(of: HomePortKit.severity(of: issues))
    }

    @ViewBuilder
    private var versionText: some View {
        if let status {
            if status.reachable {
                if let latest = issues.availableUpdate {
                    Text(verbatim: "\(status.installedVersion) → \(latest)")
                } else {
                    Text(verbatim: status.installedVersion)
                }
            } else {
                Text("Unreachable")
            }
        } else {
            Text(verbatim: "…")
        }
    }

    private var updateLabel: Text {
        model.latestTag == nil
            ? Text("GitHub unreachable — latest version unknown")
            : Text("Update (backup first)")
    }

    /// Durations, sizes and dates are shown to a human, so they go through a localized
    /// `FormatStyle` rather than the kit's compact English forms, which the CLI owns.
    private var uptime: String {
        guard let seconds = status?.uptimeSeconds else { return "—" }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
    }

    private var disk: String {
        status?.diskUsedPercent.map(FleetOverviewView.percent) ?? "—"
    }

    private var backup: String {
        guard let date = backupTimestamp(status?.lastBackup) else {
            return String(localized: "never")
        }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: String(localized: "OK"))   // the button's word, not the pill's
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
