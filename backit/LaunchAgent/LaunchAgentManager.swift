import Foundation

final class LaunchAgentManager {
    static let currentPlistVersion = 3
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

    func install(backupTime: Date = Date()) throws {
        let execPath = Bundle.main.executablePath ?? "/Applications/backit.app/Contents/MacOS/backit"
        let label = "com.backit.\(NSUserName())"
        let comps = Calendar.current.dateComponents([.hour, .minute], from: backupTime)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath, "--headless"],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Background",
            "StartCalendarInterval": [
                "Hour": comps.hour ?? 23,
                "Minute": comps.minute ?? 0
            ],
            "BackitPlistVersion": Self.currentPlistVersion
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

    private var installedVersion: Int? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any] else { return nil }
        return plist["BackitPlistVersion"] as? Int
    }

    private var installedExecutablePath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    var needsInstall: Bool {
        !isInstalled
            || installedVersion != Self.currentPlistVersion
            || installedExecutablePath != Bundle.main.executablePath
    }
}
