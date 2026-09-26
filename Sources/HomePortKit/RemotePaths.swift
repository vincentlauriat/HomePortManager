/// Remote layout as defined by Homeport's own deploy/install.sh.
public enum RemotePaths {
    public static let app = "/opt/homeport"
    public static let config = "/etc/homeport"
    public static let data = "/var/lib/homeport"
    public static let backups = "/var/backups/homeport"
    public static let unit = "homeport.service"
    public static let versionMarker = "/opt/homeport/.hpm-version"

    /// macOS counterpart of `unit` — the LaunchAgent label from Homeport's
    /// `deploy/macos/install.sh`. There is no systemd on macOS, so `status(of:)` checks this
    /// via `launchctl` when `systemctl` isn't on the target's PATH.
    public static let launchdLabel = "com.vincentlauriat.homeport"

    // Story 3.1: the autonomous scheduled-backup job deployed by `hpm backup apply` —
    // a separate service/timer pair from `unit`, invoked by systemd, never enabled itself.
    public static let backupUnit = "homeport-backup.service"
    public static let backupTimer = "homeport-backup.timer"
    public static let backupScript = "/usr/local/bin/homeport-backup.sh"
    /// Local flock (AD-12/F1): taken by the timer's script before it runs, so it can skip
    /// its turn if a mutating hpm action is already using this rendezvous point on the Pi.
    public static let backupLock = "/run/lock/homeport-backup.lock"
}
