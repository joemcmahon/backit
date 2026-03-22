import Foundation
import Combine

@MainActor
final class BackupCoordinator: ObservableObject {
    @Published var isRunning = false
    @Published var currentJobType: JobType?
    @Published var currentProgress: JobProgress = .idle
    @Published var cccProgress: JobProgress = .idle
    @Published var dropboxProgress: JobProgress = .idle
    @Published var icloudProgress: JobProgress = .idle
    @Published var lastRunStatus: RunStatus?
    @Published var lastRunDate: Date?
    @Published var lastRcloneSummary: String?
    @Published var currentJobStartDate: Date?
    @Published var rcloneStats: RcloneStats = .idle
    @Published var icloudStats: RcloneStats = .idle

    private let db: DatabaseManager
    private let settings: BackupSettings
    private let jobFactory: @MainActor (BackupSettings) -> [any BackupJob]
    private var runningTask: Task<Void, Never>?
    private var sleepAssertion: NSObjectProtocol?

    // MARK: - Backup lock file (cross-process mutual exclusion)

    // Written at backup start, removed on completion. Headless instances check this
    // before running to avoid clobbering an active interactive backup.
    static let backupLockFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backit-backup.lock")

    private func writeLockFile() {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? pid.write(to: Self.backupLockFile, atomically: true, encoding: .utf8)
    }

    private func removeLockFile() {
        try? FileManager.default.removeItem(at: Self.backupLockFile)
    }

