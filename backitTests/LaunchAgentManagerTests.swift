import XCTest
@testable import backit

final class LaunchAgentManagerTests: XCTestCase {
    var plistURL: URL!
    var sut: LaunchAgentManager!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-agents-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sut = LaunchAgentManager(agentDirectory: tmp)
        plistURL = tmp.appendingPathComponent("backit.plist")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: plistURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testInstallCreatesPlist() throws {
        try sut.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testUninstallRemovesPlist() throws {
        try sut.install()
        try sut.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testPlistContainsBundleExecutable() throws {
        try sut.install()
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data,
                                                               format: nil) as! [String: Any]
        let args = plist["ProgramArguments"] as? [String] ?? []
        XCTAssertFalse(args.isEmpty)
    }

    func testNeedsInstallWhenNotInstalled() throws {
        XCTAssertTrue(sut.needsInstall)
    }

    func testNeedsInstallWhenVersionMismatch() throws {
        let oldPlist: [String: Any] = ["Label": "com.backit.test"]
        let data = try PropertyListSerialization.data(fromPropertyList: oldPlist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL)
        XCTAssertTrue(sut.needsInstall)
    }

    func testNeedsInstallFalseWhenCurrentVersion() throws {
        try sut.install()
        XCTAssertFalse(sut.needsInstall)
    }

    func testNeedsInstallWhenExecutablePathMismatch() throws {
        // Write a v3 plist with a stale path (simulates moving app after install)
        let stalePath = "/some/old/path/backit.app/Contents/MacOS/backit"
        let stalePlist: [String: Any] = [
            "Label": "com.backit.test",
            "ProgramArguments": [stalePath, "--headless"],
            "BackitPlistVersion": LaunchAgentManager.currentPlistVersion
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: stalePlist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL)
        XCTAssertTrue(sut.needsInstall)
    }

    func testInstallEmbedsStartCalendarInterval() throws {
        // Use a specific known time: 23:15
        var comps = DateComponents()
        comps.hour = 23
        comps.minute = 15
        let backupTime = Calendar.current.date(from: comps)!

        try sut.install(backupTime: backupTime)

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data,
                                                               format: nil) as! [String: Any]
        let interval = plist["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(interval?["Hour"], 23)
        XCTAssertEqual(interval?["Minute"], 15)
    }

    func testPlistVersion3HasRunAtLoadFalse() throws {
        try sut.install()
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let runAtLoad = plist["RunAtLoad"] as? Bool
        XCTAssertEqual(runAtLoad, false)
    }

    func testPlistVersion3HasHeadlessArgument() throws {
        try sut.install()
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let args = plist["ProgramArguments"] as? [String] ?? []
        XCTAssertTrue(args.contains("--headless"), "ProgramArguments should contain --headless")
    }
}
