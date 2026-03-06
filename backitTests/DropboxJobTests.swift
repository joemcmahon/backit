import XCTest
import Combine
@testable import backit

// Tests must be async: DropboxJob is in the backit module (which contains a SwiftUI @main App),
// so the Swift compiler gives it executor-aware deinit. Async tests provide the required Task context.
final class DropboxJobTests: XCTestCase {
    func testInitialStatusIsIdle() async {
        let job = DropboxJob(remoteName: "test-dropbox", volumePath: "/tmp/test")
        XCTAssertEqual(job.progress.value.status, .idle)
    }

    func testJobTypeIsDropbox() async {
        let job = DropboxJob(remoteName: "test-dropbox", volumePath: "/tmp/test")
        XCTAssertEqual(job.jobType, .dropbox)
    }

    func testCancelSendsFailedStatus() async {
        let job = DropboxJob(remoteName: "test-dropbox", volumePath: "/tmp/test")
        job.cancel()
        XCTAssertEqual(job.progress.value.status, .failed)
    }
}
