import Foundation
@preconcurrency import Combine

final class ICloudJob: BackupJob {
    let jobType: JobType = .icloud
    let progress: CurrentValueSubject<JobProgress, Never>

    private let remoteName: String
    private let volumePath: String
    private let verify: Bool
    private var process: Process?
    // nonisolated(unsafe): only mutated from the serial readability handler + start() (safe by construction)
    nonisolated(unsafe) private var failedPaths: [String] = []
    nonisolated(unsafe) private var failedDirectories: [String] = []
    nonisolated(unsafe) private var statsBuffer: [String] = []   // last 12 lines — summary sheet
    nonisolated(unsafe) private var logFileHandle: FileHandle? = nil
    nonisolated(unsafe) private var currentStats = RcloneStats.idle
    nonisolated(unsafe) private(set) var lastLogTimestamp: Date? = nil
    let statsSubject = CurrentValueSubject<RcloneStats, Never>(.idle)
    private(set) var summary: String = ""

    static let logFilePath = "/tmp/backit-icloud-rclone.log"

    nonisolated static func isInstalled() -> Bool {
        ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"].contains {
            let resolved = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            return FileManager.default.fileExists(atPath: resolved)
        }
    }

    init(remoteName: String, volumePath: String, verify: Bool = true) {
        self.remoteName = remoteName
        self.volumePath = volumePath
        self.verify = verify
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        killOrphanedRclones()
        failedPaths = []
        failedDirectories = []
        statsBuffer = []
        summary = ""
        currentStats = RcloneStats(status: .running)
        statsSubject.send(currentStats)
        FileManager.default.createFile(atPath: Self.logFilePath, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: Self.logFilePath)

        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "Starting…", status: .running))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath())
        proc.arguments = [
            "sync", "\(remoteName):", volumePath.trimmingCharacters(in: .whitespaces),
            "--ignore-size",        // iCloud API reports uncompressed bundle sizes; delivered files are compressed
            "--fast-list",
            "--tpslimit", "12", "--tpslimit-burst", "0",
            "--transfers", "4", "--checkers", "4",
            "--retries", "1", "--low-level-retries", "1",
            "--ignore-errors",
            "--stats", "2s", "--stats-log-level", "NOTICE"
        ]

        let pipe = Pipe()
        proc.standardError = pipe

        let progressSubject = self.progress
        let statsRef = self.statsSubject
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    self?.statsBuffer.append(trimmed)
                    if (self?.statsBuffer.count ?? 0) > 12 { self?.statsBuffer.removeFirst() }
                }
                if let lineData = (line + "\n").data(using: .utf8) {
                    self?.logFileHandle?.write(lineData)
                }
                if let ts = RcloneStatsParser.parseTimestamp(line) {
                    self?.lastLogTimestamp = ts
                }
                if var stats = self?.currentStats {
                    if RcloneStatsParser.updateStats(&stats, from: line) {
                        self?.currentStats = stats
                        statsRef.send(stats)
                    }
                }
                if let update = RcloneStatsParser.parseLine(line) {
                    progressSubject.send(update)
                } else if let failedDir = RcloneStatsParser.parseDirectoryError(line) {
                    self?.failedDirectories.append(failedDir)
                } else if let failedPath = RcloneStatsParser.parseError(line) {
                    self?.failedPaths.append(failedPath)
                }
            }
        }

        self.process = proc
        try proc.run()

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

        pipe.fileHandleForReading.readabilityHandler = nil
        // Drain any output buffered in the pipe that the handler didn't process before exit.
        // Without this, a fast-failing rclone (e.g. auth error in <2s) produces an empty log.
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    statsBuffer.append(trimmed)
                    if statsBuffer.count > 12 { statsBuffer.removeFirst() }
                }
                if let lineData = (line + "\n").data(using: .utf8) { logFileHandle?.write(lineData) }
                if let ts = RcloneStatsParser.parseTimestamp(line) { lastLogTimestamp = ts }
                if RcloneStatsParser.updateStats(&currentStats, from: line) { statsSubject.send(currentStats) }
                if let update = RcloneStatsParser.parseLine(line) {
                    progress.send(update)
                } else if let failedDir = RcloneStatsParser.parseDirectoryError(line) {
                    failedDirectories.append(failedDir)
                } else if let failedPath = RcloneStatsParser.parseError(line) {
                    failedPaths.append(failedPath)
                }
            }
        }
        self.process = nil
        logFileHandle?.closeFile()
        logFileHandle = nil
        summary = statsBuffer.joined(separator: "\n")

        guard !Task.isCancelled else { return }
        let persistentlyFailed = await retryFailedPaths(failedPaths)
        guard !Task.isCancelled else { return }
        await cleanupFailedDirectories(failedDirectories)
        if verify && !Task.isCancelled { await runVerification() }
        let succeeded = proc.terminationStatus == 0 || currentStats.onlyRateLimitErrors
        currentStats.status = (succeeded || !persistentlyFailed.isEmpty) ? .done : .failed
        statsSubject.send(currentStats)
        let rateText: String
        if !persistentlyFailed.isEmpty {
            rateText = "Done — \(persistentlyFailed.count) file\(persistentlyFailed.count == 1 ? "" : "s") skipped"
        } else if succeeded && currentStats.rateLimitHits > 0 {
            rateText = "Done — \(currentStats.rateLimitHits) rate limit hit\(currentStats.rateLimitHits == 1 ? "" : "s")"
        } else if succeeded {
            rateText = "Complete"
        } else {
            rateText = "Failed"
        }
        let finalStatus: JobStatus = (succeeded || !persistentlyFailed.isEmpty) ? .done : .failed
        progress.send(JobProgress(
            fraction: finalStatus == .done ? 1.0 : progress.value.fraction,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: rateText,
            status: finalStatus))
    }

    func cancel() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        progress.send(JobProgress(
            fraction: progress.value.fraction,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: "Cancelled",
            status: .failed))
    }

    func verifyOnly() async {
        currentStats = RcloneStats(status: .running)
        currentStats.verifyMode = true
        statsSubject.send(currentStats)
        await runVerification()
        currentStats.status = .done
        statsSubject.send(currentStats)
    }

    private func runVerification() async {
        killOrphanedRclones(matching: "rclone check")
        progress.send(JobProgress(
            fraction: 1.0,
            bytesTransferred: progress.value.bytesTransferred,
            bytesTotal: progress.value.bytesTotal,
            transferRate: "Verifying…",
            status: .running))
        currentStats.verificationDifferences = nil
        currentStats.verifyMode = true
        statsSubject.send(currentStats)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath())
        let checkReportPath = "/tmp/backit-icloud-check.txt"
        FileManager.default.createFile(atPath: checkReportPath, contents: nil)
        proc.arguments = [
            "check",
            "\(remoteName):", volumePath.trimmingCharacters(in: .whitespaces),
            "--one-way",
            "--ignore-size",        // must match sync: iCloud bundle sizes differ after compression
            "--fast-list",
            "--tpslimit", "12", "--tpslimit-burst", "0",
            "--checkers", "4",
            "--stats", "2s", "--stats-log-level", "NOTICE",
            "--combined", checkReportPath
        ]

        proc.standardError = Pipe()

        guard (try? proc.run()) != nil else { return }

        let pollTask = Task { [weak self] in
            var offset: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                if let fh = FileHandle(forReadingAtPath: checkReportPath) {
                    try? fh.seek(toOffset: offset)
                    let data = fh.readDataToEndOfFile()
                    fh.closeFile()
                    offset += UInt64(data.count)
                    if var stats = self?.currentStats,
                       let text = String(data: data, encoding: .utf8) {
                        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                            switch line.prefix(1) {
                            case "=": stats.verifySame += 1
                            case "+": stats.verifyMissingFromDest += 1
                            case "-": stats.verifyMissingFromSource += 1
                            case "*": stats.verifyDifferent += 1
                            case "!":
                                if !line.contains("too_many_requests") {
                                    stats.verifyCheckErrors += 1
                                }
                            default: break
                            }
                        }
                        self?.currentStats = stats
                        self?.statsSubject.send(stats)
                    }
                }
            }
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                continuation.resume()
            }
        }
        pollTask.cancel()

        let reportText = (try? String(contentsOfFile: checkReportPath, encoding: .utf8)) ?? ""
        let mismatches = reportText.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("=") && !$0.contains("too_many_requests") }
            .map { line -> String in
                let flag = line.prefix(1)
                let path = line.dropFirst(2)
                switch flag {
                case "+": return "+ \(path)  (missing from backup)"
                case "-": return "- \(path)  (missing from source)"
                case "*": return "* \(path)  (differs)"
                case "!": return "! \(path)  (read error)"
                default:  return String(line)
                }
            }
        currentStats.verificationMismatches = mismatches
        currentStats.verificationDifferences = proc.terminationStatus == 0 ? 0 : mismatches.count
        statsSubject.send(currentStats)
    }

    private func cleanupFailedDirectories(_ dirs: [String]) async {
        guard !dirs.isEmpty else { return }
        let unique = Array(Set(dirs)).sorted()
        let dest = volumePath.trimmingCharacters(in: .whitespaces)
        for (i, dir) in unique.enumerated() {
            let count = unique.count
            progress.send(JobProgress(
                fraction: 1.0,
                bytesTransferred: progress.value.bytesTransferred,
                bytesTotal: progress.value.bytesTotal,
                transferRate: "Cleanup phase: \(i + 1)/\(count)",
                status: .running))
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: rclonePath())
            proc.arguments = [
                "sync", "\(remoteName):\(dir)", "\(dest)/\(dir)",
                "--ignore-size",
                "--tpslimit", "12", "--tpslimit-burst", "0",
                "--retries", "2", "--low-level-retries", "2",
                "--stats", "2s", "--stats-log-level", "NOTICE",
                "--ignore-errors"
            ]
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { continue }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    continuation.resume()
                }
            }
        }
    }

    private func retryFailedPaths(_ paths: [String]) async -> [String] {
        guard !paths.isEmpty else { return [] }
        var remaining = paths
        for attempt in 1...2 {
            guard !remaining.isEmpty else { break }
            let count = remaining.count
            progress.send(JobProgress(
                fraction: 1.0,
                bytesTransferred: progress.value.bytesTransferred,
                bytesTotal: progress.value.bytesTotal,
                transferRate: "Retrying \(count) file\(count == 1 ? "" : "s")… (pass \(attempt))",
                status: .running))

            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rclone-icloud-retry-\(attempt).txt")
            try? remaining.joined(separator: "\n").write(to: tmpURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: rclonePath())
            proc.arguments = [
                "copy",
                "--files-from", tmpURL.path,
                "\(remoteName):", volumePath.trimmingCharacters(in: .whitespaces),
                "--ignore-size",
                "--retries", "1", "--low-level-retries", "1",
                "--stats", "2s"
            ]
            let errPipe = Pipe()
            proc.standardError = errPipe
            guard (try? proc.run()) != nil else { break }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    continuation.resume()
                }
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            remaining = errText.components(separatedBy: .newlines)
                .compactMap { RcloneStatsParser.parseError($0) }
        }
        return remaining
    }

    private func killOrphanedRclones(matching pattern: String = "rclone") {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", pattern]
        try? killer.run()
        killer.waitUntilExit()
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
