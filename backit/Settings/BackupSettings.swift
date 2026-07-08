import Foundation
import Combine

final class BackupSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var backupTime: Date              { didSet { defaults.set(backupTime, forKey: "backupTime") } }
    @Published var preflightIntervalMinutes: Int { didSet { defaults.set(preflightIntervalMinutes, forKey: "preflightIntervalMinutes") } }
    @Published var reminderIntervalMinutes: Int  { didSet { defaults.set(reminderIntervalMinutes, forKey: "reminderIntervalMinutes") } }
    @Published var diskCCCTaskName: String { didSet { defaults.set(diskCCCTaskName.trimmingCharacters(in: .whitespaces), forKey: "diskCCCTaskName") } }
    @Published var bootableCCCTaskName: String { didSet { defaults.set(bootableCCCTaskName.trimmingCharacters(in: .whitespaces), forKey: "bootableCCCTaskName") } }
    @Published var diskBackupVolumePath: String { didSet { defaults.set(diskBackupVolumePath.trimmingCharacters(in: .whitespaces), forKey: "diskBackupVolumePath") } }
    @Published var diskBackupEnabled: Bool { didSet { defaults.set(diskBackupEnabled, forKey: "diskBackupEnabled") } }
    @Published var dropboxRemoteName: String { didSet { defaults.set(dropboxRemoteName.trimmingCharacters(in: .whitespaces), forKey: "dropboxRemoteName") } }
    @Published var dropboxVolumePath: String { didSet { defaults.set(dropboxVolumePath.trimmingCharacters(in: .whitespaces), forKey: "dropboxVolumePath") } }
    @Published var dropboxBackupEnabled: Bool { didSet { defaults.set(dropboxBackupEnabled, forKey: "dropboxBackupEnabled") } }
    @Published var historyLimit: Int       { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var storedMachineUUID: String { didSet { defaults.set(storedMachineUUID, forKey: "storedMachineUUID") } }
    @Published var skipTonight: Bool       { didSet { defaults.set(skipTonight, forKey: "skipTonight") } }
    @Published var verifyAfterSync: Bool   { didSet { defaults.set(verifyAfterSync, forKey: "verifyAfterSync") } }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.backupTime              = (userDefaults.object(forKey: "backupTime") as? Date) ?? Self.time(hour: 23, minute: 0)
        let pf = userDefaults.integer(forKey: "preflightIntervalMinutes")
        self.preflightIntervalMinutes = pf == 0 ? 30 : pf
        let rm = userDefaults.integer(forKey: "reminderIntervalMinutes")
        self.reminderIntervalMinutes  = rm == 0 ? 120 : rm
        self.diskCCCTaskName       = userDefaults.string(forKey: "diskCCCTaskName")       ?? "\(NSUserName()) Backup"
        self.bootableCCCTaskName   = userDefaults.string(forKey: "bootableCCCTaskName")   ?? "\(NSUserName()) Bootable"
        self.diskBackupVolumePath  = userDefaults.string(forKey: "diskBackupVolumePath")  ?? ""
        self.diskBackupEnabled     = userDefaults.object(forKey: "diskBackupEnabled") as? Bool ?? true
        self.dropboxRemoteName     = userDefaults.string(forKey: "dropboxRemoteName")     ?? "\(NSUserName())-dropbox"
        self.dropboxVolumePath     = userDefaults.string(forKey: "dropboxVolumePath")     ?? "/Volumes/\(NSUserName()) Dropbox Clone"
        self.dropboxBackupEnabled  = userDefaults.object(forKey: "dropboxBackupEnabled") as? Bool ?? true
        let limit = userDefaults.integer(forKey: "historyLimit")
        self.historyLimit      = limit == 0 ? 3 : limit
        self.storedMachineUUID = userDefaults.string(forKey: "storedMachineUUID") ?? ""
        self.skipTonight       = userDefaults.bool(forKey: "skipTonight")
        self.verifyAfterSync   = userDefaults.object(forKey: "verifyAfterSync") as? Bool ?? true
    }

    private static func time(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }
}
