import AppKit
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var coordinator: BackupCoordinator?
    var scheduleManager: ScheduleManager?
    var settings: BackupSettings?
    var db: DatabaseManager?
    var launchAgentManager: LaunchAgentManager?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

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
        scheduleManager.onBackupSkipped   = { coordinator.recordSkipped() }

        // Notification permission + categories
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerNotificationCategories(center)

        // Main floating window
        showMainWindow()

        // Install launch agent if not already present
        if !launchAgent.isInstalled { try? launchAgent.install() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return false
    }

    func showMainWindow() {
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let coordinator, let settings, let db else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Backit"
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(
            rootView: BackitMainView(coordinator: coordinator, settings: settings, db: db)
        )
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = win
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "SKIP_TONIGHT" {
            settings?.skipTonight = true
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func registerNotificationCategories(_ center: UNUserNotificationCenter) {
        let skip = UNNotificationAction(identifier: "SKIP_TONIGHT",
                                         title: "Skip Tonight", options: [])
        let category = UNNotificationCategory(identifier: "PREFLIGHT_WARNING",
                                               actions: [skip],
                                               intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
}
