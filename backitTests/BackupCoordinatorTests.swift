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
}
