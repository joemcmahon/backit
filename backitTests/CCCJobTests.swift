import XCTest
import Combine
@testable import backit

// Inject a mock so tests never touch real AppleScript
final class MockScriptRunner: AppleScriptRunner {
    var responseMap: [String: String] = [:]
    private(set) var scripts: [String] = []

    func run(script: String) throws -> String {
        scripts.append(script)
        for (key, value) in responseMap {
            if script.contains(key) { return value }
        }
        return ""
    }
}

// Tests must be async: CCCJob is in the backit module which contains a SwiftUI @main App.
// The Swift compiler infers executor-aware deinit for CCCJob, which requires a Task context.
// Async test methods provide that context via XCTest's Task wrapper.
final class CCCJobTests: XCTestCase {
    func testInitialStatusIsIdle() async {
        let job = CCCJob(jobType: .disk, taskName: "Test Backup",
                         scriptRunner: MockScriptRunner())
        XCTAssertEqual(job.progress.value.status, .idle)
    }

    func testJobTypeIsPreserved() async {
        let disk     = CCCJob(jobType: .disk,     taskName: "A", scriptRunner: MockScriptRunner())
        let bootable = CCCJob(jobType: .bootable, taskName: "B", scriptRunner: MockScriptRunner())
        XCTAssertEqual(disk.jobType, .disk)
        XCTAssertEqual(bootable.jobType, .bootable)
    }

    func testCancelSendsFailedStatus() async {
        let job = CCCJob(jobType: .disk, taskName: "Test", scriptRunner: MockScriptRunner())
        job.cancel()
        XCTAssertEqual(job.progress.value.status, .failed)
    }
}
