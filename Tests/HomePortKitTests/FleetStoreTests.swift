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
}
