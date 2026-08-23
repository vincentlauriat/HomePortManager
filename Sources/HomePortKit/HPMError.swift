import Foundation

public struct HPMError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The refusal `acquireLock` throws on a live in-TTL holder. Its own type so the journal
/// seam can tell contention — rethrown to the user untouched — from an infrastructure
/// failure of the lock machinery, which degrades like the journal: warn and run unlocked,
/// never refuse an action because the base is broken (the 1.2 doctrine).
public struct LockContentionError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public typealias Reporter = (String) -> Void

public func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
