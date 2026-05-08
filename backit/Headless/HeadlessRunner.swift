import AppKit
import UserNotifications

@MainActor
final class HeadlessRunner {
    private let db: DatabaseManager
    private let settings: BackupSettings
    private unowned let coordinator: BackupCoordinator
    private let settleDelay: Duration
    private let terminateHandler: () -> Void
    private let notificationPoster: (UNNotificationRequest) async -> Void
    private let backupRunningChecker: () -> Bool

    init(db: DatabaseManager,
         settings: BackupSettings,
         coordinator: BackupCoordinator,
         settleDelay: Duration = .seconds(30),
         terminateHandler: (() -> Void)? = nil,
         notificationPoster: (@Sendable (UNNotificationRequest) async -> Void)? = nil,
         backupRunningChecker: (() -> Bool)? = nil) {
        self.db = db
        self.settings = settings
        self.coordinator = coordinator
        self.settleDelay = settleDelay
        self.terminateHandler = terminateHandler ?? { NSApp.terminate(nil) }
        self.notificationPoster = notificationPoster ?? { request in
            try? await UNUserNotificationCenter.current().add(request)
        }
        self.backupRunningChecker = backupRunningChecker ?? HeadlessRunner.defaultBackupRunningChecker
    }

    func run() async {
        if backupRunningChecker() {
            terminateHandler()
            return
        }
        try? await Task.sleep(for: settleDelay)
        // Re-check after settle: another instance may have started during the delay
        if backupRunningChecker() {
            terminateHandler()
            return
        }
        let startedAt = Date()
        await coordinator.performBackup()
        await postNotification(startedAt: startedAt)
        terminateHandler()
    }

    // Checks whether another backit process is currently running a backup by reading
    // the PID lock file written by BackupCoordinator.performBackup().
    nonisolated static let backupLockFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backit-backup.lock")

    nonisolated static func defaultBackupRunningChecker() -> Bool {
        guard let data = try? Data(contentsOf: backupLockFile),
              let pidStr = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else { return false }
        // kill(pid, 0) succeeds if the process exists; ESRCH means it's gone (stale lock)
        return kill(pid, 0) == 0
    }

    // MARK: - Notification

    private func postNotification(startedAt: Date) async {
        let recentRun = try? db.fetchRecentRuns(limit: 1).first
        let jobResults = recentRun.flatMap { run -> [JobResult]? in
            try? db.fetchJobResults(forRun: run.id!)
        } ?? []
        let completedAt = recentRun?.completedAt ?? Date()
        let body = Self.notificationBody(jobResults: jobResults,
                                         lastRunStatus: coordinator.lastRunStatus,
                                         completedAt: completedAt)
        let content = UNMutableNotificationContent()
        content.title = "Backit"
        content.body = body
        let request = UNNotificationRequest(identifier: "backit.headless.result",
                                            content: content,
                                            trigger: nil)
        await notificationPoster(request)
    }

    // Static so tests can call it without constructing a full HeadlessRunner
    nonisolated static func notificationBody(jobResults: [JobResult],
                                 lastRunStatus: RunStatus?,
                                 completedAt: Date) -> String {
        let timeString = timeFormatter.string(from: completedAt)

        if jobResults.isEmpty && lastRunStatus == .success {
            return "Backup skipped at \(timeString) — no jobs configured."
        }

        if jobResults.isEmpty {
            return "Backup failed at \(timeString) — no jobs completed."
        }

        let succeeded = jobResults.filter { $0.status == .done }.map { jobName($0.jobType) }
        let failed    = jobResults.filter { $0.status != .done }.map { jobName($0.jobType) }

        if failed.isEmpty {
            return "Backup completed at \(timeString) — \(listString(succeeded)) succeeded."
        } else if succeeded.isEmpty {
            return "Backup failed at \(timeString) — \(listString(failed)) failed."
        } else {
            return "Backup completed at \(timeString) — \(listString(succeeded)) succeeded; \(listString(failed)) failed."
        }
    }

    // MARK: - Helpers

    private nonisolated static func jobName(_ type: JobType) -> String {
        switch type {
        case .disk:     return "disk clone"
        case .dropbox:  return "Dropbox"
        case .bootable: return "bootable clone"
        }
    }

    private nonisolated static func listString(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default:
            let allButLast = items.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(items.last!)"
        }
    }

    private nonisolated static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }
}
