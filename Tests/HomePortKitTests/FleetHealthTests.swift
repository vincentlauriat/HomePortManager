import XCTest
@testable import HomePortKit

final class FleetHealthTests: XCTestCase {
    private func status(name: String = "m", reachable: Bool = true, version: String = "v0.5.0",
                        active: Bool = true, healthz: Bool = true, disk: Int? = 40) -> MachineStatus {
        MachineStatus(name: name, reachable: reachable, installedVersion: version,
                      serviceActive: active, healthzOK: healthz, lastBackup: nil,
                      uptimeSeconds: 100, diskUsedPercent: disk, sshLatencyMs: 100)
    }

    func testAllGreen() {
        XCTAssertEqual(FleetHealth.aggregate([status(), status(name: "b")], latest: "v0.5.0"), .allGreen)
    }

    func testEmptyIsUnknown() {
        XCTAssertEqual(FleetHealth.aggregate([], latest: nil), .unknown)
    }

    func testWarningOnAnyProblem() {
        XCTAssertEqual(FleetHealth.aggregate([status(), status(healthz: false)], latest: "v0.5.0"), .warning)
    }

    func testWarnings() {
        XCTAssertEqual(machineWarnings(status(), latest: "v0.5.0"), [])
        XCTAssertEqual(machineWarnings(status(reachable: false), latest: nil), ["unreachable"])
        XCTAssertEqual(machineWarnings(status(version: "v0.4.0"), latest: "v0.5.0"),
                       ["update available (v0.5.0)"])
        XCTAssertEqual(machineWarnings(status(version: "unknown"), latest: "v0.5.0"), [],
                       "unknown version must not claim an update is available")
        XCTAssertEqual(machineWarnings(status(disk: 93), latest: "v0.5.0"), ["disk 93% full"])
        XCTAssertEqual(machineWarnings(status(active: false, healthz: false), latest: "v0.5.0"),
                       ["service inactive", "healthz failing"])
    }

    func testTransitions() {
        // First observation: silent.
        XCTAssertEqual(transitions(old: nil, new: status()), [])
        // No change: silent.
        XCTAssertEqual(transitions(old: status(), new: status()), [])
        // Goes down / comes back.
        XCTAssertEqual(transitions(old: status(), new: status(healthz: false)).count, 1)
        XCTAssertTrue(transitions(old: status(), new: status(healthz: false))[0].contains("DOWN"))
        XCTAssertEqual(transitions(old: status(healthz: false), new: status()), ["m is back up"])
        // Stays red: silent.
        XCTAssertEqual(transitions(old: status(healthz: false), new: status(healthz: false)), [])
        // Reachability transitions.
        XCTAssertEqual(transitions(old: status(), new: status(reachable: false)), ["m is unreachable"])
        XCTAssertEqual(transitions(old: status(reachable: false), new: status()), ["m is reachable again"])
    }

    func testBackupAge() {
        XCTAssertEqual(backupAge(nil), "never")
        XCTAssertEqual(backupAge("garbage"), "never")
        let formatter = HomeportManager.timestampFormatter
        let twoHoursAgo = formatter.string(from: Date(timeIntervalSinceNow: -7200))
        XCTAssertEqual(backupAge("homeport_m_v0.5.0_\(twoHoursAgo).tar.gz"), "2h ago")
        let threeDaysAgo = formatter.string(from: Date(timeIntervalSinceNow: -3 * 86_400 - 60))
        XCTAssertEqual(backupAge("homeport_m_v0.5.0_\(threeDaysAgo).tar.gz"), "3d ago")
    }
}
