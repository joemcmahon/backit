import XCTest
@testable import backit

final class MacOSVersionDetectorTests: XCTestCase {
    func testCurrentBuildIsNonEmpty() {
        XCTAssertFalse(MacOSVersionDetector.currentBuild().isEmpty)
    }

    func testHardwareUUIDIsNonEmpty() {
        XCTAssertFalse(MacOSVersionDetector.hardwareUUID().isEmpty)
    }

    func testHardwareUUIDIsStable() {
        XCTAssertEqual(MacOSVersionDetector.hardwareUUID(), MacOSVersionDetector.hardwareUUID())
    }
}
