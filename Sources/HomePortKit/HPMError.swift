import Foundation

public struct HPMError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public typealias Reporter = (String) -> Void

public func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
