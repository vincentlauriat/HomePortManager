import XCTest
@testable import HomePortKit

final class FleetRowTests: XCTestCase {
    private let blocks: [String: MachineBlock] = ["raspcorse": .lime, "raspyellow": .cream]
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func machine(_ name: String) -> Machine { Machine(name: name, ssh: "pi@\(name)") }

    /// The name `backup(on:)` actually writes: `homeport_<machine>_<version>_<stamp>.tar.gz`.
    /// Built from the formatter and a known instant, so the assertion compares against that
    /// instant and not against a round-trip of the same string.
    private func archive(_ name: String, at date: Date) -> String {
        "homeport_\(name)_v0.5.0_\(HomeportManager.timestampFormatter.string(from: date)).tar.gz"
    }

    private func status(_ name: String, reachable: Bool = true, version: String = "v0.5.0",
                        active: Bool = true, healthz: Bool = true, backup: String? = nil,
                        disk: Int? = 40) -> MachineStatus {
        MachineStatus(name: name, reachable: reachable, installedVersion: version,
                      serviceActive: active, healthzOK: healthz, lastBackup: backup,
                      uptimeSeconds: 3_600, diskUsedPercent: disk, sshLatencyMs: 12)
    }

    // MARK: Matrix

    func testPopulatedFleet() {
        // The formatter has a one-second resolution: the reference instant is whole-second.
        let backedUpAt = Date(timeIntervalSince1970: 1_699_999_000)
        let backup = archive("raspcorse", at: backedUpAt)
        let rows = fleetRows(machines: [machine("raspcorse"), machine("raspyellow")],
                             statuses: ["raspcorse": status("raspcorse", backup: backup),
                                        "raspyellow": status("raspyellow", disk: 12)],
                             lastSeen: ["raspcorse": now, "raspyellow": now],
                             latest: "v0.5.0", blocks: blocks, now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.name), ["raspcorse", "raspyellow"])
        XCTAssertEqual(rows[0].block, .lime)
        XCTAssertEqual(rows[1].block, .cream)
        XCTAssertEqual(rows.map(\.severity), [.ok, .ok])
        XCTAssertEqual(rows[0].version, "v0.5.0")
        XCTAssertEqual(rows[1].diskUsedPercent, 12)
        XCTAssertEqual(rows[0].lastBackupAt, backedUpAt)
        XCTAssertNil(rows[1].lastBackupAt, "no archive means no date, not a wrong one")
        XCTAssertEqual(rows[0].lastSeen, now)
    }

    func testEmptyFleetProducesNoRows() {
        XCTAssertTrue(fleetRows(machines: Fleet().machines, statuses: [:],
                                latest: nil, blocks: [:]).isEmpty)
    }

    func testUnreachableFallsBackOnLastKnownData() {
        let seen = now.addingTimeInterval(-600)
        let rows = fleetRows(machines: [machine("raspcorse")],
                             statuses: ["raspcorse": status("raspcorse", reachable: false,
                                                            version: "-", active: false,
                                                            healthz: false, disk: nil)],
                             lastReachable: ["raspcorse": status("raspcorse", version: "v0.4.0",
                                                                 disk: 61)],
                             lastSeen: ["raspcorse": seen],
                             latest: "v0.5.0", blocks: blocks, now: now)
        XCTAssertEqual(rows[0].severity, .critical)
        XCTAssertEqual(rows[0].version, "v0.4.0", "the last known version stays on screen")
        XCTAssertEqual(rows[0].diskUsedPercent, 61)
        XCTAssertEqual(rows[0].lastSeen, seen)
        XCTAssertEqual(rows[0].issues, [.unreachable],
                       "the warning line must survive: unreachable is an issue like any other")
    }

    func testNeverReachedHasUnknownValues() {
        let rows = fleetRows(machines: [machine("raspcorse")],
                             statuses: ["raspcorse": status("raspcorse", reachable: false,
                                                            version: "-", active: false,
                                                            healthz: false, disk: nil)],
                             latest: nil, blocks: blocks, now: now)
        XCTAssertEqual(rows[0].severity, .critical)
        XCTAssertNil(rows[0].version)
        XCTAssertNil(rows[0].diskUsedPercent)
        XCTAssertNil(rows[0].lastBackupAt)
        XCTAssertNil(rows[0].lastSeen)
    }

    func testWarningSeverityForAHealthyMachineNeedingAttention() {
        let rows = fleetRows(machines: [machine("raspcorse")],
                             statuses: ["raspcorse": status("raspcorse", disk: 95)],
                             latest: "v0.5.0", blocks: blocks, now: now)
        XCTAssertEqual(rows[0].severity, .warning)
        XCTAssertEqual(rows[0].issues, [.diskAlmostFull(95)])
    }

    // MARK: Severity boundaries

    func testHardFailuresAreCriticalNotWarning() {
        XCTAssertEqual(severity(of: status("m", healthz: false), latest: "v0.5.0"), .critical)
        XCTAssertEqual(severity(of: status("m", active: false), latest: "v0.5.0"), .critical)
        XCTAssertEqual(severity(of: nil, latest: nil), .critical,
                       "not polled yet is unknown, not fine")
        XCTAssertEqual(severity(of: status("m", version: "v0.4.0"), latest: "v0.5.0"), .warning)
        XCTAssertEqual(severity(of: status("m"), latest: "v0.5.0"), .ok)
    }

    func testUnknownMachineFallsBackOnTheFirstBlockRatherThanCrashing() {
        let rows = fleetRows(machines: [machine("brand-new")], statuses: [:],
                             latest: nil, blocks: [:], now: now)
        XCTAssertEqual(rows[0].block, .lime)
    }

    // MARK: Font fallback

    func testFontFamilyResolvesToTheFirstAvailableFallback() {
        XCTAssertEqual(resolveFontFamily(preferred: FontStack.sans) { _ in true }, "Inter",
                       "the head of the stack wins whenever it is installed")
        XCTAssertEqual(resolveFontFamily(preferred: FontStack.sans) { $0 != "Inter" },
                       "SF Pro Display",
                       "PingFang SC is skipped: it is in the stack for CJK coverage, not as a face")
        XCTAssertEqual(resolveFontFamily(preferred: FontStack.mono) { $0 == "Menlo" }, "Menlo")
        XCTAssertNil(resolveFontFamily(preferred: FontStack.mono) { _ in false })
    }

    /// The mono stack must never resolve to a proportional face: the data table aligns
    /// figures on it, and PingFang SC is not fixed-width.
    func testTheMonoStackNeverResolvesToTheCoverageFace() {
        XCTAssertEqual(resolveFontFamily(preferred: FontStack.mono) { $0 != "JetBrains Mono" },
                       "SF Mono")
        XCTAssertEqual(resolveFontFamily(preferred: FontStack.mono) {
            $0 == "PingFang SC" || $0 == "Menlo"
        }, "Menlo", "with only the coverage face and Menlo installed, Menlo is the answer")
        for stack in [FontStack.sans, FontStack.mono] {
            XCTAssertNotEqual(resolveFontFamily(preferred: stack) { _ in true },
                              "PingFang SC")
        }
    }
}
