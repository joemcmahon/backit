import Foundation
import Combine

@MainActor
final class BackupCoordinator: ObservableObject {
    @Published var isRunning = false
    @Published var currentJobType: JobType?
    @Published var currentProgress: JobProgress = .idle
    @Published var lastRunStatus: RunStatus?
    @Published var lastRunDate: Date?

    private let db: DatabaseManager
    private let settings: BackupSettings
    private let jobFactory: (BackupSettings) -> [any BackupJob]
    private var runningTask: Task<Void, Never>?

    init(db: DatabaseManager,
         settings: BackupSettings,
         jobFactory: @escaping (BackupSettings) -> [any BackupJob] = BackupCoordinator.defaultFactory) {
        self.db = db
        self.settings = settings
        self.jobFactory = jobFactory
    }

    static func defaultFactory(_ settings: BackupSettings) -> [any BackupJob] {
        var jobs: [any BackupJob] = []
        if CCCJob.isInstalled() {
            jobs.append(CCCJob(jobType: .disk, taskName: settings.diskCCCTaskName))
        }
        if DropboxJob.isInstalled() {
            jobs.append(DropboxJob(remoteName: settings.dropboxRemoteName,
                                   volumePath: settings.dropboxVolumePath))
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

    func cancelBackup() {
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        currentJobType = nil
    }

    // Internal — also called directly by tests
    func performBackup() async {
        isRunning = true

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

        for job in jobs {
            currentJobType = job.jobType
            let jobStart = Date()

            // Forward live progress into coordinator's published property
            let progressTask = Task { [weak self] in
                for await p in job.progress.values {
                    self?.currentProgress = p
                }
            }

            do {
                try await job.start()
            } catch {
                print("[BackupCoordinator] \(job.jobType) failed: \(error)")
            }

            progressTask.cancel()
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
        currentProgress = .idle
        runningTask = nil
    }
}
