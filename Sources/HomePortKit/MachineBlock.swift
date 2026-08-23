import Foundation

/// The pastel identity of a machine: assigned once when the machine first appears,
/// never reassigned. Carries its own hex so the kit stays free of SwiftUI — the app
/// translates a case into a `Color` in `Theme`.
public enum MachineBlock: String, CaseIterable, Codable, Equatable, Sendable {
    case lime
    case cream
    case lilac
    case mint
    case pink
    case coral
    /// Out of rotation: a dark editorial surface, never a machine identity.
    case navy

    public var hex: String {
        switch self {
        case .lime:  return "#dceeb1"
        case .cream: return "#f4ecd6"
        case .lilac: return "#c5b0f4"
        case .mint:  return "#c8e6cd"
        case .pink:  return "#efd4d4"
        case .coral: return "#f3c9b6"
        case .navy:  return "#1f1d3d"
        }
    }

    /// The documented assignment order. Explicitly enumerated rather than derived from
    /// `allCases`, so navy can never leak in and shift the order.
    public static let rotation: [MachineBlock] = [.lime, .cream, .lilac, .mint, .pink, .coral]
}

/// Merges `names` into `existing`, assigning a block to each name that has none.
///
/// Invariants: an existing entry is never rewritten, and the index of the next block is
/// the *size of the store*, not the size of the fleet — so a machine removed from
/// `fleet.yaml` keeps its block reserved and no colour is ever recycled. Beyond six
/// machines the rotation cycles (index modulo 6). The caller must therefore keep the
/// store append-only; see `MachineBlockStore`.
public func assignBlocks(to names: [String],
                         existing: [String: MachineBlock]) -> [String: MachineBlock] {
    var blocks = existing
    var next = existing.count
    for name in names where blocks[name] == nil {
        blocks[name] = MachineBlock.rotation[next % MachineBlock.rotation.count]
        next += 1
    }
    return blocks
}
