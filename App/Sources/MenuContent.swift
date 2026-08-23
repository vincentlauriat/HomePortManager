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
            if model.machines.isEmpty {
                Text("No machines declared.\nRun: hpm machine add <name> --ssh <host>")
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
            Button("Backup all") {
                model.machines.forEach { model.run(.backup, on: $0) }
            }
            .disabled(model.machines.isEmpty || !model.inFlight.isEmpty)
            Button("Refresh") { model.refresh() }
                .disabled(model.refreshing)
            Button("Edit fleet") {
                NSWorkspace.shared.open(URL(fileURLWithPath: expandPath(FleetStore.defaultPath)))
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

struct MachineRow: View {
    @ObservedObject var model: FleetModel
    let machine: Machine

    private var status: MachineStatus? { model.statuses[machine.name] }
    private var warnings: [String] {
        status.map { machineWarnings($0, latest: model.latestTag) } ?? []
    }
    private var busy: Bool { model.inFlight.contains(machine.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text(machine.name).fontWeight(.semibold)
                Text(versionText).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    actions
                }
            }
            if let status, status.reachable {
                Text("up \(formatUptime(status.uptimeSeconds)) · disk \(status.diskUsedPercent.map { "\($0)%" } ?? "-") · backup \(backupAge(status.lastBackup))")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 15)
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 15)
            }
            if let error = model.lastError[machine.name] {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.leading, 15)
                    .lineLimit(3)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.run(.backup, on: machine) } label: {
                Image(systemName: "archivebox")
            }.help("Backup now")
            Button {
                if confirm("Restart homeport on \(machine.name)?") {
                    model.run(.restart, on: machine)
                }
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }.help("Restart service")
            Button {
                let target = model.latestTag ?? "latest"
                if confirm("Update \(machine.name) to \(target)? A backup is taken first.") {
                    model.run(.update, on: machine)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help(model.latestTag == nil ? "GitHub unreachable — latest version unknown" : "Update (backup first)")
            .disabled(model.latestTag == nil)
            Button { LogsWindow.open(for: machine, model: model) } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }.help("Show logs")
        }
        .buttonStyle(.borderless)
        .disabled(status?.reachable != true)
    }

    private var dotColor: Color {
        guard let status else { return .gray }
        guard status.reachable else { return .gray }
        if status.serviceActive && status.healthzOK {
            return warnings.isEmpty ? .green : .yellow
        }
        return .red
    }

    private var versionText: String {
        guard let status else { return "…" }
        guard status.reachable else { return "unreachable" }
        if let latest = model.latestTag, status.installedVersion != "unknown",
           status.installedVersion != latest {
            return "\(status.installedVersion) → \(latest)"
        }
        return status.installedVersion
    }

    private func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
