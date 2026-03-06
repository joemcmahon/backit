import Foundation
import Combine

// Injectable protocol so tests never invoke real AppleScript
protocol AppleScriptRunner: AnyObject {
    func run(script: String) throws -> String
}

final class DefaultAppleScriptRunner: AppleScriptRunner {
    func run(script: String) throws -> String {
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return "" }
        let result = appleScript.executeAndReturnError(&errorDict)
        if let err = errorDict {
            throw NSError(domain: "AppleScript", code: -1,
                          userInfo: err as? [String: Any])
        }
        return result.stringValue ?? ""
    }
}

final class CCCJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>

    private let taskName: String
    private let scriptRunner: AppleScriptRunner

    private var escapedTaskName: String {
        taskName.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Carbon Copy Cloner.app")
    }

    init(jobType: JobType, taskName: String,
         scriptRunner: AppleScriptRunner = DefaultAppleScriptRunner()) {
        self.jobType = jobType
        self.taskName = taskName
        self.scriptRunner = scriptRunner
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .running))

        let startScript = """
        tell application "Carbon Copy Cloner"
            run task named "\(escapedTaskName)"
        end tell
        """
        try scriptRunner.run(script: startScript)

        while true {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch is CancellationError {
                progress.send(JobProgress(
                    fraction: progress.value.fraction,
                    bytesTransferred: 0, bytesTotal: 0,
                    transferRate: "", status: .failed))
                throw CancellationError()
            }

            let pctScript = """
            tell application "Carbon Copy Cloner"
                get percent complete of task named "\(escapedTaskName)"
            end tell
            """
            let statusScript = """
            tell application "Carbon Copy Cloner"
                get status of task named "\(escapedTaskName)"
            end tell
            """

            let cccStatus = (try? scriptRunner.run(script: statusScript)) ?? ""
            let pct = Double((try? scriptRunner.run(script: pctScript)) ?? "") ?? 0

            // Only treat explicit terminal states as terminal
            if cccStatus == "Success" || cccStatus == "Failed" || cccStatus == "Aborted" {
                let jobStatus: JobStatus = cccStatus == "Success" ? .done : .failed
                progress.send(JobProgress(
                    fraction: jobStatus == .done ? 1.0 : pct / 100.0,
                    bytesTransferred: 0, bytesTotal: 0,
                    transferRate: "", status: jobStatus))
                return
            }

            progress.send(JobProgress(fraction: pct / 100.0, bytesTransferred: 0,
                                      bytesTotal: 0, transferRate: "", status: .running))
        }
    }

    func cancel() {
        let script = """
        tell application "Carbon Copy Cloner"
            abort task named "\(escapedTaskName)"
        end tell
        """
        try? scriptRunner.run(script: script)
        progress.send(JobProgress(
            fraction: progress.value.fraction,
            bytesTransferred: 0, bytesTotal: 0,
            transferRate: "", status: .failed))
    }
}
