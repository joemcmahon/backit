import Foundation
import AppKit
import UserNotifications
import Combine

@MainActor
final class ScheduleManager: ObservableObject {
    @Published var diskPresent: Bool = false
    @Published var nextBackupDate: Date?

    var onBackupTriggered: (() -> Void)?
    var onBackupSkipped: (() -> Void)?

    private let settings: BackupSettings
    private var timers: [Timer] = []
    private var volumeObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(settings: BackupSettings) {
        self.settings = settings
        checkDiskPresence()
        scheduleAllTimers()
        observeVolumes()
    }

    deinit {
        timers.forEach { $0.invalidate() }
        volumeObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func triggerManualBackup() {
        onBackupTriggered?()
    }

    func resetSkipTonight() {
        settings.skipTonight = false
    }

    // MARK: - Disk presence

    func checkDiskPresence() {
        diskPresent = FileManager.default.fileExists(atPath: settings.dropboxVolumePath)
    }

    // MARK: - Volume observation

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        let mount = nc.addObserver(forName: NSWorkspace.didMountNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskPresence() }
        }
        let unmount = nc.addObserver(forName: NSWorkspace.didUnmountNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskPresence() }
        }
        volumeObservers = [mount, unmount]
    }

    // MARK: - Timers

    private func scheduleAllTimers() {
        timers.forEach { $0.invalidate() }
        timers = [
            makeDaily(time: settings.backupReminderTime)  { [weak self] in self?.fireBackupReminder() },
            makeDaily(time: settings.preflightWarningTime) { [weak self] in self?.firePreflightWarning() },
            makeDaily(time: settings.backupTime)           { [weak self] in self?.fireBackupTimer() }
        ]
        nextBackupDate = nextOccurrence(of: settings.backupTime)
    }

    private func makeDaily(time: Date, block: @escaping () -> Void) -> Timer {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let fire  = Calendar.current.nextDate(after: Date(), matching: comps,
                                               matchingPolicy: .nextTime) ?? Date()
        let t = Timer(fire: fire, interval: 86400, repeats: true) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func nextOccurrence(of time: Date) -> Date {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.nextDate(after: Date(), matching: comps,
                                          matchingPolicy: .nextTime) ?? Date()
    }

    // MARK: - Timer actions

    private func fireBackupReminder() {
        checkDiskPresence()
        guard isUserActive() else { return }
        let timeStr = shortTime(settings.backupTime)
        if diskPresent {
            notify(title: "Backup Tonight",
                   body: "Backup scheduled at \(timeStr) — you might want to wrap up.")
        } else {
            notify(title: "Backup Tonight",
                   body: "Backup scheduled at \(timeStr) — your backup drive isn't connected yet.")
        }
    }

    private func firePreflightWarning() {
        checkDiskPresence()
        guard !diskPresent else { return }
        guard isUserActive() else { return }
        notify(title: "Backup Drive Not Connected",
               body: "Backup is coming up soon and your drive isn't connected.",
               categoryID: "PREFLIGHT_WARNING")
    }

    private func fireBackupTimer() {
        checkDiskPresence()
        guard !settings.skipTonight else { settings.skipTonight = false; onBackupSkipped?(); return }
        guard diskPresent else {
            onBackupSkipped?()
            return
        }
        onBackupTriggered?()
    }

    private func isUserActive() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.activationPolicy == .regular && $0.isActive }
    }

    // MARK: - Notifications

    private func notify(title: String, body: String, categoryID: String = "") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        if !categoryID.isEmpty { content.categoryIdentifier = categoryID }
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: date)
    }
}
