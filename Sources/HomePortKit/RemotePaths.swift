/// Remote layout as defined by Homeport's own deploy/install.sh.
public enum RemotePaths {
    public static let app = "/opt/homeport"
    public static let config = "/etc/homeport"
    public static let data = "/var/lib/homeport"
    public static let backups = "/var/backups/homeport"
    public static let unit = "homeport.service"
    public static let versionMarker = "/opt/homeport/.hpm-version"
}
