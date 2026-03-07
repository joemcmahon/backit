import Foundation
import Combine

private func freePort() -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return 5572 }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = INADDR_LOOPBACK
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return 5572 }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &len)
        }
    }
    return Int(addr.sin_port.bigEndian)
}

final class DropboxJob: BackupJob {
    let jobType: JobType = .dropbox
    let progress: CurrentValueSubject<JobProgress, Never>

    private let remoteName: String
    private let volumePath: String
    private let rcPort: Int
    private var process: Process?
    private var pollTask: Task<Void, Never>?

    static func isInstalled() -> Bool {
        ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"].contains {
            let resolved = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            return FileManager.default.fileExists(atPath: resolved)
        }
    }

    init(remoteName: String, volumePath: String, rcPort: Int = freePort()) {
        self.remoteName = remoteName
        self.volumePath = volumePath
        self.rcPort = rcPort
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        killOrphanedRclones()

        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .running))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath())
        proc.arguments = [
            "sync", "\(remoteName):", volumePath.trimmingCharacters(in: .whitespaces),
            "--metadata",
            "--tpslimit", "12", "--tpslimit-burst", "0",
            "-L",
            "--transfers", "8", "--checkers", "8",
            "--rc", "--rc-addr", "localhost:\(rcPort)"
        ]
        print("[DropboxJob] launching: \(rclonePath()) \(proc.arguments?.joined(separator: " ") ?? "")")
        self.process = proc
        try proc.run()

        pollTask = Task { await pollStats() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    continuation.resume()
                }
            }
        } onCancel: {
            proc.terminate()
        }
        pollTask?.cancel()
        self.process = nil

        let jobStatus: JobStatus = proc.terminationStatus == 0 ? .done : .failed
        progress.send(JobProgress(
            fraction: jobStatus == .done ? 1.0 : progress.value.fraction,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: "", status: jobStatus))
    }

    private func killOrphanedRclones() {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "rclone sync"]
        try? killer.run()
        // Don't waitUntilExit — fire-and-forget is fine for pkill
    }

    func cancel() {
        pollTask?.cancel()
        process?.terminate()
        process?.waitUntilExit()
        process = nil
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
        let candidates = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"]
        for path in candidates {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        return "/usr/local/bin/rclone"
    }
}
