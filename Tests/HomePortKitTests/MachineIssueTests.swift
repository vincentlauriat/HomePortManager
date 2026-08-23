import XCTest
@testable import HomePortKit

/// The single health verdict every surface reads. These tests pin the rules that used to be
/// re-implemented per view — the order of the issues, the two thresholds, and the fact that
/// a severity is never decided anywhere but from an issue list.
final class MachineIssueTests: XCTestCase {
    private func status(_ name: String = "m", reachable: Bool = true, version: String = "v0.5.0",
                        active: Bool = true, healthz: Bool = true,
                        disk: Int? = 40) -> MachineStatus {
        MachineStatus(name: name, reachable: reachable, installedVersion: version,
                      serviceActive: active, healthzOK: healthz, lastBackup: nil,
                      uptimeSeconds: 3_600, diskUsedPercent: disk, sshLatencyMs: 12)
    }

    // MARK: Order

    func testIssuesComeInTheDocumentedOrder() {
        let issues = machineIssues(status(version: "v0.4.0", active: false, healthz: false,
                                          disk: 97),
                                   latest: "v0.5.0")
        XCTAssertEqual(issues, [.serviceInactive, .healthzFailing,
                                .updateAvailable("v0.5.0"), .diskAlmostFull(97)],
                       "the order mirrors machineWarnings so CLI and interface never diverge")
    }

    func testAHealthyMachineHasNoIssue() {
        XCTAssertEqual(machineIssues(status(), latest: "v0.5.0"), [])
    }

    // MARK: Exclusive facts

    func testNotPolledIsItsOwnSingleFact() {
        XCTAssertEqual(machineIssues(nil, latest: "v0.5.0"), [.notPolled])
        XCTAssertEqual(severity(of: nil, latest: "v0.5.0"), .critical,
                       "never observed is unknown, not fine")
    }

    func testUnreachableSaysNothingElse() {
        let issues = machineIssues(status(reachable: false, version: "-", active: false,
                                          healthz: false, disk: nil),
                                   latest: "v0.5.0")
        XCTAssertEqual(issues, [.unreachable],
                       "a machine that did not answer cannot also report a dead service")
        XCTAssertEqual(severity(of: issues), .critical)
    }

    // MARK: Thresholds

    func testDiskThresholdIsNinetyInclusive() {
        XCTAssertEqual(machineIssues(status(disk: 90), latest: nil), [.diskAlmostFull(90)])
        XCTAssertEqual(machineIssues(status(disk: 89), latest: nil), [],
                       "89% is not almost full: the threshold is >= 90")
    }

    func testAnUnknownVersionNeverClaimsAnUpdate() {
        XCTAssertEqual(machineIssues(status(version: "unknown"), latest: "v0.5.0"), [],
                       #""unknown" marks an unreadable version marker, not a version"#)
        XCTAssertEqual(machineIssues(status(version: "v0.4.0"), latest: nil), [],
                       "no known release means nothing to update to")
        XCTAssertEqual(machineIssues(status(version: "v0.4.0"), latest: "v0.5.0"),
                       [.updateAvailable("v0.5.0")])
    }

    // MARK: Severity

    func testOnlyHardFailuresAreCritical() {
        XCTAssertTrue(MachineIssue.notPolled.isCritical)
        XCTAssertTrue(MachineIssue.unreachable.isCritical)
        XCTAssertTrue(MachineIssue.serviceInactive.isCritical)
        XCTAssertTrue(MachineIssue.healthzFailing.isCritical)
        XCTAssertFalse(MachineIssue.diskAlmostFull(99).isCritical)
        XCTAssertFalse(MachineIssue.updateAvailable("v9").isCritical)
    }

    func testACriticalIssueOutweighsAWarningOne() {
        XCTAssertEqual(severity(of: [.diskAlmostFull(95), .healthzFailing]), .critical)
        XCTAssertEqual(severity(of: [.updateAvailable("v1"), .diskAlmostFull(95)]), .warning)
        XCTAssertEqual(severity(of: []), .ok)
    }

    /// The menu bar dot and the control center's pill are two renderings of one verdict:
    /// both take `severity(of:latest:)` and hand it to `Theme.color(of:)`. They used to
    /// disagree — a machine with no observation read grey in the menu bar and critical in
    /// the pill. Locking the verdict here is what keeps them from drifting apart again.
    func testEverySurfaceReadsTheSameVerdict() {
        let cases: [MachineStatus?] = [
            nil,
            status(reachable: false, version: "-", active: false, healthz: false, disk: nil),
            status(active: false),
            status(healthz: false),
            status(version: "v0.4.0"),
            status(disk: 95),
            status(),
        ]
        let expected: [FleetRow.Severity] = [.critical, .critical, .critical, .critical,
                                             .warning, .warning, .ok]
        for (candidate, verdict) in zip(cases, expected) {
            XCTAssertEqual(severity(of: candidate, latest: "v0.5.0"), verdict)
            XCTAssertEqual(severity(of: machineIssues(candidate, latest: "v0.5.0")), verdict,
                           "the issue list and the status must yield one and the same severity")
        }
    }

    /// The third reading: the menu bar *icon*. It used to be built from a `compactMap` that
    /// dropped unobserved machines, so a fleet of one green machine and one never-polled one
    /// showed a green check while the fleet table showed CRITICAL for the second. The pill,
    /// the dot and the icon now weigh an unobserved machine identically.
    func testAnUnpolledMachineWeighsTheSameOnAllThreeSurfaces() {
        let green = status("polled")
        let fleet = [Machine(name: "polled", ssh: "pi@polled"),
                     Machine(name: "silent", ssh: "pi@silent")]
        let rows = fleetRows(machines: fleet, statuses: ["polled": green],
                             latest: "v0.5.0", blocks: [:])

        // 1. the pill, through the row severity
        XCTAssertEqual(rows.map(\.severity), [.ok, .critical])
        // 2. the menu bar dot, through the same function the dot colours
        XCTAssertEqual(severity(of: nil, latest: "v0.5.0"), .critical)
        // 3. the menu bar icon
        XCTAssertEqual(FleetHealth.aggregate([green, nil], latest: "v0.5.0"), .warning,
                       "one machine never polled: the icon cannot claim the fleet is green")
        XCTAssertEqual(FleetHealth.aggregate([green], latest: "v0.5.0"), .allGreen)
        XCTAssertEqual(FleetHealth.aggregate([nil, nil], latest: "v0.5.0"), .warning,
                       "a fleet nobody has answered for yet is not a green fleet")
        XCTAssertEqual(FleetHealth.aggregate([], latest: "v0.5.0"), .unknown,
                       "unknown is for having nothing to judge, not for not having judged yet")
    }

    /// The kit's own prose stays byte-for-byte what the CLI prints: this story consumes
    /// `machineWarnings`, it does not reshape it. The two agree on *whether* something is
    /// wrong; only the wording differs.
    func testTheCLIAndTheInterfaceAgreeOnWhatIsWrong() {
        let cases: [MachineStatus] = [
            status(reachable: false, version: "-", active: false, healthz: false, disk: nil),
            status(active: false),
            status(healthz: false),
            status(version: "v0.4.0"),
            status(disk: 95),
            status(),
        ]
        for candidate in cases {
            XCTAssertEqual(machineIssues(candidate, latest: "v0.5.0").count,
                           machineWarnings(candidate, latest: "v0.5.0").count,
                           "same rule set, same number of findings for \(candidate.name)")
        }
    }
}