    private func preventSleep() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Backup in progress"
        )
    }

    private func allowSleep() {
        sleepAssertion = nil  // endActivity called automatically when token deallocates
    }

    init(db: DatabaseManager,
         settings: BackupSettings,
         jobFactory: @escaping @MainActor (BackupSettings) -> [any BackupJob] = BackupCoordinator.defaultFactory) {
        self.db = db
        self.settings = settings
        self.jobFactory = jobFactory
        restoreLastRun()
    }

    private func restoreLastRun() {
        // fetchRecentRuns is a synchronous SQLite read — no async needed here
        guard let run = try? db.fetchRecentRuns(limit: 1).first,
              run.completedAt != nil else { return }
        lastRunDate = run.completedAt
        lastRunStatus = run.status
    }

    static func defaultFactory(_ settings: BackupSettings) -> [any BackupJob] {
        var jobs: [any BackupJob] = []
        if CCCJob.isInstalled() {
            jobs.append(CCCJob(jobType: .disk, taskName: settings.diskCCCTaskName))
        }
        if DropboxJob.isInstalled() && !settings.dropboxRemoteName.isEmpty {
            jobs.append(DropboxJob(remoteName: settings.dropboxRemoteName,
                                   volumePath: settings.dropboxVolumePath,
                                   verify: settings.verifyAfterSync))
        }
        if ICloudJob.isInstalled() && !settings.icloudRemoteName.isEmpty {
            jobs.append(ICloudJob(remoteName: settings.icloudRemoteName,
                                  volumePath: settings.icloudVolumePath,
                                  verify: settings.verifyAfterSync))
        }
        // Bootable clone task disabled until a real CCC bootable task is configured
        // if CCCJob.isInstalled() {
        //     jobs.append(CCCJob(jobType: .bootable, taskName: settings.bootableCCCTaskName))
        // }
        return jobs
    }

    func runBackup() {
        guard !isRunning else { return }
        runningTask = Task { await performBackup() }
    }

    func runVerifyOnly() {
        guard !isRunning else { return }
        runningTask = Task { await performVerification() }
    }

    func runSingleJob(_ jobType: JobType) {
        guard !isRunning else { return }
        runningTask = Task { await performSingleJob(jobType) }
    }

    func recordSkipped() {
        lastRunStatus = .skipped
        lastRunDate = Date()
    }

    func cancelBackup() {
        runningTask?.cancel()
        runningTask = nil
        currentJobType = nil
        // isRunning stays true until performBackup() finishes its cleanup and sets it false.
        // This prevents runBackup() from starting a second backup while the first is still winding down.
    }

    func performVerification() async {
        preventSleep()
        defer { allowSleep() }
        isRunning = true
        rcloneStats = RcloneStats(status: .running)
        currentJobType = .dropbox
        currentJobStartDate = Date()
        let job = DropboxJob(remoteName: settings.dropboxRemoteName,
                             volumePath: settings.dropboxVolumePath,
                             verify: true)
        let statsTask = Task { [weak self] in
            for await stats in job.statsSubject.values {
                self?.rcloneStats = stats
            }
        }
        await job.verifyOnly()
        statsTask.cancel()
        isRunning = false
        currentJobType = nil
        currentJobStartDate = nil
        runningTask = nil
    }

    func performSingleJob(_ targetType: JobType) async {
        preventSleep()
        writeLockFile()
        defer {
            removeLockFile()
            allowSleep()
        }
        isRunning = true
        var run = BackupRun(startedAt: Date(), completedAt: nil,
                            status: .running,
                            macosBuild: MacOSVersionDetector.currentBuild())
        try? db.save(&run)
        guard let runId = run.id else { isRunning = false; return }

        let allJobs = jobFactory(settings)
        guard let job = allJobs.first(where: { $0.jobType == targetType }) else {
            isRunning = false; return
        }

        currentJobType = job.jobType
        let jobStart = Date()
        currentJobStartDate = jobStart

        let progressTask = Task { [weak self] in
            for await p in job.progress.values {
                self?.currentProgress = p
                switch job.jobType {
                case .disk, .bootable: self?.cccProgress = p
                case .dropbox:         self?.dropboxProgress = p
                case .icloud:          self?.icloudProgress = p
                }
            }
        }
        let statsTask: Task<Void, Never>?
        if let dropboxJob = job as? DropboxJob {
            statsTask = Task { [weak self] in
                for await stats in dropboxJob.statsSubject.values { self?.rcloneStats = stats }
            }
        } else if let icloudJob = job as? ICloudJob {
            statsTask = Task { [weak self] in
                for await stats in icloudJob.statsSubject.values { self?.icloudStats = stats }
            }
        } else {
            statsTask = nil
        }

        do { try await job.start() } catch {}

        progressTask.cancel()
        statsTask?.cancel()
        if let dropboxJob = job as? DropboxJob {
            if !dropboxJob.summary.isEmpty { lastRcloneSummary = dropboxJob.summary }
            if let logTime = dropboxJob.lastLogTimestamp { lastRunDate = logTime }
        } else if let icloudJob = job as? ICloudJob {
            if let logTime = icloudJob.lastLogTimestamp { lastRunDate = logTime }
        }

        let fp = job.progress.value
        let duration = Int(Date().timeIntervalSince(jobStart))
        var result = JobResult(runId: runId, jobType: job.jobType,
                               status: fp.status == .done ? .done : .failed,
                               bytesTransferred: fp.bytesTransferred,
                               bytesTotal: fp.bytesTotal,
                               durationSeconds: duration)
        try? db.save(&result)

        run.completedAt = Date()
        run.status = fp.status == .done ? .success : .failed
        try? db.save(&run)

        lastRunStatus = run.status
        lastRunDate = Date()
        isRunning = false
        currentJobType = nil
        currentJobStartDate = nil
        currentProgress = .idle
        switch targetType {
        case .disk, .bootable: cccProgress = .idle
        case .dropbox:         dropboxProgress = .idle; rcloneStats = .idle
        case .icloud:          icloudProgress = .idle; icloudStats = .idle
        }
        runningTask = nil
    }

    // Internal — also called directly by tests
    func performBackup() async {
        preventSleep()
        writeLockFile()
        defer {
            removeLockFile()
            allowSleep()
        }
        isRunning = true
        rcloneStats = .idle

        let currentUUID = MacOSVersionDetector.hardwareUUID()
        if !settings.storedMachineUUID.isEmpty,
           settings.storedMachineUUID != currentUUID {
            // UI layer handles warning alert via lastRunStatus observation
        }

        var run = BackupRun(startedAt: Date(), completedAt: nil,
                            status: .running,
                            macosBuild: MacOSVersionDetector.currentBuild())
        try? db.save(&run)
        guard let runId = run.id else {
            isRunning = false; return
        }

        let jobs = jobFactory(settings)
        var anyFailed = false
        var anySucceeded = false

        // Mark all jobs after the first as "waiting" so the UI doesn't show blank progress
        let waiting = JobProgress(fraction: 0, bytesTransferred: 0, bytesTotal: 0,
                                  transferRate: "Waiting…", status: .idle)
        for job in jobs.dropFirst() {
            switch job.jobType {
            case .disk, .bootable: cccProgress = waiting
            case .dropbox:         dropboxProgress = waiting
            case .icloud:          icloudProgress = waiting
            }
        }

        for job in jobs {
            guard !Task.isCancelled else { break }
            currentJobType = job.jobType
            let jobStart = Date()
            currentJobStartDate = jobStart

            // Forward live progress into coordinator's published properties
            let progressTask = Task { [weak self] in
                for await p in job.progress.values {
                    self?.currentProgress = p
                    switch job.jobType {
                    case .disk, .bootable: self?.cccProgress = p
                    case .dropbox:         self?.dropboxProgress = p
                    case .icloud:          self?.icloudProgress = p
                    }
                }
            }
            let statsTask: Task<Void, Never>?
            if let dropboxJob = job as? DropboxJob {
                statsTask = Task { [weak self] in
                    for await stats in dropboxJob.statsSubject.values {
                        self?.rcloneStats = stats
                    }
                }
            } else if let icloudJob = job as? ICloudJob {
                statsTask = Task { [weak self] in
                    for await stats in icloudJob.statsSubject.values {
                        self?.icloudStats = stats
                    }
                }
            } else {
                statsTask = nil
            }

            do {
                try await job.start()
            } catch {
                // Cancellation and job errors are reflected in job.progress.value.status
            }

            progressTask.cancel()
            statsTask?.cancel()
            if let dropboxJob = job as? DropboxJob {
                if !dropboxJob.summary.isEmpty { lastRcloneSummary = dropboxJob.summary }
                if let logTime = dropboxJob.lastLogTimestamp { lastRunDate = logTime }
            } else if let icloudJob = job as? ICloudJob {
                if let logTime = icloudJob.lastLogTimestamp { lastRunDate = logTime }
            }
            let fp = job.progress.value
            let duration = Int(Date().timeIntervalSince(jobStart))
            var result = JobResult(runId: runId,
                                   jobType: job.jobType,
                                   status: fp.status == .done ? .done : .failed,
                                   bytesTransferred: fp.bytesTransferred,
                                   bytesTotal: fp.bytesTotal,
                                   durationSeconds: duration)
            try? db.save(&result)

            if fp.status == .done { anySucceeded = true } else { anyFailed = true }
        }

        let overallStatus: RunStatus
        if jobs.isEmpty || anySucceeded && !anyFailed { overallStatus = .success }
        else if anySucceeded { overallStatus = .partial }
        else { overallStatus = .failed }

        run.completedAt = Date()
        run.status = overallStatus
        try? db.save(&run)

        if settings.storedMachineUUID.isEmpty {
            settings.storedMachineUUID = currentUUID
        }
        try? db.pruneRuns(keepLast: settings.historyLimit)

        lastRunStatus = overallStatus
        lastRunDate = Date()
        isRunning = false
        currentJobType = nil
        currentJobStartDate = nil
        cccProgress = .idle
        dropboxProgress = .idle
        icloudProgress = .idle
        currentProgress = .idle
        rcloneStats = .idle
        icloudStats = .idle
        runningTask = nil
    }
}
