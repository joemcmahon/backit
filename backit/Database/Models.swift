import Foundation

enum RunStatus: String {
    case running, success, partial, failed, skipped
}

enum JobType: String {
    case disk, dropbox, bootable
}

enum JobStatus: String {
    case idle, running, done, failed, skipped
}

struct BackupRun {
    var id: Int64?
    var startedAt: Date
    var completedAt: Date?
    var status: RunStatus
    var macosBuild: String
}

struct JobResult {
    var id: Int64?
    var runId: Int64
    var jobType: JobType
    var status: JobStatus
    var bytesTransferred: Int64
    var bytesTotal: Int64
    var durationSeconds: Int
    var completedAt: Date? = nil
}

struct LogLine {
    var id: Int64?
    var jobResultId: Int64
    var timestamp: Date
    var line: String
}
