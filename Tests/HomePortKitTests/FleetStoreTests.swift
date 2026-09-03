import XCTest
@testable import HomePortKit

final class FleetStoreTests: XCTestCase {
    private var path: String!
    private var store: FleetStore!

    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "hpm-tests-\(UUID().uuidString)"
        path = dir + "/fleet.yaml"
        store = FleetStore(path: path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        super.tearDown()
    }

    func testLoadMissingFileReturnsEmptyFleet() throws {
        XCTAssertEqual(try store.load(), Fleet())
    }

    func testAddAndLoadRoundTrip() throws {
        let machine = Machine(name: "raspcorse", ssh: "raspcorse", port: 80, notes: "Pi 5")
        try store.add(machine)
        XCTAssertEqual(try store.load().machines, [machine])
    }

    func testAddDuplicateThrows() throws {
        try store.add(Machine(name: "a", ssh: "a"))
        XCTAssertThrowsError(try store.add(Machine(name: "a", ssh: "other")))
    }

    func testRemove() throws {
        try store.add(Machine(name: "a", ssh: "a"))
        XCTAssertTrue(try store.remove(named: "a"))
        XCTAssertFalse(try store.remove(named: "a"))
        XCTAssertEqual(try store.load(), Fleet())
    }

    func testMachineNamedThrowsWithHint() throws {
        XCTAssertThrowsError(try store.machine(named: "ghost")) { error in
            XCTAssertTrue("\(error)".contains("hpm machine add"))
        }
    }

    func testDefaultPort() {
        XCTAssertEqual(Machine(name: "x", ssh: "x").port, 80)
    }

    func testMachineWithoutExploitPortRoundTripsWithoutNullKey() throws {
        let path = NSTemporaryDirectory() + "fleet-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FleetStore(path: path)
        try store.save(Fleet(machines: [Machine(name: "raspyellow", ssh: "vincent@raspyellow", port: 80)]))

        let written = try String(contentsOfFile: path, encoding: .utf8)
        // Un optionnel absent ne doit pas gagner de clé : le fichier de Vincent est écrit à la main.
        XCTAssertFalse(written.contains("exploitPort"))
        XCTAssertNil(try store.load().machines[0].exploitPort)
    }

    func testExploitPortSurvivesRoundTrip() throws {
        let path = NSTemporaryDirectory() + "fleet-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = FleetStore(path: path)
        try store.save(Fleet(machines: [Machine(name: "raspcorse", ssh: "raspcorse", port: 80, exploitPort: 8081)]))
        XCTAssertEqual(try store.load().machines[0].exploitPort, 8081)
    }
}
