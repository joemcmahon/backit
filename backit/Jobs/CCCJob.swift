import Foundation
import Combine

// Injectable protocol so tests never invoke the real CCC CLI
protocol CCCCLIRunner: AnyObject {
    func runTask(named name: String, progressHandler: @escaping (Double) -> Void) async throws -> Int32
    func stopTask(named name: String)
}

final class DefaultCCCCLIRunner: CCCCLIRunner {
    static let cliPath = "/Applications/Carbon Copy Cloner.app/Contents/MacOS/ccc"

    func runTask(named name: String, progressHandler: @escaping (Double) -> Void) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.cliPath)
        proc.arguments = ["--start=\(name)", "--watch"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                if let pct = Self.percentFrom(line) { progressHandler(pct) }
            }
        }

        try proc.run()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                continuation.resume()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return proc.terminationStatus
    }

    func stopTask(named name: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.cliPath)
        proc.arguments = ["--stop=\(name)"]
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func percentFrom(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[range]).map { $0 / 100.0 }
    }
}

final class CCCJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>

    private let taskName: String
    private let runner: CCCCLIRunner

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Carbon Copy Cloner.app")
    }

    init(jobType: JobType, taskName: String, runner: CCCCLIRunner = DefaultCCCCLIRunner()) {
        self.jobType = jobType
        self.taskName = taskName
        self.runner = runner
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .running))

        let exitCode = try await runner.runTask(named: taskName) { [weak self] pct in
            self?.progress.send(JobProgress(fraction: pct, bytesTransferred: 0,
                                            bytesTotal: 0, transferRate: "", status: .running))
        }

        let jobStatus: JobStatus = exitCode == 0 ? .done : .failed
        progress.send(JobProgress(
            fraction: jobStatus == .done ? 1.0 : progress.value.fraction,
            bytesTransferred: 0, bytesTotal: 0,
            transferRate: "", status: jobStatus))
    }

    func cancel() {
        runner.stopTask(named: taskName)
        progress.send(JobProgress(
            fraction: progress.value.fraction,
            bytesTransferred: 0, bytesTotal: 0,
            transferRate: "", status: .failed))
    }
}
