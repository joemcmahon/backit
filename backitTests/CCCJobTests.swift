import XCTest
import Combine
@testable import backit

// Inject a mock so tests never touch the real CCC CLI
final class MockCCCCLIRunner: CCCCLIRunner {
    var runResult: Int32 = 0
    private(set) var startedTasks: [String] = []
    private(set) var stoppedTasks: [String] = []

    func runTask(named name: String, progressHandler: @escaping (Double) -> Void) async throws -> Int32 {
        startedTasks.append(name)
        return runResult
    }

    func stopTask(named name: String) {
        stoppedTasks.append(name)
    }
}

// Tests must be async: CCCJob is in the backit module which contains a SwiftUI @main App.
// The Swift compiler infers executor-aware deinit for CCCJob, which requires a Task context.
// Async test methods provide that context via XCTest's Task wrapper.
final class CCCJobTests: XCTestCase {
    func testInitialStatusIsIdle() async {
        let job = CCCJob(jobType: .disk, taskName: "Test Backup",
                         runner: MockCCCCLIRunner())
        XCTAssertEqual(job.progress.value.status, .idle)
    }

    func testJobTypeIsPreserved() async {
        let disk     = CCCJob(jobType: .disk,     taskName: "A", runner: MockCCCCLIRunner())
        let bootable = CCCJob(jobType: .bootable, taskName: "B", runner: MockCCCCLIRunner())
        XCTAssertEqual(disk.jobType, .disk)
        XCTAssertEqual(bootable.jobType, .bootable)
    }

    func testCancelSendsFailedStatus() async {
        let mock = MockCCCCLIRunner()
        let job = CCCJob(jobType: .disk, taskName: "Test", runner: mock)
        job.cancel()
        XCTAssertEqual(job.progress.value.status, .failed)
        XCTAssertEqual(mock.stoppedTasks, ["Test"])
    }

    func testSuccessfulRunSendsDoneStatus() async throws {
        let mock = MockCCCCLIRunner()
        mock.runResult = 0
        let job = CCCJob(jobType: .disk, taskName: "My Backup", runner: mock)
        try await job.start()
        XCTAssertEqual(job.progress.value.status, .done)
        XCTAssertEqual(job.progress.value.fraction, 1.0)
        XCTAssertEqual(mock.startedTasks, ["My Backup"])
    }

    func testFailedRunSendsFailedStatus() async throws {
        let mock = MockCCCCLIRunner()
        mock.runResult = 1
        let job = CCCJob(jobType: .disk, taskName: "My Backup", runner: mock)
        try await job.start()
        XCTAssertEqual(job.progress.value.status, .failed)
    }
}
