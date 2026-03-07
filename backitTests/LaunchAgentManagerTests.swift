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
}
