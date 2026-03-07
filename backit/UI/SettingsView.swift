import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: BackupSettings

    var body: some View {
        Form {
            Section("Schedule") {
                DatePicker("Backup time",
                           selection: $settings.backupTime,
                           displayedComponents: .hourAndMinute)
                DatePicker("Early reminder",
                           selection: $settings.earlyReminderTime,
                           displayedComponents: .hourAndMinute)
                DatePicker("Late reminder",
                           selection: $settings.lateReminderTime,
                           displayedComponents: .hourAndMinute)
            }

            Section("CCC Tasks") {
                TextField("Disk backup task", text: $settings.diskCCCTaskName)
                TextField("Bootable clone task", text: $settings.bootableCCCTaskName)
            }

            Section("Dropbox") {
                TextField("Remote name", text: $settings.dropboxRemoteName)
                TextField("Volume path", text: $settings.dropboxVolumePath)
            }

            Section("History") {
                Stepper("Keep \(settings.historyLimit) run\(settings.historyLimit == 1 ? "" : "s")",
                        value: $settings.historyLimit, in: 1...10)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
        .padding()
    }
}
