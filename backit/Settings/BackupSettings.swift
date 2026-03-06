import Foundation
import Combine

final class BackupSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var backupTime: Date        { didSet { defaults.set(backupTime, forKey: "backupTime") } }
    @Published var earlyReminderTime: Date { didSet { defaults.set(earlyReminderTime, forKey: "earlyReminderTime") } }
    @Published var lateReminderTime: Date  { didSet { defaults.set(lateReminderTime, forKey: "lateReminderTime") } }
    @Published var diskCCCTaskName: String { didSet { defaults.set(diskCCCTaskName, forKey: "diskCCCTaskName") } }
    @Published var bootableCCCTaskName: String { didSet { defaults.set(bootableCCCTaskName, forKey: "bootableCCCTaskName") } }
    @Published var dropboxRemoteName: String { didSet { defaults.set(dropboxRemoteName, forKey: "dropboxRemoteName") } }
    @Published var dropboxVolumePath: String { didSet { defaults.set(dropboxVolumePath, forKey: "dropboxVolumePath") } }
    @Published var historyLimit: Int       { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var storedMachineUUID: String { didSet { defaults.set(storedMachineUUID, forKey: "storedMachineUUID") } }
    @Published var skipTonight: Bool       { didSet { defaults.set(skipTonight, forKey: "skipTonight") } }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.backupTime        = (userDefaults.object(forKey: "backupTime") as? Date)        ?? Self.time(hour: 23, minute: 0)
        self.earlyReminderTime = (userDefaults.object(forKey: "earlyReminderTime") as? Date) ?? Self.time(hour: 17, minute: 0)
        self.lateReminderTime  = (userDefaults.object(forKey: "lateReminderTime") as? Date)  ?? Self.time(hour: 21, minute: 0)
        self.diskCCCTaskName     = userDefaults.string(forKey: "diskCCCTaskName")     ?? "\(NSUserName()) Backup"
        self.bootableCCCTaskName = userDefaults.string(forKey: "bootableCCCTaskName") ?? "\(NSUserName()) Bootable"
        self.dropboxRemoteName   = userDefaults.string(forKey: "dropboxRemoteName")   ?? "\(NSUserName())-dropbox"
        self.dropboxVolumePath   = userDefaults.string(forKey: "dropboxVolumePath")   ?? "/Volumes/\(NSUserName()) Dropbox Clone"
        let limit = userDefaults.integer(forKey: "historyLimit")
        self.historyLimit      = limit == 0 ? 3 : limit
        self.storedMachineUUID = userDefaults.string(forKey: "storedMachineUUID") ?? ""
        self.skipTonight       = userDefaults.bool(forKey: "skipTonight")
    }

    private static func time(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }
}
