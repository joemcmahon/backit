import XCTest
import Combine
@testable import backit

final class MockJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>
    var startCalled = false
    var shouldSucceed = true

    init(jobType: JobType) {
        self.jobType = jobType
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        startCalled = true
        let status: JobStatus = shouldSucceed ? .done : .failed
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
        let job1 = MockJob(jobType: .disk)
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
        let good = MockJob(jobType: .disk)
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
        let job = MockJobWithSideEffect(jobType: .disk) {
            box.value = FileManager.default.fileExists(atPath: BackupCoordinator.backupLockFile.path)
        }
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        await coordinator.performBackup()
        XCTAssertTrue(box.value, "lock file should exist while backup is running")
    }

    func testPerJobLastResultsSetAfterSuccessfulRun() async throws {
        let diskJob = MockJob(jobType: .disk)
        let dropboxJob = MockJob(jobType: .dropbox)
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [diskJob, dropboxJob] }
        }
        await coordinator.performBackup()
        let cccResult = await MainActor.run { coordinator.cccLastResult }
        let dropboxResult = await MainActor.run { coordinator.dropboxLastResult }
        let duration = await MainActor.run { coordinator.lastRunDuration }
        XCTAssertNotNil(cccResult)
        XCTAssertEqual(cccResult?.status, .done)
        XCTAssertNotNil(cccResult?.completedAt)
        XCTAssertNotNil(dropboxResult)
        XCTAssertEqual(dropboxResult?.status, .done)
        XCTAssertNotNil(dropboxResult?.completedAt)
        XCTAssertNotNil(duration)
        XCTAssertGreaterThanOrEqual(duration ?? -1, 0)
    }

    func testPerJobLastResultsSetForFailedJob() async throws {
        let diskJob = MockJob(jobType: .disk)
        diskJob.shouldSucceed = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [diskJob] }
        }
        await coordinator.performBackup()
        let cccResult = await MainActor.run { coordinator.cccLastResult }
        XCTAssertNotNil(cccResult)
        XCTAssertEqual(cccResult?.status, .failed)
        XCTAssertNotNil(cccResult?.completedAt)
    }

    func testPerJobLastResultsRestoredAtStartup() async throws {
        // Run a backup to populate the DB
        let diskJob = MockJob(jobType: .disk)
        let icloudJob = MockJob(jobType: .icloud)
        let coordinator1 = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [diskJob, icloudJob] }
        }
        await coordinator1.performBackup()

        // Create a fresh coordinator pointing at the same DB (simulates app restart)
        let coordinator2 = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let cccResult = await MainActor.run { coordinator2.cccLastResult }
        let icloudResult = await MainActor.run { coordinator2.icloudLastResult }
        let duration = await MainActor.run { coordinator2.lastRunDuration }
        XCTAssertNotNil(cccResult)
        XCTAssertEqual(cccResult?.status, .done)
        XCTAssertNotNil(icloudResult)
        let dropboxResult = await MainActor.run { coordinator2.dropboxLastResult }
        XCTAssertNil(dropboxResult)  // not in this run
        XCTAssertNotNil(duration)
    }
}
