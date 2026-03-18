import XCTest
import Combine
@testable import backit

// Tests must be async: ICloudJob is in the backit module (which contains a SwiftUI @main App),
// so the Swift compiler gives it executor-aware deinit. Async tests provide the required Task context.
final class ICloudJobTests: XCTestCase {
    func testInitialStatusIsIdle() async {
        let job = ICloudJob(remoteName: "test-icloud", volumePath: "/tmp/test")
        XCTAssertEqual(job.progress.value.status, .idle)
    }

    func testJobTypeIsICloud() async {
        let job = ICloudJob(remoteName: "test-icloud", volumePath: "/tmp/test")
        XCTAssertEqual(job.jobType, .icloud)
    }

    func testCancelSendsFailedStatus() async {
        let job = ICloudJob(remoteName: "test-icloud", volumePath: "/tmp/test")
        job.cancel()
        XCTAssertEqual(job.progress.value.status, .failed)
    }
}
