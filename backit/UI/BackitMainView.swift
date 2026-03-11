import SwiftUI
import AppKit

struct BackitMainView: View {
    @ObservedObject var coordinator: BackupCoordinator
    @ObservedObject var settings: BackupSettings
    let db: DatabaseManager

    @State private var cccTasks: [CCCTaskEntry] = []
    @State private var rcloneRemotes: [String] = []
    @State private var showScheduleSheet = false
    @State private var showRcloneSummary = false
    @State private var showVerifyResults = false
    @State private var optionHeld = false

    var body: some View {
        VStack(spacing: 0) {
            // CCC section
            JobSectionView(
                title: "Internal disk (CCC)",
                systemImage: "externaldrive.fill",
                sourcePicker: { AnyView(cccTaskPicker) },
                destPicker: { AnyView(cccVolumePicker) },
                progress: coordinator.cccProgress,
                startDate: coordinator.currentJobType == .disk ? coordinator.currentJobStartDate : nil
            )

            Divider().padding(.horizontal)

            // rclone section
            RcloneStatusView(
                sourcePicker: { AnyView(rcloneRemotePicker) },
                destPicker: { AnyView(rcloneFolderPicker) },
                stats: coordinator.rcloneStats,
                startDate: coordinator.currentJobType == .dropbox ? coordinator.currentJobStartDate : nil
            )

            Divider()

            // Bottom bar
            HStack {
                if let date = coordinator.lastRunDate, let status = coordinator.lastRunStatus {
                    let fmt = DateFormatter()
                    let _ = { fmt.dateStyle = .medium; fmt.timeStyle = .short }()
                    Label(fmt.string(from: date),
                          systemImage: status == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(status == .success ? .green : .orange)
                        .font(.caption)
                } else {
                    Text("No backup yet").font(.caption).foregroundColor(.secondary)
                }

                Spacer()

                if coordinator.lastRcloneSummary != nil {
                    Button("Details") { showRcloneSummary = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .sheet(isPresented: $showRcloneSummary) {
                            RcloneSummarySheet(summary: coordinator.lastRcloneSummary ?? "")
                        }
                }

                Button {
                    showScheduleSheet = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .sheet(isPresented: $showScheduleSheet) {
                    ScheduleSheetView(settings: settings)
                }

                if coordinator.isRunning {
                    Button("Stop") { coordinator.cancelBackup() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button(optionHeld ? "Verify Backup" : "Run Backup") {
                        if optionHeld { coordinator.runVerifyOnly() }
                        else { coordinator.runBackup() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(optionHeld ? .purple : .accentColor)
                }
            }
            .padding()
        }
        .frame(width: 560)
        .task { await loadRemoteData() }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionHeld = event.modifierFlags.contains(.option)
                return event
            }
        }
        .sheet(isPresented: $showVerifyResults) {
            VerifyResultsSheet(stats: coordinator.rcloneStats)
        }
        .onChange(of: coordinator.rcloneStats.verificationDifferences) { _, diff in
            if let diff, diff > 0 { showVerifyResults = true }
        }
    }

    // MARK: - CCC pickers

    private var cccTaskPicker: some View {
        Menu(settings.diskCCCTaskName.isEmpty ? "Select CCC Task…" : settings.diskCCCTaskName) {
            if cccTasks.isEmpty {
                Text("No tasks found").foregroundColor(.secondary)
            }
            ForEach(cccTasks) { task in
                Button(task.name) { settings.diskCCCTaskName = task.name }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var cccVolumePicker: some View {
        Button("Configure in CCC…") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Carbon Copy Cloner.app"))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - rclone pickers

    private var rcloneRemotePicker: some View {
        Menu(settings.dropboxRemoteName.isEmpty ? "Select Remote…" : settings.dropboxRemoteName) {
            if rcloneRemotes.isEmpty {
                Text("No remotes found").foregroundColor(.secondary)
            }
            ForEach(rcloneRemotes, id: \.self) { remote in
                Button(remote) { settings.dropboxRemoteName = remote }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rcloneFolderPicker: some View {
        Button(settings.dropboxVolumePath.isEmpty ? "Select Folder…" : abbreviatedPath(settings.dropboxVolumePath)) {
            pickFolder { settings.dropboxVolumePath = $0 }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func loadRemoteData() async {
        cccTasks = await CCCTaskLoader.load()
        rcloneRemotes = await RcloneRemoteLoader.load()
    }

    private func pickFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Job section

struct JobSectionView: View {
    let title: String
    let systemImage: String
    let sourcePicker: () -> AnyView
    let destPicker: () -> AnyView
    let progress: JobProgress
    var startDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            HStack(spacing: 8) {
                sourcePicker()
                destPicker()
            }

            HStack(spacing: 8) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: .infinity)
                Text(progressLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            HStack {
                if progress.status == .running, !progress.transferRate.isEmpty {
                    Text(progress.transferRate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if progress.status == .running, let startDate {
                    TimelineView(.periodic(from: startDate, by: 1.0)) { context in
                        Text(elapsed(from: startDate, to: context.date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("--:--")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding()
    }

    private var progressLabel: String {
        switch progress.status {
        case .idle: return progress.transferRate.isEmpty ? "—" : progress.transferRate
        case .running: return "\(Int(progress.fraction * 100))%"
        case .done: return "✓"
        case .failed: return "✗"
        case .skipped: return "•"
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let s = Int(now.timeIntervalSince(start))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Schedule sheet

struct ScheduleSheetView: View {
    @ObservedObject var settings: BackupSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
            Section("Schedule") {
                DatePicker("Backup time", selection: $settings.backupTime,
                           displayedComponents: .hourAndMinute)
                DatePicker("Backup reminder", selection: $settings.backupReminderTime,
                           displayedComponents: .hourAndMinute)
                DatePicker("Preflight warning", selection: $settings.preflightWarningTime,
                           displayedComponents: .hourAndMinute)
            }
            Section("History") {
                Stepper("Keep \(settings.historyLimit) run\(settings.historyLimit == 1 ? "" : "s")",
                        value: $settings.historyLimit, in: 1...10)
            }
            Section("Tonight") {
                Toggle("Skip tonight's backup", isOn: $settings.skipTonight)
            }
            Section("Verification") {
                Toggle("Verify backup after sync", isOn: $settings.verifyAfterSync)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 460)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - Rclone stats panel

struct RcloneStatusView: View {
    let sourcePicker: () -> AnyView
    let destPicker: () -> AnyView
    let stats: RcloneStats
    var startDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(stats.verifyMode ? "Dropbox (rclone check)" : "Dropbox (rclone)",
                  systemImage: stats.verifyMode ? "checkmark.shield" : "arrow.triangle.2.circlepath")
                .font(.headline)

            HStack(spacing: 8) {
                sourcePicker()
                destPicker()
            }

            if stats.verifyMode {
                HStack(spacing: 0) {
                    StatCell(label: "Same", value: stats.status == .idle ? "—" : formatCount(stats.verifySame))
                    StatCell(label: "Missing↓", value: stats.status == .idle ? "—" : formatCount(stats.verifyMissingFromDest))
                    StatCell(label: "Missing↑", value: stats.status == .idle ? "—" : formatCount(stats.verifyMissingFromSource))
                    StatCell(label: "Differs", value: stats.status == .idle ? "—" : formatCount(stats.verifyDifferent))
                    StatCell(label: "Errors", value: stats.status == .idle ? "—" : "\(stats.verifyCheckErrors)")
                }
            } else {
                HStack(spacing: 0) {
                    StatCell(label: "Listed", value: stats.status == .idle ? "—" : formatCount(stats.listed))
                    StatCell(label: "Checked", value: stats.status == .idle ? "—" : formatCount(stats.checked))
                    StatCell(label: "Copied", value: stats.status == .idle ? "—" : formatCount(stats.filesTransferred))
                    StatCell(label: "Errors", value: stats.status == .idle ? "—" : "\(stats.realErrors)")
                }
            }

            HStack {
                if stats.status == .running, stats.bytesTransferred > 0 {
                    Text("\(formatBytes(stats.bytesTransferred)) · \(stats.transferRate)")
                        .font(.caption2).foregroundColor(.secondary)
                } else if stats.status == .done {
                    Text(stats.onlyRateLimitErrors
                         ? "Done — \(stats.rateLimitHits) rate limit hit\(stats.rateLimitHits == 1 ? "" : "s")"
                         : stats.realErrors > 0
                             ? "Done — \(stats.realErrors) error\(stats.realErrors == 1 ? "" : "s")"
                             : "Complete")
                        .font(.caption2)
                        .foregroundColor(stats.realErrors > 0 ? .orange : .secondary)
                } else if stats.status == .failed {
                    Text("Failed").font(.caption2).foregroundColor(.red)
                } else if let diff = stats.verificationDifferences, stats.status == .done {
                    Text(diff == 0 ? "Verified ✓" : "⚠ \(diff) difference\(diff == 1 ? "" : "s") found")
                        .font(.caption2)
                        .foregroundColor(diff == 0 ? .green : .orange)
                } else {
                    Text(" ").font(.caption2)
                }
                Spacer()
                if stats.status == .running, let startDate {
                    TimelineView(.periodic(from: startDate, by: 1.0)) { context in
                        Text(elapsed(from: startDate, to: context.date))
                            .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                    }
                } else {
                    Text("--:--").font(.caption2).foregroundColor(.secondary).monospacedDigit()
                }
            }
        }
        .padding()
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let s = Int(now.timeIntervalSince(start))
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func formatCount(_ n: Int64) -> String {
        let fmt = NumberFormatter(); fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatBytes(_ n: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = Double(n); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
}

struct StatCell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced)).monospacedDigit()
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rclone summary sheet

struct RcloneSummarySheet: View {
    let summary: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rclone Summary")
                .font(.headline)

            ScrollView {
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)

            HStack {
                Button("Open Full Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: DropboxJob.logFilePath))
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 440)
    }
}

// MARK: - Verify results sheet

struct VerifyResultsSheet: View {
    let stats: RcloneStats
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: stats.verificationDifferences == 0
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(stats.verificationDifferences == 0 ? .green : .orange)
                Text(stats.verificationDifferences == 0
                     ? "Backup Verified"
                     : "\(stats.verificationDifferences ?? 0) Difference\((stats.verificationDifferences ?? 0) == 1 ? "" : "s") Found")
                    .font(.headline)
            }

            if stats.verificationMismatches.isEmpty {
                Text("All files in Dropbox match the backup destination.")
                    .foregroundColor(.secondary)
            } else {
                Text("Files that differ between Dropbox and backup:")
                    .font(.caption).foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stats.verificationMismatches, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - Data models

struct CCCTaskEntry: Identifiable {
    let id: String   // UUID from ccc --uuids
    let name: String
}
