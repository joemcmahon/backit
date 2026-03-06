import Foundation
import Combine

final class DropboxJob: BackupJob {
    let jobType: JobType = .dropbox
    let progress: CurrentValueSubject<JobProgress, Never>

    private let remoteName: String
    private let volumePath: String
    private let rcPort: Int
    private var process: Process?
    private var pollTask: Task<Void, Never>?

    static func isInstalled() -> Bool {
        ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    init(remoteName: String, volumePath: String, rcPort: Int = 5572) {
        self.remoteName = remoteName
        self.volumePath = volumePath
        self.rcPort = rcPort
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .running))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath())
        proc.arguments = [
            "sync", "\(remoteName):", volumePath,
            "--metadata",
            "--tpslimit", "12", "--tpslimit-burst", "0",
            "-L",
            "--transfers", "8", "--checkers", "8",
            "--rc", "--rc-addr", "localhost:\(rcPort)"
        ]
        self.process = proc
        try proc.run()

        pollTask = Task { await pollStats() }
        proc.waitUntilExit()
        pollTask?.cancel()

        let jobStatus: JobStatus = proc.terminationStatus == 0 ? .done : .failed
        progress.send(JobProgress(
            fraction: jobStatus == .done ? 1.0 : progress.value.fraction,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: "", status: jobStatus))
    }

    func cancel() {
        pollTask?.cancel()
        process?.terminate()
        progress.send(JobProgress(
            fraction: progress.value.fraction,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: "", status: .failed))
    }

    private func pollStats() async {
        let url = URL(string: "http://localhost:\(rcPort)/core/stats")!
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { break }
            if let data = try? await URLSession.shared.data(from: url).0,
               let stats = try? RcloneStatsParser.parse(data: data) {
                progress.send(JobProgress(
                    fraction: stats.fraction,
                    bytesTransferred: stats.bytesTransferred,
                    bytesTotal: stats.bytesTotal,
                    transferRate: stats.transferRate,
                    status: .running))
            }
        }
    }

    private func rclonePath() -> String {
        ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"]
            .first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/local/bin/rclone"
    }
}
