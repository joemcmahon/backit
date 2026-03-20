import AppKit
import Combine
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var coordinator: BackupCoordinator?
    var scheduleManager: ScheduleManager?
    var settings: BackupSettings?
    var db: DatabaseManager?
    var launchAgentManager: LaunchAgentManager?
    var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    var helpWindow: NSWindow?

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
        if !launchAgent.isInstalled { try? launchAgent.install(backupTime: settings.backupTime) }

        settings.$backupTime
            .dropFirst()
            .sink { [weak self] newTime in
                try? self?.launchAgentManager?.install(backupTime: newTime)
            }
            .store(in: &cancellables)

        // If we launched because launchd fired StartCalendarInterval at backup time,
        // the ScheduleManager timer targets tomorrow. Catch up if backup time was
        // within the last 5 minutes and no backup has run today.
        let backupComps = Calendar.current.dateComponents([.hour, .minute], from: settings.backupTime)
        // Use a 10-minute lookback so nextDate reliably finds today's occurrence;
        // the inner check narrows acceptance to 5 minutes.
        if let lastFired = Calendar.current.nextDate(
            after: Date().addingTimeInterval(-600),
            matching: backupComps,
            matchingPolicy: .nextTime) {
            let elapsed = Date().timeIntervalSince(lastFired)
            let noRunToday = coordinator.lastRunDate.map {
                !Calendar.current.isDateInToday($0)
            } ?? true  // nil means never run
            if elapsed >= 0 && elapsed < 5 * 60 && noRunToday {
                coordinator.runBackup()
            }
        }
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

    // MARK: - Help

    @objc func openHelpWindow(_ sender: Any?) {
        if let win = helpWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "backit Help"
        win.isReleasedWhenClosed = false

        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.textContainerInset = NSSize(width: 20, height: 20)
            if let data = HelpContent.html.data(using: .utf8),
               let attrStr = NSAttributedString(
                   html: data,
                   options: [.documentType: NSAttributedString.DocumentType.html,
                             .characterEncoding: String.Encoding.utf8.rawValue],
                   documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attrStr)
            }
        }
        win.contentView = scrollView
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        helpWindow = win
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
