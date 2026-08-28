/// The range of Homeport API contract versions hpm consumes, and the decision that
/// compares a server's announced version against it.
///
/// The contract itself is `docs/api/homeport-api-v1.md`; this file is the executable half
/// of it, and the two must state the same range. Compatibility is answered with a value,
/// never a thrown error: a server too old to serve the API is an ordinary state the UI
/// displays, not a failure.

/// A strict `major.minor.patch` version. Parsing rejects anything else — no `v` prefix,
/// no missing component, no pre-release suffix — because the contract only binds releases.
public struct SemanticVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Returns nil when `raw` is not exactly three non-negative integers separated by dots.
    public init?(parsing raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `Int(...)` alone would accept a leading "+" or "-"; the contract wants digits only.
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return nil }
            // Semver forbids leading zeros, so "01.0.0" is not a version that names a release.
            guard part == "0" || !part.hasPrefix("0") else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// The verdict on a server's announced contract version. Every case carries what it needs
/// to be shown to the user without re-deriving anything.
public enum ContractCompatibility: Equatable, Sendable {
    case compatible(SemanticVersion)
    /// Older than the floor hpm supports — the machine needs an update.
    case tooOld(SemanticVersion)
    /// A major beyond what this client was written against — hpm needs an update.
    case tooNew(SemanticVersion)
    /// A pre-release. It parses, but a pre-release does not commit to the contract.
    case preRelease(String)
    /// Not a version at all: empty, non-numeric, or the wrong number of components.
    case unreadable(String)

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    /// The version met, formatted for display (§8, row 2). One place rather than two: the
    /// Events tab and `hpm events` both name the version a machine announced, and AD-13
    /// forbids the two ever describing it differently.
    public var describedVersion: String {
        switch self {
        case .compatible(let version), .tooOld(let version), .tooNew(let version):
            return version.description
        case .preRelease(let raw), .unreadable(let raw):
            return raw.isEmpty ? "(none)" : raw
        }
    }
}

public enum HomeportAPIContract {
    /// Oldest contract version hpm can consume.
    public static let minimumSupported = SemanticVersion(1, 0, 0)

    /// First version hpm cannot consume. A major bump is by definition breaking, so the
    /// ceiling is exclusive and sits at the next major.
    public static let firstUnsupported = SemanticVersion(2, 0, 0)

    /// The consumed range, for display and for the pinned document to be checked against.
    public static let supportedRange = ">= 1.0.0 < 2.0.0"

    /// Compares the `contract` field of a `capabilities` response against the consumed range.
    /// Never throws: an incompatible server is a state to display, not an error to handle.
    public static func compatibility(with raw: String) -> ContractCompatibility {
        // A pre-release parses as a version followed by a suffix; catch it before parsing so
        // "1.1.0-rc1" is reported as what it is rather than as unreadable. The prefix must still
        // be a version, or "abc-def" would be announced to the user as a pre-release.
        if let suffix = raw.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            return SemanticVersion(parsing: String(raw[raw.startIndex..<suffix])) != nil
                ? .preRelease(raw) : .unreadable(raw)
        }
        guard let version = SemanticVersion(parsing: raw) else { return .unreadable(raw) }
        if version < minimumSupported { return .tooOld(version) }
        if version >= firstUnsupported { return .tooNew(version) }
        return .compatible(version)
    }
}
