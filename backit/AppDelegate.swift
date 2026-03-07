import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var menubarController: MenubarController?
    var coordinator: BackupCoordinator?
    var scheduleManager: ScheduleManager?
    var settings: BackupSettings?
    var db: DatabaseManager?
    var launchAgentManager: LaunchAgentManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Core objects
        let settings = BackupSettings()
        let db = (try? DatabaseManager()) ?? (try! DatabaseManager(inMemory: true))
        let coordinator = BackupCoordinator(db: db, settings: settings)
        let scheduleManager = ScheduleManager(settings: settings)
        let launchAgent = LaunchAgentManager()

        self.settings = settings
        self.db = db
        self.coordinator = coordinator
        self.scheduleManager = scheduleManager
        self.launchAgentManager = launchAgent

        // Wire schedule → coordinator
        scheduleManager.onBackupTriggered = { coordinator.runBackup() }

        // Notification permission + categories
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerNotificationCategories(center)

        // Menubar
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        menubarController = MenubarController(statusItem: item,
                                              coordinator: coordinator,
                                              scheduleManager: scheduleManager,
                                              settings: settings)

        // Install launch agent if not already present
        if !launchAgent.isInstalled { try? launchAgent.install() }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case "STOP_WORK":
            coordinator?.runBackup()
        case "SKIP_TONIGHT":
            settings?.skipTonight = true
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func registerNotificationCategories(_ center: UNUserNotificationCenter) {
        let stop = UNNotificationAction(identifier: "STOP_WORK",
                                         title: "I've Stopped — Back Up Now", options: [])
        let skip = UNNotificationAction(identifier: "SKIP_TONIGHT",
                                         title: "Skip for Now", options: [])
        let category = UNNotificationCategory(identifier: "LATE_CHECK",
                                               actions: [stop, skip],
                                               intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
}
