import XCTest
@testable import backit

final class BackupSettingsTests: XCTestCase {
    var sut: BackupSettings!

    override func setUp() {
        super.setUp()
        sut = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testDefaultHistoryLimit() {
        XCTAssertEqual(sut.historyLimit, 3)
    }

    func testDefaultDiskCCCTaskName() {
        XCTAssertEqual(sut.diskCCCTaskName, "\(NSUserName()) Backup")
    }

    func testDefaultDropboxRemoteName() {
        XCTAssertEqual(sut.dropboxRemoteName, "\(NSUserName())-dropbox")
    }

    func testRoundTripHistoryLimit() {
        sut.historyLimit = 7
        XCTAssertEqual(sut.historyLimit, 7)
    }

    func testRoundTripStoredMachineUUID() {
        sut.storedMachineUUID = "test-uuid-1234"
        XCTAssertEqual(sut.storedMachineUUID, "test-uuid-1234")
    }

    func testDefaultStoredMachineUUIDIsEmpty() {
        XCTAssertEqual(sut.storedMachineUUID, "")
    }
}
