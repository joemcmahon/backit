import XCTest
import Combine
import UserNotifications
@testable import backit

final class HeadlessRunnerTests: XCTestCase {
    var db: DatabaseManager!
    var settings: BackupSettings!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(inMemory: true)
        settings = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    // MARK: - Notification body (pure logic)

    func testNotificationBodyAllSucceeded() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .done),
            makeJobResult(type: .dropbox, status: .done),
            makeJobResult(type: .icloud, status: .done)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .success, completedAt: startedAt)
        XCTAssertTrue(body.contains("succeeded"), "body: \(body)")
        XCTAssertTrue(body.contains("disk clone"), "body: \(body)")
        XCTAssertTrue(body.contains("Dropbox"), "body: \(body)")
        XCTAssertTrue(body.contains("iCloud"), "body: \(body)")
        XCTAssertFalse(body.contains("failed"), "body: \(body)")
    }

    func testNotificationBodyPartial() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .failed),
            makeJobResult(type: .dropbox, status: .done)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .partial, completedAt: startedAt)
        XCTAssertTrue(body.contains("Dropbox") && body.contains("succeeded"), "body: \(body)")
        XCTAssertTrue(body.contains("disk clone") && body.contains("failed"), "body: \(body)")
    }

    func testNotificationBodyAllFailed() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .failed),
            makeJobResult(type: .dropbox, status: .failed)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .failed, completedAt: startedAt)
        XCTAssertFalse(body.contains("succeeded"), "body: \(body)")
    }

    func testNotificationBodyNoJobsConfigured() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let body = HeadlessRunner.notificationBody(
            jobResults: [], lastRunStatus: .success, completedAt: startedAt)
        XCTAssertTrue(body.contains("no jobs configured"), "body: \(body)")
    }

    func testNotificationBodyIncludesTime() async {
        let startedAt = makeDate(hour: 14, minute: 30)
        let body = HeadlessRunner.notificationBody(
            jobResults: [], lastRunStatus: .success, completedAt: startedAt)
        XCTAssertTrue(body.contains("30"), "body should contain minute: \(body)")
    }

    // MARK: - Concurrent-instance guard

    func testRunSkipsWhenAnotherInstanceIsBackingUp() async {
        var terminated = false
        var notificationPosted = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { terminated = true },
                notificationPoster: { _ in notificationPosted = true },
                backupRunningChecker: { true }
            )
        }
        await runner.run()
        XCTAssertTrue(terminated, "should terminate even when skipping")
        XCTAssertTrue(notificationPosted, "should notify that backup was skipped")
        let runs = try! db.fetchRecentRuns(limit: 10)
        XCTAssertEqual(runs.count, 0, "no backup run should be recorded when skipped")
    }

    func testRunProceedsWhenNoOtherInstanceIsBackingUp() async {
        var terminated = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { terminated = true },
                notificationPoster: { _ in },
                backupRunningChecker: { false }
            )
        }
        await runner.run()
        XCTAssertTrue(terminated)
        let runs = try! db.fetchRecentRuns(limit: 10)
        XCTAssertEqual(runs.count, 1, "backup should run when no other instance is active")
    }

    // MARK: - Integration

    func testRunCallsTerminateHandler() async {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { box.value = true },
                notificationPoster: { _ in }
            )
        }
        await runner.run()
        XCTAssertTrue(box.value)
    }

    func testRunRecordsBackupInDatabase() async {
        let job = MockHeadlessJob(jobType: .dropbox, shouldSucceed: true)
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { },
                notificationPoster: { _ in }
            )
        }
        await runner.run()
        let runs = try! db.fetchRecentRuns(limit: 1)
        XCTAssertEqual(runs.count, 1)
        let status = runs.first?.status
        XCTAssertEqual(status, .success)
    }

    // MARK: - Helpers

    private func makeDate(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 21
        comps.hour = hour; comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    private func makeJobResult(type: JobType, status: JobStatus) -> JobResult {
        JobResult(id: nil, runId: 1, jobType: type, status: status,
                  bytesTransferred: 1024, bytesTotal: 1024, durationSeconds: 1)
    }
}

final class MockHeadlessJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>
    private let shouldSucceed: Bool

    init(jobType: JobType, shouldSucceed: Bool) {
        self.jobType = jobType
        self.shouldSucceed = shouldSucceed
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        let status: JobStatus = shouldSucceed ? .done : .failed
        progress.send(JobProgress(fraction: 1.0, bytesTransferred: 1024,
                                  bytesTotal: 1024, transferRate: "", status: status))
    }

    func cancel() {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .failed))
    }
}
