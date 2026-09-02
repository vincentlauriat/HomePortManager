import Foundation
import Yams

public struct Machine: Codable, Equatable {
    public var name: String
    public var ssh: String
    public var port: Int
    public var notes: String?
    /// Le port de HomePortExploit sur cette machine. `nil` — la clé absente du YAML —
    /// signifie que le service n'y est pas déployé : un état neutre, jamais une panne.
    public var exploitPort: Int?

    public init(name: String, ssh: String, port: Int = 80, notes: String? = nil, exploitPort: Int? = nil) {
        self.name = name
        self.ssh = ssh
        self.port = port
        self.notes = notes
        self.exploitPort = exploitPort
    }
}

public struct Fleet: Codable, Equatable {
    public var machines: [Machine]
    public init(machines: [Machine] = []) { self.machines = machines }
}

public final class FleetStore {
    public static let defaultPath = "~/.config/hpm/fleet.yaml"
    private let path: String

    public init(path: String = FleetStore.defaultPath) {
        self.path = expandPath(path)
    }

    public func load() throws -> Fleet {
        guard FileManager.default.fileExists(atPath: path) else { return Fleet() }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        do {
            return try YAMLDecoder().decode(Fleet.self, from: contents)
        } catch {
            throw HPMError("cannot parse \(path): \(error)")
        }
    }

    public func save(_ fleet: Fleet) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let yaml = try YAMLEncoder().encode(fleet)
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func add(_ machine: Machine) throws {
        var fleet = try load()
        guard !fleet.machines.contains(where: { $0.name == machine.name }) else {
            throw HPMError("machine '\(machine.name)' already exists in \(path)")
        }
        fleet.machines.append(machine)
        try save(fleet)
    }

    @discardableResult
    public func remove(named name: String) throws -> Bool {
        var fleet = try load()
        let before = fleet.machines.count
        fleet.machines.removeAll { $0.name == name }
        guard fleet.machines.count != before else { return false }
        try save(fleet)
        return true
    }

    public func machine(named name: String) throws -> Machine {
        guard let machine = try load().machines.first(where: { $0.name == name }) else {
            throw HPMError("unknown machine '\(name)' — declare it with: hpm machine add \(name) --ssh <host>")
        }
        return machine
    }
}
