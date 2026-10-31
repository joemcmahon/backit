import XCTest
import Combine
@testable import backit

final class MockJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>
    var startCalled = false
    var shouldSucceed = true
    var failureReason: String?
    var finishesWithWarning = false

    init(jobType: JobType) {
        self.jobType = jobType
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        startCalled = true
        let status: JobStatus = finishesWithWarning ? .warning : shouldSucceed ? .done : .failed
        progress.send(JobProgress(fraction: 1.0, bytesTransferred: 1024,
                                  bytesTotal: 1024, transferRate: "", status: status))
    }

    func cancel() {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .failed))
    }
}

final class MockJobWithSideEffect: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>
    private let sideEffect: () -> Void

    init(jobType: JobType, sideEffect: @escaping () -> Void) {
        self.jobType = jobType
        self.progress = CurrentValueSubject(.idle)
        self.sideEffect = sideEffect
    }

    func start() async throws {
        sideEffect()
        progress.send(JobProgress(fraction: 1.0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .done))
    }

    func cancel() {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .failed))
    }
}

final class BackupCoordinatorTests: XCTestCase {
    var db: DatabaseManager!
    var settings: BackupSettings!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(inMemory: true)
        settings = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testRunsAllJobs() async throws {
        let job1 = MockJob(jobType: .dropbox)
        let job2 = MockJob(jobType: .dropbox)
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job1, job2] }
        }
        await coordinator.performBackup()
        XCTAssertTrue(job1.startCalled)
        XCTAssertTrue(job2.startCalled)
    }

    func testSavesBackupRunToDatabase() async throws {
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        await coordinator.performBackup()
        let runs = try db.fetchRecentRuns(limit: 10)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .success)
    }

    func testPrunesRunsToHistoryLimit() async throws {
        settings.historyLimit = 2
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        await coordinator.performBackup()
        await coordinator.performBackup()
        await coordinator.performBackup()
        let runs = try db.fetchRecentRuns(limit: 10)
        XCTAssertEqual(runs.count, 2)
    }

    func testPartialStatusWhenOneJobFails() async throws {
        let good = MockJob(jobType: .dropbox)
        let bad  = MockJob(jobType: .dropbox); bad.shouldSucceed = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [good, bad] }
        }
        await coordinator.performBackup()
        let runs = try db.fetchRecentRuns(limit: 10)
        XCTAssertEqual(runs.first?.status, .partial)
    }

    func testRestoresLastRunDateAndStatusFromDB() async throws {
        // Insert a completed run directly into the DB
        var run = BackupRun(id: nil,
                            startedAt: Date().addingTimeInterval(-3600),
                            completedAt: Date().addingTimeInterval(-3600),
                            status: .success,
                            macosBuild: "24A1")
        try db.save(&run)

        // Creating a fresh coordinator should pick it up
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let (lastRunDate, lastRunStatus) = await MainActor.run {
            (coordinator.lastRunDate, coordinator.lastRunStatus)
        }
        XCTAssertNotNil(lastRunDate)
        XCTAssertEqual(lastRunStatus, .success)
        // Restored date should match what was stored (not a fresh Date())
        XCTAssertEqual(lastRunDate?.timeIntervalSince1970 ?? 0,
                       run.completedAt!.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testCleansUpStaleRunAtStartup() async throws {
        // Insert a run with no completedAt (crashed mid-backup)
        var run = BackupRun(id: nil,
                            startedAt: Date().addingTimeInterval(-60),
                            completedAt: nil,
                            status: .running,
                            macosBuild: "24A1")
        try db.save(&run)

        // Creating a coordinator should clean up the stale run and restore it as failed
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let (lastRunDate, lastRunStatus) = await MainActor.run {
            (coordinator.lastRunDate, coordinator.lastRunStatus)
        }
        // Stale run is closed out and shown as failed, not silently ignored
        XCTAssertNotNil(lastRunDate)
        XCTAssertEqual(lastRunStatus, .failed)

        // Verify the DB record was updated
        let runs = try db.fetchRecentRuns(limit: 1)
        XCTAssertNotNil(runs.first?.completedAt)
        XCTAssertEqual(runs.first?.status, .failed)
    }

    func testIsRunningFalseAfterBackupCompletes() async throws {
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        await coordinator.performBackup()
        let running = await MainActor.run { coordinator.isRunning }
        XCTAssertFalse(running)
    }

    func testLockFileRemovedAfterBackup() async throws {
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        await coordinator.performBackup()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: BackupCoordinator.backupLockFile.path),
            "lock file should be removed after backup completes")
    }

    func testLockFileExistsDuringBackup() async throws {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let job = MockJobWithSideEffect(jobType: .dropbox) {
            box.value = FileManager.default.fileExists(atPath: BackupCoordinator.backupLockFile.path)
        }
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        await coordinator.performBackup()
        XCTAssertTrue(box.value, "lock file should exist while backup is running")
    }

    func testPerJobLastResultsSetAfterSuccessfulRun() async throws {
        let dropboxJob = MockJob(jobType: .dropbox)
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [dropboxJob] }
        }
        await coordinator.performBackup()
        let dropboxResult = await MainActor.run { coordinator.dropboxLastResult }
        let duration = await MainActor.run { coordinator.lastRunDuration }
        XCTAssertNotNil(dropboxResult)
        XCTAssertEqual(dropboxResult?.status, .done)
        XCTAssertNotNil(dropboxResult?.completedAt)
        XCTAssertNotNil(duration)
        XCTAssertGreaterThanOrEqual(duration ?? -1, 0)
    }

    func testPerJobLastResultsSetForFailedJob() async throws {
        let dropboxJob = MockJob(jobType: .dropbox)
        dropboxJob.shouldSucceed = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [dropboxJob] }
        }
        await coordinator.performBackup()
        let dropboxResult = await MainActor.run { coordinator.dropboxLastResult }
        XCTAssertNotNil(dropboxResult)
        XCTAssertEqual(dropboxResult?.status, .failed)
        XCTAssertNotNil(dropboxResult?.completedAt)
    }

    func testPerJobLastResultsRestoredAtStartup() async throws {
        // Run a backup to populate the DB
        let dropboxJob = MockJob(jobType: .dropbox)
        let coordinator1 = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [dropboxJob] }
        }
        await coordinator1.performBackup()

        // Create a fresh coordinator pointing at the same DB (simulates app restart)
        let coordinator2 = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let dropboxResult = await MainActor.run { coordinator2.dropboxLastResult }
        let duration = await MainActor.run { coordinator2.lastRunDuration }
        XCTAssertNotNil(dropboxResult)
        XCTAssertEqual(dropboxResult?.status, .done)
        XCTAssertNotNil(duration)
    }

    func testFailureReasonPublishedAfterRun() async throws {
        let job = MockJob(jobType: .dropbox)
        job.shouldSucceed = false
        job.failureReason = "Backup volume is full"
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        await coordinator.performBackup()
        let reason = await MainActor.run { coordinator.lastFailureReason }
        XCTAssertEqual(reason, "Backup volume is full")

        job.shouldSucceed = true
        job.failureReason = nil
        await coordinator.performBackup()
        let cleared = await MainActor.run { coordinator.lastFailureReason }
        XCTAssertNil(cleared)
    }

    func testRunWithSkippedFilesIsPartialNotSuccess() async throws {
        let job = MockJob(jobType: .dropbox)
        job.finishesWithWarning = true
        job.failureReason = "3 files couldn't be copied"
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        await coordinator.performBackup()
        let run = try XCTUnwrap(db.fetchRecentRuns(limit: 1).first)
        XCTAssertEqual(run.status, .partial)
        XCTAssertEqual(try db.fetchJobResults(forRun: run.id!).first?.status, .warning)
        let reason = await MainActor.run { coordinator.lastFailureReason }
        XCTAssertEqual(reason, "3 files couldn't be copied")
    }

    func testSingleJobRunWithSkippedFilesIsPartial() async throws {
        let job = MockJob(jobType: .dropbox)
        job.finishesWithWarning = true
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        await coordinator.performSingleJob(.dropbox)
        XCTAssertEqual(try db.fetchRecentRuns(limit: 1).first?.status, .partial)
    }
}
