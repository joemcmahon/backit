import XCTest
import Combine
@testable import backit

final class BackupJobTests: XCTestCase {
    func testProgressFractionClamped() {
        var p = JobProgress(fraction: 1.5, bytesTransferred: 100, bytesTotal: 100, transferRate: "1MB/s", status: .done)
        XCTAssertEqual(p.fraction, 1.0)

        p = JobProgress(fraction: -0.1, bytesTransferred: 0, bytesTotal: 0, transferRate: "", status: .idle)
        XCTAssertEqual(p.fraction, 0.0)
    }
}
