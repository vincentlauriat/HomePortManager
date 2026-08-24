import XCTest
@testable import HomePortKit

/// The version range hpm consumes is the one thing in story 2.1 that executes rather than
/// merely being written down. These tests pin the whole decision table, and — because a
/// contract that disagrees with its own document is worse than no contract — check that the
/// pinned document under `docs/api/` states the same range as the code.
final class HomeportAPIContractTests: XCTestCase {

    // MARK: The decision table

    func testAVersionAtTheFloorIsCompatible() {
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "1.0.0"),
                       .compatible(SemanticVersion(1, 0, 0)))
        XCTAssertTrue(HomeportAPIContract.compatibility(with: "1.0.0").isCompatible)
    }

    func testANewerMinorIsCompatible() {
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "1.4.2"),
                       .compatible(SemanticVersion(1, 4, 2)),
                       "minor increments are additive by contract, so a v1.0 client survives them")
        XCTAssertTrue(HomeportAPIContract.compatibility(with: "1.4.2").isCompatible)
    }

    func testANewerMajorIsTooNew() {
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "2.0.0"),
                       .tooNew(SemanticVersion(2, 0, 0)))
        XCTAssertFalse(HomeportAPIContract.compatibility(with: "2.0.0").isCompatible)
    }

    func testAVersionBelowTheFloorIsTooOld() {
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "0.9.0"),
                       .tooOld(SemanticVersion(0, 9, 0)))
        XCTAssertFalse(HomeportAPIContract.compatibility(with: "0.9.0").isCompatible)
    }

    func testUnreadableVersionsAreReportedNotThrown() {
        for raw in ["", "abc", "1.2", "1.2.3.4", "v1.2.3", "1..3", "1.2.x"] {
            XCTAssertEqual(HomeportAPIContract.compatibility(with: raw), .unreadable(raw),
                           "\(raw.debugDescription) should be unreadable, never an exception")
            XCTAssertFalse(HomeportAPIContract.compatibility(with: raw).isCompatible)
        }
    }

    func testAPreReleaseDoesNotCommitToTheContract() {
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "1.1.0-rc1"),
                       .preRelease("1.1.0-rc1"),
                       "a pre-release parses but does not bind — and saying 'unreadable' would be a lie")
        XCTAssertFalse(HomeportAPIContract.compatibility(with: "1.1.0-rc1").isCompatible)
        XCTAssertEqual(HomeportAPIContract.compatibility(with: "1.1.0+build7"),
                       .preRelease("1.1.0+build7"))
        XCTAssertFalse(HomeportAPIContract.compatibility(with: "1.1.0+build7").isCompatible)
    }

    func testASuffixOnGarbageIsUnreadableNotAPreRelease() {
        for raw in ["abc-def", "-", "+", "1.2-rc1", "-1.0.0"] {
            XCTAssertEqual(HomeportAPIContract.compatibility(with: raw), .unreadable(raw),
                           "\(raw.debugDescription) has a suffix but no version in front of it")
            XCTAssertFalse(HomeportAPIContract.compatibility(with: raw).isCompatible)
        }
    }

    func testLeadingZeroesAreNotAVersion() {
        for raw in ["01.0.0", "1.00.0", "1.0.00"] {
            XCTAssertEqual(HomeportAPIContract.compatibility(with: raw), .unreadable(raw),
                           "semver forbids leading zeroes, so \(raw.debugDescription) names no release")
            XCTAssertFalse(HomeportAPIContract.compatibility(with: raw).isCompatible)
        }
        XCTAssertTrue(HomeportAPIContract.compatibility(with: "1.0.0").isCompatible,
                      "a bare zero component is still legal")
    }

    // MARK: Boundaries of the range

    func testTheCeilingIsExclusiveAtTheNextMajor() {
        XCTAssertTrue(HomeportAPIContract.compatibility(with: "1.999.999").isCompatible)
        XCTAssertFalse(HomeportAPIContract.compatibility(with: "2.0.0").isCompatible)
    }

    // MARK: Version ordering

    func testVersionsOrderByMajorThenMinorThenPatch() {
        XCTAssertTrue(SemanticVersion(1, 0, 0) < SemanticVersion(1, 0, 1))
        XCTAssertTrue(SemanticVersion(1, 0, 9) < SemanticVersion(1, 1, 0))
        XCTAssertTrue(SemanticVersion(1, 9, 9) < SemanticVersion(2, 0, 0))
        XCTAssertFalse(SemanticVersion(1, 10, 0) < SemanticVersion(1, 9, 0),
                       "components compare numerically, not as strings")
    }

    // MARK: The document and the code must agree

    func testThePinnedContractStatesTheSameRangeAsTheCode() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HomePortKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let contract = repoRoot.appendingPathComponent("docs/api/homeport-api-v1.md")

        let text = try String(contentsOf: contract, encoding: .utf8)
        // Every line stating the range must agree — checking only the first would let a second,
        // contradictory restatement through the one check that guards this.
        let rangeLines = text.split(separator: "\n").filter { $0.contains("Plage consommée par hpm") }
        XCTAssertFalse(rangeLines.isEmpty,
                       "the pinned contract must state the consumed range in a line naming it")

        for line in rangeLines {
            XCTAssertTrue(line.contains(">= \(HomeportAPIContract.minimumSupported)"),
                          "document floor disagrees with the code: \(line)")
            XCTAssertTrue(line.contains("< \(HomeportAPIContract.firstUnsupported)"),
                          "document ceiling disagrees with the code: \(line)")
        }
        XCTAssertEqual(HomeportAPIContract.supportedRange,
                       ">= \(HomeportAPIContract.minimumSupported) < \(HomeportAPIContract.firstUnsupported)",
                       "the displayed range is derived from the same constants it describes")
    }
}
