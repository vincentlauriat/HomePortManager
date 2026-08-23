import XCTest
@testable import HomePortKit

final class MachineBlockTests: XCTestCase {
    func testRotationExcludesNavyAndKeepsDocumentedOrder() {
        XCTAssertEqual(MachineBlock.rotation, [.lime, .cream, .lilac, .mint, .pink, .coral])
        XCTAssertEqual(MachineBlock.rotation.count, 6)
        XCTAssertFalse(MachineBlock.rotation.contains(.navy),
                       "navy is a dark editorial surface, never a machine identity")
    }

    func testFirstAssignmentTakesLime() {
        XCTAssertEqual(assignBlocks(to: ["whatever"], existing: [:]), ["whatever": .lime])
    }

    func testDocumentedOrderForTheCurrentFleet() {
        XCTAssertEqual(assignBlocks(to: ["raspcorse", "raspyellow"], existing: [:]),
                       ["raspcorse": .lime, "raspyellow": .cream])
    }

    func testRemovedMachineKeepsItsBlockReserved() {
        // B is gone from fleet.yaml but stays in the store: C must not inherit cream.
        let store: [String: MachineBlock] = ["A": .lime, "B": .cream]
        let result = assignBlocks(to: ["A", "C"], existing: store)
        XCTAssertEqual(result["A"], .lime)
        XCTAssertEqual(result["B"], .cream)
        XCTAssertEqual(result["C"], .lilac)
    }

    func testBeyondSixMachinesTheRotationCycles() {
        let names = (1...7).map { "m\($0)" }
        let result = assignBlocks(to: names, existing: [:])
        XCTAssertEqual(names.map { result[$0] },
                       [.lime, .cream, .lilac, .mint, .pink, .coral, .lime])
    }

    func testAssignmentIsStableAcrossRepeatedCalls() {
        let first = assignBlocks(to: ["a", "b", "c"], existing: [:])
        let second = assignBlocks(to: ["c", "b", "a"], existing: first)
        XCTAssertEqual(first, second, "an existing assignment is never rewritten")

        let grown = assignBlocks(to: ["a", "b", "c", "d"], existing: second)
        XCTAssertEqual(grown["a"], first["a"])
        XCTAssertEqual(grown["b"], first["b"])
        XCTAssertEqual(grown["c"], first["c"])
        XCTAssertEqual(grown["d"], .mint)
    }
}
