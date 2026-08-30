import Foundation

extension HomeportManager {
    /// Deploys (idempotently) the declared backup job as a systemd `.service`/`.timer`
    /// pair plus the autonomous root script that performs the actual backup — content
    /// ported from `performBackup` (Manager+Backup.swift), which this never calls or
    /// modifies. The script resolves everything it needs locally on the machine: no SSH
    /// round-trip, no dependency on the Mac being reachable (epic 3's core requirement).
    public func applyBackupJob(on machine: Machine) throws {
        try journaled("backup-apply", on: machine, locking: true) { try performApplyBackupJob(on: machine) }
    }

    private func performApplyBackupJob(on machine: Machine) throws {
        guard let job = try BackupJobStore(root: jobsRoot).load(for: machine.name) else {
            throw HPMError("""
            no backup job declared for '\(machine.name)' — declare one first: \
            hpm backup apply \(machine.name) --schedule <OnCalendar expression, e.g. daily>
            """)
        }
        // Defense in depth: the CLI already rejects this before writing the job, but a
        // hand-edited YAML file or a future non-CLI writer (the app, story 3.2) could not.
        try Self.validateBackupJobInputs(schedule: job.schedule, machineName: machine.name)

        // Always checked first, before a single file is touched: an explicit, actionable
        // refusal rather than a partial deployment (spec Boundaries: "Always").
        report("Checking sudo precondition on \(machine.name)…")
        let sudoCheck = try ssh.run(on: machine.ssh, "sudo -n true")
        guard sudoCheck.succeeded else {
            throw HPMError("""
            passwordless sudo is required on \(machine.name) before deploying the backup job \
            (probe: sudo -n true) — configure NOPASSWD sudo for the SSH user first, or run: \
            hpm prereqs \(machine.name)
            """)
        }

        report("Deploying \(RemotePaths.backupUnit)/\(RemotePaths.backupTimer) on \(machine.name)…")
        let script = Self.backupJobDeployScript(machineName: machine.name, job: job)
        let result = try ssh.run(on: machine.ssh, script, sudo: true)
        guard result.succeeded else {
            throw HPMError("backup job deployment on \(machine.name) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        report("Backup job active on \(machine.name) — schedule '\(job.schedule)', keep \(job.retention) local archives.")
    }

    /// The three heredoc terminators used by `backupJobDeployScript`. A `schedule` or
    /// `machine.name` containing a newline plus one of these exact strings on its own line
    /// would close a heredoc early and let its remainder run as root on the Pi — so any
    /// value merely *containing* one of these substrings, or a newline at all, is refused
    /// before it ever reaches the script (`validateBackupJobInputs`).
    static let heredocMarkers = ["HPM_BACKUP_UNIT", "HPM_BACKUP_TIMER", "HPM_BACKUP_SCRIPT"]

    /// Public: the CLI calls this before writing a job to `BackupJobStore` (findings #1/#4),
    /// so the check happens before anything reaches disk, not just before deployment.
    public static func validateBackupJobInputs(schedule: String, machineName: String) throws {
        for (label, value) in [("--schedule", schedule), ("machine name", machineName)] {
            guard !value.contains("\n"), !value.contains("\r") else {
                throw HPMError("\(label) cannot contain a newline")
            }
            for marker in heredocMarkers where value.contains(marker) {
                throw HPMError("\(label) cannot contain '\(marker)'")
            }
        }
    }

    /// The whole deployment as one script, fed to `sudo bash -s` (SSHClient's heredoc-sudo
    /// pattern — no shell-quoting pitfalls for a multi-line script): write both units and
    /// the script — each atomically, `.new` + `mv -f`, so an SSH drop mid-write can never
    /// leave a corrupt unit file or a torn script that bash is mid-executing — then
    /// `daemon-reload` and enable **only the timer**. The service has no `[Install]` section
    /// and is never enabled/started directly — it exists to be invoked by the timer, exactly
    /// like `../Homeport/deploy/nvme/homeport-nvme.{service,timer}`. The explicit `restart`
    /// after `enable --now` is what makes a changed `--schedule` take effect promptly:
    /// `enable --now` alone is a no-op on an already-active timer and does not make it
    /// recompute its next elapse from a new `OnCalendar=`. Rewriting identical content and
    /// replaying this is otherwise a no-op: the machine is left unchanged (idempotence row).
    static func backupJobDeployScript(machineName: String, job: BackupJob) -> String {
        """
        set -euo pipefail
        cat > /etc/systemd/system/\(RemotePaths.backupUnit).new <<'HPM_BACKUP_UNIT'
        \(serviceUnitContents)
        HPM_BACKUP_UNIT
        mv -f /etc/systemd/system/\(RemotePaths.backupUnit).new /etc/systemd/system/\(RemotePaths.backupUnit)
        cat > /etc/systemd/system/\(RemotePaths.backupTimer).new <<'HPM_BACKUP_TIMER'
        \(timerUnitContents(schedule: job.schedule))
        HPM_BACKUP_TIMER
        mv -f /etc/systemd/system/\(RemotePaths.backupTimer).new /etc/systemd/system/\(RemotePaths.backupTimer)
        cat > \(RemotePaths.backupScript).new <<'HPM_BACKUP_SCRIPT'
        \(backupScriptContents(machineName: machineName, retention: job.retention))
        HPM_BACKUP_SCRIPT
        chmod 0755 \(RemotePaths.backupScript).new
        mv -f \(RemotePaths.backupScript).new \(RemotePaths.backupScript)
        systemctl daemon-reload
        systemctl enable --now \(RemotePaths.backupTimer)
        systemctl restart \(RemotePaths.backupTimer)
        """
    }

    private static let serviceUnitContents = """
    [Unit]
    Description=Homeport — scheduled backup (autonomous; runs whether or not the Mac is reachable)
    Documentation=file://\(RemotePaths.backupScript)
    After=local-fs.target

    [Service]
    Type=oneshot
    ExecStart=\(RemotePaths.backupScript)
    """

    private static func timerUnitContents(schedule: String) -> String {
        """
        [Unit]
        Description=Homeport — scheduled backup timer

        [Timer]
        OnCalendar=\(schedule)
        Persistent=true
        RandomizedDelaySec=300

        [Install]
        WantedBy=timers.target
        """
    }

    /// Bash port of `performBackup`'s content (config + data dir, sqlite-safe, tar,
    /// rotation) — same shape, same fallback branches, deliberately not "improved" here
    /// (spec: "même contenu que performBackup"). Two things only this script adds, because
    /// they are this story's own requirements, not performBackup's: the flock rendezvous
    /// (AD-12/F1) and a strictly atomic tmp+mv for the archive (performBackup already
    /// stages into a tmp dir, but writes the final tarball straight to its destination).
    private static func backupScriptContents(machineName: String, retention: Int) -> String {
        """
        #!/usr/bin/env bash
        # Deployed by `hpm backup apply` — overwritten on every apply, do not edit by hand.
        set -euo pipefail

        MACHINE="\(machineName)"
        RETAIN=\(retention)
        BACKUPS_DIR="\(RemotePaths.backups)"
        CONFIG_DIR="\(RemotePaths.config)"
        UNIT="\(RemotePaths.unit)"
        DEFAULT_DATA_DIR="\(RemotePaths.data)"
        VERSION_MARKER="\(RemotePaths.versionMarker)"
        LOCK="\(RemotePaths.backupLock)"

        # A mutating hpm action in progress on this machine holds the same lock (AD-12/F1):
        # skip this run rather than block or race it. The next tick retries.
        exec 9>"$LOCK"
        if ! flock -n 9; then
          echo "homeport-backup: lock held by another hpm-mutating action — skipping this run" >&2
          exit 0
        fi

        version=$(cat "$VERSION_MARKER" 2>/dev/null || echo unknown)

        # Effective data dir: a systemd drop-in may override HOMEPORT_DATA_DIR (raspcorse
        # keeps its data on an SSD) — last override wins, same rule as Manager+Backup's dataDir(on:).
        data_dir="$DEFAULT_DATA_DIR"
        env_output=$(systemctl show "$UNIT" -p Environment 2>/dev/null || true)
        for tok in $(echo "$env_output" | sed 's/Environment=/ /g'); do
          case "$tok" in
            HOMEPORT_DATA_DIR=*) data_dir="${tok#HOMEPORT_DATA_DIR=}" ;;
          esac
        done
        [ -d "$data_dir" ] || { echo "homeport-backup: data dir missing: $data_dir" >&2; exit 1; }

        mkdir -p "$BACKUPS_DIR"
        staging=$(mktemp -d)
        trap 'rm -rf "$staging"' EXIT
        cp -a "$CONFIG_DIR" "$staging/etc-homeport"
        mkdir -p "$staging/var-lib-homeport"
        if command -v sqlite3 >/dev/null 2>&1; then
          find "$data_dir" -maxdepth 1 -type f \\( -name '*.db' -o -name '*.sqlite*' \\) | while read -r f; do
            sqlite3 "$f" ".backup '$staging/var-lib-homeport/$(basename "$f")'"
          done
          find "$data_dir" -mindepth 1 -maxdepth 1 ! \\( -type f \\( -name '*.db' -o -name '*.sqlite*' \\) \\) -exec cp -a {} "$staging/var-lib-homeport/" \\;
        else
          cp -a "$data_dir"/. "$staging/var-lib-homeport/"
        fi

        # Atomic archive write: a visible archive is always complete (spec's "Always").
        stamp=$(date +%Y%m%d-%H%M%S)
        archive="$BACKUPS_DIR/homeport_${MACHINE}_${version}_${stamp}.tar.gz"
        tmp_archive=$(mktemp "$BACKUPS_DIR/.homeport-backup.XXXXXX")
        tar -C "$staging" -czf "$tmp_archive" .
        mv -f "$tmp_archive" "$archive"

        ls -1t "$BACKUPS_DIR"/homeport_"${MACHINE}"_*.tar.gz | tail -n +$((RETAIN + 1)) | xargs -r rm --
        """
    }
}
