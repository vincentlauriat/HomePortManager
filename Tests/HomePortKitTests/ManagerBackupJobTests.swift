import XCTest
@testable import HomePortKit

final class ManagerBackupJobTests: XCTestCase {
    private let machine = Machine(name: "raspcorse", ssh: "raspcorse")

    private func declare(_ job: BackupJob, jobsRoot: String, machineName: String = "raspcorse") throws {
        try BackupJobStore(root: jobsRoot).save(job, for: machineName)
    }

    // MARK: - Preconditions

    func testNoJobDeclaredThrowsAndTouchesNothing() throws {
        let mock = MockProcessRunner()
        let manager = makeTestManager(mock: mock)
        XCTAssertThrowsError(try manager.applyBackupJob(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("no backup job declared"))
            XCTAssertTrue("\(error)".contains("hpm backup apply raspcorse --schedule"))
        }
        // Nothing declared means nothing to deploy: not even the sudo probe should run.
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testSudoPreconditionFailureRefusesBeforeAnyDeployment() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "sudo -n true", exitCode: 1)
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily"), jobsRoot: jobsRoot)

        XCTAssertThrowsError(try manager.applyBackupJob(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("passwordless sudo"))
        }
        // Exactly the probe ran — no unit/script content was ever written.
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertTrue(mock.calls[0].line.contains("sudo -n true"))
        XCTAssertFalse(mock.calls.contains { ($0.stdin ?? "").contains("daemon-reload") })
    }

    // MARK: - Deployment content

    func testSuccessfulDeployWritesUnitsAndScript() throws {
        let mock = MockProcessRunner()
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily", retention: 5), jobsRoot: jobsRoot)

        try manager.applyBackupJob(on: machine)

        let deployCalls = mock.calls.filter { ($0.stdin ?? "").contains("daemon-reload") }
        XCTAssertEqual(deployCalls.count, 1)
        let script = try XCTUnwrap(deployCalls.first?.stdin)

        XCTAssertTrue(script.contains("/etc/systemd/system/\(RemotePaths.backupUnit)"))
        XCTAssertTrue(script.contains("/etc/systemd/system/\(RemotePaths.backupTimer)"))
        XCTAssertTrue(script.contains("OnCalendar=daily"))
        XCTAssertTrue(script.contains("RETAIN=5"))
        XCTAssertTrue(script.contains("tail -n +$((RETAIN + 1))"))
        // The Pi-local rendezvous with hpm-mutating actions (AD-12/F1).
        XCTAssertTrue(script.contains("flock -n 9"))
        // Atomic writes: the archive, and the deployed script itself (both tmp + mv).
        XCTAssertTrue(script.contains("tmp_archive=$(mktemp"))
        XCTAssertTrue(script.contains("mv -f \"$tmp_archive\" \"$archive\""))
        XCTAssertTrue(script.contains("\(RemotePaths.backupScript).new"))
        XCTAssertTrue(script.contains("mv -f \(RemotePaths.backupScript).new \(RemotePaths.backupScript)"))
        // Atomic writes: the two unit files too (an SSH drop mid-write must never leave a
        // corrupt unit on disk).
        XCTAssertTrue(script.contains("cat > /etc/systemd/system/\(RemotePaths.backupUnit).new <<'HPM_BACKUP_UNIT'"))
        XCTAssertTrue(script.contains("mv -f /etc/systemd/system/\(RemotePaths.backupUnit).new /etc/systemd/system/\(RemotePaths.backupUnit)"))
        XCTAssertTrue(script.contains("cat > /etc/systemd/system/\(RemotePaths.backupTimer).new <<'HPM_BACKUP_TIMER'"))
        XCTAssertTrue(script.contains("mv -f /etc/systemd/system/\(RemotePaths.backupTimer).new /etc/systemd/system/\(RemotePaths.backupTimer)"))
        // A redeployed --schedule must take effect promptly: enable --now alone is a no-op
        // on an already-active timer.
        XCTAssertTrue(script.contains("systemctl restart \(RemotePaths.backupTimer)"))
        // A missing/misconfigured data dir fails with a clear message, not a raw find/cp error.
        XCTAssertTrue(script.contains("[ -d \"$data_dir\" ] || { echo \"homeport-backup: data dir missing: $data_dir\" >&2; exit 1; }"))
    }

    /// The service has no `[Install]` and must never be enabled/started directly — only
    /// the timer. Enabling the service too would fire a backup immediately on every
    /// redeploy and give it a boot-time WantedBy of its own.
    func testEnablesOnlyTheTimerNeverTheService() throws {
        let mock = MockProcessRunner()
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily"), jobsRoot: jobsRoot)

        try manager.applyBackupJob(on: machine)

        let script = try XCTUnwrap(mock.calls.compactMap(\.stdin).first { $0.contains("daemon-reload") })
        XCTAssertTrue(script.contains("systemctl enable --now \(RemotePaths.backupTimer)"))
        XCTAssertFalse(script.contains("enable --now \(RemotePaths.backupUnit)"))
        XCTAssertFalse(script.contains("start \(RemotePaths.backupUnit)"))
        XCTAssertFalse(script.contains("[Install]\nWantedBy=multi-user.target"))
    }

    /// Same content of Manager+Backup's `performBackup`, ported to bash: config +
    /// sqlite-safe data dir with a raw-copy fallback, drop-in HOMEPORT_DATA_DIR override.
    func testScriptPortsPerformBackupContent() throws {
        let mock = MockProcessRunner()
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily"), jobsRoot: jobsRoot)

        try manager.applyBackupJob(on: machine)

        let script = try XCTUnwrap(mock.calls.compactMap(\.stdin).first { $0.contains("daemon-reload") })
        XCTAssertTrue(script.contains("cp -a \"$CONFIG_DIR\" \"$staging/etc-homeport\""))
        XCTAssertTrue(script.contains("command -v sqlite3"))
        XCTAssertTrue(script.contains(".backup '$staging/var-lib-homeport/"))
        XCTAssertTrue(script.contains("cp -a \"$data_dir\"/. \"$staging/var-lib-homeport/\""))
        XCTAssertTrue(script.contains("HOMEPORT_DATA_DIR=*"))
        XCTAssertTrue(script.contains("systemctl show \"$UNIT\" -p Environment"))
    }

    // MARK: - Idempotence

    func testRedeployingAnUnchangedJobIsIdempotent() throws {
        let mock = MockProcessRunner()
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily", retention: 3), jobsRoot: jobsRoot)

        try manager.applyBackupJob(on: machine)
        try manager.applyBackupJob(on: machine)

        let scripts = mock.calls.compactMap(\.stdin).filter { $0.contains("daemon-reload") }
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0], scripts[1])
    }

    // MARK: - Heredoc-injection guard (defense in depth)

    /// A hostile schedule bypassing the CLI's own guard (e.g. a hand-edited job file) must
    /// still be caught here, before any SSH call — not just before the vulnerable line is
    /// reached deep inside script assembly.
    func testAHostileScheduleFromAPreExistingJobFileIsRefusedBeforeAnySSHCall() throws {
        let mock = MockProcessRunner()
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily\nHPM_BACKUP_SCRIPT\nrm -rf /", retention: 3), jobsRoot: jobsRoot)

        XCTAssertThrowsError(try manager.applyBackupJob(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("newline"))
        }
        XCTAssertTrue(mock.calls.isEmpty)
    }

    /// A hostile machine name can't practically reach `applyBackupJob` through real storage —
    /// `BackupJobStore` uses the machine name as the file's own name, so a value breaking the
    /// guard already breaks that write, long before deployment. Covered directly instead: the
    /// shared validator (also used by `performApplyBackupJob`) must reject it and label it
    /// distinctly from a hostile `--schedule`.
    func testValidateBackupJobInputsRejectsAHostileMachineNameDistinctlyFromSchedule() {
        XCTAssertThrowsError(try HomeportManager.validateBackupJobInputs(schedule: "daily", machineName: "raspcorse\nHPM_BACKUP_UNIT")) { error in
            XCTAssertTrue("\(error)".contains("machine name"))
            XCTAssertFalse("\(error)".contains("--schedule"))
        }
    }

    func testValidateBackupJobInputsAcceptsOrdinaryValues() throws {
        XCTAssertNoThrow(try HomeportManager.validateBackupJobInputs(schedule: "*-*-* 03:30:00", machineName: "raspyellow"))
    }

    func testValidateBackupJobInputsRejectsEachHeredocMarker() {
        for marker in HomeportManager.heredocMarkers {
            XCTAssertThrowsError(try HomeportManager.validateBackupJobInputs(schedule: "daily \(marker)", machineName: "raspcorse")) { error in
                XCTAssertTrue("\(error)".contains(marker))
            }
        }
    }

    // MARK: - Rotation arithmetic (executes the real generated snippet)

    /// Runs the actual generated rotation line (extracted from the real deploy script, not
    /// a hand-copied stand-in) against a temp directory pre-seeded with fake archives, so an
    /// off-by-one in `tail -n +$((RETAIN + 1))` would fail this test rather than pass silently
    /// behind a substring assertion. `flock` isn't invoked: it isn't installed on every dev
    /// Mac, and this test only exercises the archive-naming + rotation portion.
    func testRotationKeepsExactlyRetentionArchivesNewestFirst() throws {
        let retain = 3
        let script = HomeportManager.backupJobDeployScript(machineName: "raspcorse", job: BackupJob(schedule: "daily", retention: retain))

        // Anchored on "xargs -r rm --", not on the exact `RETAIN + 1` formula: this must
        // still find (and then execute) the line even if the arithmetic itself regresses,
        // or the count assertion below would never get a chance to catch it.
        let machineLine = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("MACHINE=") })
        let retainLine = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("RETAIN=") })
        let rotationLine = try XCTUnwrap(script.split(separator: "\n").first { $0.contains("xargs -r rm --") })

        let tempDir = NSTemporaryDirectory() + "hpm-rotation-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Seed 6 fake archives with distinct, explicit mtimes (newest = highest index).
        let names = (0..<6).map { "homeport_raspcorse_v0.4.0_2026080\($0)-000000.tar.gz" }
        for (i, name) in names.enumerated() {
            let path = tempDir + "/" + name
            FileManager.default.createFile(atPath: path, contents: Data())
            let mtime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3600)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }

        let composed = """
        \(machineLine)
        \(retainLine)
        BACKUPS_DIR="\(tempDir)"
        \(rotationLine)
        """
        let result = try DefaultProcessRunner().run("/bin/bash", ["-c", composed], stdin: nil)
        XCTAssertTrue(result.succeeded, result.stderr)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir).sorted()
        XCTAssertEqual(remaining.count, retain)
        // The three newest (highest index) survive.
        XCTAssertEqual(Set(remaining), Set(names.suffix(retain)))
    }

    func testDeployFailureThrowsWithRemoteStderr() throws {
        let mock = MockProcessRunner()
        mock.stub(matching: "daemon-reload", exitCode: 1, stderr: "unit file invalid")
        let jobsRoot = NSTemporaryDirectory() + "hpm-jobs-\(UUID().uuidString)"
        let manager = makeTestManager(mock: mock, jobsRoot: jobsRoot)
        try declare(BackupJob(schedule: "daily"), jobsRoot: jobsRoot)

        XCTAssertThrowsError(try manager.applyBackupJob(on: machine)) { error in
            XCTAssertTrue("\(error)".contains("unit file invalid"))
        }
    }
}
