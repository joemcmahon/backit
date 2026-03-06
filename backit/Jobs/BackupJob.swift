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

    init(fraction: Double, bytesTransferred: Int64, bytesTotal: Int64, transferRate: String, status: JobStatus) {
        self.fraction = min(1.0, max(0.0, fraction))
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
        self.transferRate = transferRate
        self.status = status
    }

    static let idle = JobProgress(fraction: 0, bytesTransferred: 0, bytesTotal: 0, transferRate: "", status: .idle)
}

protocol BackupJob: AnyObject {
    var jobType: JobType { get }
    var progress: CurrentValueSubject<JobProgress, Never> { get }
    func start() async throws
    func cancel()
}
