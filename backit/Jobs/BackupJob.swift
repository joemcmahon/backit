import Foundation
import Combine

struct JobProgress {
    var fraction: Double {
        didSet { fraction = min(1.0, max(0.0, fraction)) }
    }
    var bytesTransferred: Int64
    var bytesTotal: Int64
    var transferRate: String
    var status: JobStatus

    nonisolated init(fraction: Double, bytesTransferred: Int64, bytesTotal: Int64, transferRate: String, status: JobStatus) {
        self.fraction = min(1.0, max(0.0, fraction))
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
        self.transferRate = transferRate
        self.status = status
    }

    nonisolated static let idle = JobProgress(fraction: 0, bytesTransferred: 0, bytesTotal: 0, transferRate: "", status: .idle)
}

struct RcloneStats {
    var listed: Int64 = 0
    var checked: Int64 = 0
    var filesTransferred: Int64 = 0
    var bytesTransferred: Int64 = 0
    var errors: Int = 0
    var rateLimitHits: Int = 0   // subset of errors that are 429s
    var modtimeErrors: Int = 0   // chtimes errors on deleted paths — benign, not transfer failures
    var transientErrors: Int = 0 // directory read failures, march errors — retried by cleanup phase
    var transferRate: String = ""
    var status: JobStatus = .idle

    var lastError: String = ""   // last non-rate-limit, non-modtime ERROR line (for UI/notification)
    var realErrors: Int { max(0, errors - rateLimitHits - modtimeErrors - transientErrors) }
    var onlyRecoverableErrors: Bool { errors > 0 && realErrors == 0 }
    // Verification result: nil = not run, 0 = verified clean, >0 = differences found
    var verificationDifferences: Int? = nil
    var verificationMismatches: [String] = []
    // Verify mode counters (from rclone check --combined)
    var verifyMode: Bool = false
    var verifySame: Int64 = 0
    var verifyMissingFromDest: Int64 = 0    // + in source, missing from dest
    var verifyMissingFromSource: Int64 = 0  // - in dest, missing from source
    var verifyDifferent: Int64 = 0          // * differs
    var verifyCheckErrors: Int64 = 0        // ! read errors (excl. 409s)

    nonisolated static let idle = RcloneStats()
}

protocol BackupJob: AnyObject {
    var jobType: JobType { get }
    var progress: CurrentValueSubject<JobProgress, Never> { get }
    func start() async throws
    func cancel()
}
