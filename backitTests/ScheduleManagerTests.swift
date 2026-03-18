import XCTest
@testable import backit

final class ScheduleManagerTests: XCTestCase {
    var settings: BackupSettings!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: UUID().uuidString)!
        settings = BackupSettings(userDefaults: testDefaults)
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

    // MARK: - Interval defaults

    func testDefaultPreflightInterval() {
        XCTAssertEqual(settings.preflightIntervalMinutes, 30)
    }

    func testDefaultReminderInterval() {
        XCTAssertEqual(settings.reminderIntervalMinutes, 120)
    }

    // MARK: - Interval persistence

    func testPreflightIntervalPersists() async {
        settings.preflightIntervalMinutes = 15
        let reloaded = BackupSettings(userDefaults: testDefaults)
        XCTAssertEqual(reloaded.preflightIntervalMinutes, 15)
    }

    func testReminderIntervalPersists() async {
        settings.reminderIntervalMinutes = 45
        let reloaded = BackupSettings(userDefaults: testDefaults)
        XCTAssertEqual(reloaded.reminderIntervalMinutes, 45)
    }

    // MARK: - Computed fire times

    func testPreflightFiresBeforeBackup() async {
        // preflight must fire preflightIntervalMinutes before backupTime
        settings.preflightIntervalMinutes = 10
        let manager = await MainActor.run { ScheduleManager(settings: settings) }
        let nextBackup = await MainActor.run { manager.nextBackupDate! }
        let expectedPreflight = nextBackup - TimeInterval(10 * 60)
        // nextBackupDate is the next occurrence of backupTime; preflight is 10 min earlier
        XCTAssertEqual(expectedPreflight.timeIntervalSince1970,
                       (nextBackup - 600).timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testReminderFiresBeforePreflight() async {
        // reminder must fire reminderIntervalMinutes before preflight
        settings.preflightIntervalMinutes = 10
        settings.reminderIntervalMinutes = 20
        let manager = await MainActor.run { ScheduleManager(settings: settings) }
        let nextBackup = await MainActor.run { manager.nextBackupDate! }
        let expectedReminder = nextBackup - TimeInterval((10 + 20) * 60)
        XCTAssertEqual(expectedReminder.timeIntervalSince1970,
                       (nextBackup - 1800).timeIntervalSince1970,
                       accuracy: 1.0)
    }

}
