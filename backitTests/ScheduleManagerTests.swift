import XCTest
@testable import backit

final class ScheduleManagerTests: XCTestCase {
    var settings: BackupSettings!

    override func setUp() {
        super.setUp()
        settings = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testDiskNotPresentForNonexistentPath() async {
        settings.dropboxVolumePath = "/Volumes/DoesNotExist_\(UUID().uuidString)"
        let (manager) = await MainActor.run { ScheduleManager(settings: settings) }
        let diskPresent = await MainActor.run { manager.diskPresent }
        XCTAssertFalse(diskPresent)
    }

    func testDiskPresentForExistingPath() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        settings.dropboxVolumePath = tmp.path
        let manager = await MainActor.run { ScheduleManager(settings: settings) }
        let diskPresent = await MainActor.run { manager.diskPresent }
        XCTAssertTrue(diskPresent)
    }

    func testNextBackupDateIsInFuture() async {
        let manager = await MainActor.run { ScheduleManager(settings: settings) }
        let nextDate = await MainActor.run { manager.nextBackupDate }
        XCTAssertGreaterThan(nextDate ?? Date.distantPast, Date())
    }
}
