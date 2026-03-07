import SwiftUI

struct MainPanelView: View {
    @ObservedObject var coordinator: BackupCoordinator
    let db: DatabaseManager?

    private var cccInstalled: Bool { CCCJob.isInstalled() }
    private var rcloneInstalled: Bool { DropboxJob.isInstalled() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Backit").font(.headline).padding(.top)

            if !cccInstalled || !rcloneInstalled {
                missingToolsSection
            }

            if coordinator.isRunning {
                runningSection
            } else {
                idleSection
            }

            Divider()
            RunHistoryView(db: db)
        }
        .padding()
        .frame(width: 300)
    }

    private var missingToolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !cccInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Carbon Copy Cloner not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Button("Download from bombich.com") {
                        NSWorkspace.shared.open(URL(string: "https://bombich.com")!)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
            if !rcloneInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    Label("rclone not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Install with: brew install rclone")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Backup Running…", systemImage: "arrow.clockwise")
                .foregroundColor(.blue)

            if let jobType = coordinator.currentJobType {
                Text(jobType.rawValue.capitalized)
                    .font(.caption).foregroundColor(.secondary)
            }

            ProgressView(value: coordinator.currentProgress.fraction)

            Text(coordinator.currentProgress.transferRate)
                .font(.caption2).foregroundColor(.secondary)

            Button("Cancel") { coordinator.cancelBackup() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
    }

    private var idleSection: some View {
        Group {
            if let status = coordinator.lastRunStatus,
               let date = coordinator.lastRunDate {
                let fmt: DateFormatter = {
                    let f = DateFormatter()
                    f.dateStyle = .medium; f.timeStyle = .short
                    return f
                }()
                Label(fmt.string(from: date),
                      systemImage: status == .success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundColor(status == .success ? .green : .orange)
            } else {
                Label("No backup yet", systemImage: "externaldrive")
                    .foregroundColor(.secondary)
            }
        }
    }
}
