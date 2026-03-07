import Foundation

final class LaunchAgentManager {
    private let agentDirectory: URL

    static var systemAgentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    init(agentDirectory: URL = LaunchAgentManager.systemAgentDirectory) {
        self.agentDirectory = agentDirectory
    }

    private var plistURL: URL {
        agentDirectory.appendingPathComponent("backit.plist")
    }

    func install() throws {
        let execPath = Bundle.main.executablePath ?? "/Applications/backit.app/Contents/MacOS/backit"
        let label = "com.backit.\(NSUserName())"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background"
        ]

        try FileManager.default.createDirectory(at: agentDirectory,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: plistURL)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }
}
