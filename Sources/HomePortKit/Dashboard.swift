import Foundation

/// The address of a machine's Homeport web dashboard, derived from the identity declared
/// in fleet.yaml — the same `ssh` target every channel reads, and the same `port` the
/// healthz check probes. Host is what follows the last `@` (a bare `ssh` is already a
/// host); scheme is plain http on the tailnet, path is the root.
///
/// Pure and total: an empty target, a dangling `user@`, a port outside 1…65535 (the
/// `URLComponents.port` setter raises on a negative one) or a host outside the DNS
/// alphabet yield `nil`, never a crash. The host is vetted against a positive allowlist
/// — letters, digits, `-` and `.`, what a MagicDNS name or a hostname is made of —
/// rather than against `urlHostAllowed`, which admits `:`, `[`, `]` and every
/// sub-delimiter (`& ; , + = …`): `URLComponents` would carry those through into a
/// syntactically valid address that names no machine (`host:port` suffixes and IPv6
/// literals among them, neither of which is a fleet.yaml identity).
/// L'hôte joignable d'une machine, dérivé de sa cible SSH : le préfixe `user@` retiré
/// (`vincent@raspyellow` → `raspyellow`), puis validé contre une allowlist de caractères.
/// Partagé par les deux clients HTTP du dépôt : une seule dérivation, une seule allowlist.
public func apiHost(for machine: Machine) -> String? {
    let target = machine.ssh
    let host: String
    if let at = target.lastIndex(of: "@") {
        host = String(target[target.index(after: at)...])
    } else {
        host = target
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"
                               + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
    guard !host.isEmpty, host.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
    return host
}

public func dashboardURL(for machine: Machine) -> URL? {
    guard (1...65535).contains(machine.port), let host = apiHost(for: machine) else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = machine.port
    components.path = "/"
    return components.url
}
