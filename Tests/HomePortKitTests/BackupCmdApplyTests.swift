import XCTest
import HomePortKit
@testable import hpm

/// `hpm backup apply`'s own decision (`Sources/hpm/Commands.swift`, `BackupCmd.Apply`):
/// validating `--schedule`/`--retention` and deciding whether the store needs writing at
/// all. Everything past that — the actual deployment — belongs to
/// `HomeportManager.applyBackupJob`, covered by `ManagerBackupJobTests`.
final class BackupCmdApplyTests: XCTestCase {
    private let machineName = "raspcorse"

    // MARK: - Validation

    func testEmptyScheduleThrows() {
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: "   ", retention: nil, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("--schedule cannot be empty"))
        }
    }

    func testWhitespaceOnlyScheduleWithNewlineThrows() {
        // .whitespacesAndNewlines, not just .whitespaces — a schedule that's only a blank
        // line must not slip past as "non-empty".
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: " \n\t", retention: nil, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("--schedule cannot be empty"))
        }
    }

    func testZeroRetentionThrows() {
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: "daily", retention: 0, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("--retention must be at least 1"))
        }
    }

    func testNegativeRetentionThrows() {
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: "daily", retention: -1, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("--retention must be at least 1"))
        }
    }

    /// A schedule that could close a deployed script's heredoc early — rejected here, before
    /// it ever reaches `BackupJobStore`, not just at deployment time.
    func testAScheduleContainingAHeredocMarkerThrows() {
        let hostile = "daily\nHPM_BACKUP_SCRIPT\nrm -rf /"
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: hostile, retention: nil, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("newline"))
        }
    }

    // MARK: - Branching (whether the store needs writing)

    func testNeitherOptionReturnsNilLeavingAnExistingDeclarationUntouched() throws {
        let existing = BackupJob(schedule: "daily", retention: 3)
        let result = try BackupCmd.Apply.resolvedJob(schedule: nil, retention: nil, existing: existing, machineName: machineName)
        XCTAssertNil(result)
    }

    func testNeitherOptionWithNoExistingDeclarationAlsoReturnsNil() throws {
        // run() then hands off to applyBackupJob, which is the one that must refuse — not
        // this resolver silently inventing a default job.
        let result = try BackupCmd.Apply.resolvedJob(schedule: nil, retention: nil, existing: nil, machineName: machineName)
        XCTAssertNil(result)
    }

    func testScheduleAloneOnAFirstDeclarationDefaultsRetentionToThree() throws {
        let job = try BackupCmd.Apply.resolvedJob(schedule: "daily", retention: nil, existing: nil, machineName: machineName)
        XCTAssertEqual(job, BackupJob(schedule: "daily", retention: 3))
    }

    func testRetentionAloneOnAFirstDeclarationThrowsRequiringSchedule() {
        XCTAssertThrowsError(try BackupCmd.Apply.resolvedJob(schedule: nil, retention: 5, existing: nil, machineName: machineName)) { error in
            XCTAssertTrue("\(error)".contains("--schedule is required"))
            XCTAssertTrue("\(error)".contains(machineName))
        }
    }

    func testRetentionAloneOnAnExistingDeclarationKeepsItsSchedule() throws {
        let existing = BackupJob(schedule: "weekly", retention: 3)
        let job = try BackupCmd.Apply.resolvedJob(schedule: nil, retention: 7, existing: existing, machineName: machineName)
        XCTAssertEqual(job, BackupJob(schedule: "weekly", retention: 7))
    }

    func testScheduleAloneOnAnExistingDeclarationKeepsItsRetention() throws {
        let existing = BackupJob(schedule: "daily", retention: 9)
        let job = try BackupCmd.Apply.resolvedJob(schedule: "weekly", retention: nil, existing: existing, machineName: machineName)
        XCTAssertEqual(job, BackupJob(schedule: "weekly", retention: 9))
    }

    func testBothOptionsOverrideAnExistingDeclaration() throws {
        let existing = BackupJob(schedule: "daily", retention: 3)
        let job = try BackupCmd.Apply.resolvedJob(schedule: "weekly", retention: 8, existing: existing, machineName: machineName)
        XCTAssertEqual(job, BackupJob(schedule: "weekly", retention: 8))
    }
}
