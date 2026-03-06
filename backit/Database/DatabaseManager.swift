import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string immediately (safe for Swift Strings)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
    case corrupt(String)
}

final class DatabaseManager {
    private var db: OpaquePointer?

    init(inMemory: Bool = false) throws {
        let path = inMemory ? ":memory:" : try Self.dbPath()
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(msg)
        }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private static func dbPath() throws -> String {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("backit/backit.db")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - Schema

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS backupRun (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            startedAt REAL NOT NULL,
            completedAt REAL,
            status TEXT NOT NULL,
            macosBuild TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS jobResult (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            runId INTEGER NOT NULL REFERENCES backupRun(id) ON DELETE CASCADE,
            jobType TEXT NOT NULL,
            status TEXT NOT NULL,
            bytesTransferred INTEGER NOT NULL,
            bytesTotal INTEGER NOT NULL,
            durationSeconds INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS logLine (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            jobResultId INTEGER NOT NULL REFERENCES jobResult(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL,
            line TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Save

    func save(_ run: inout BackupRun) throws {
        if run.id == nil {
            let sql = """
            INSERT INTO backupRun (startedAt, completedAt, status, macosBuild)
            VALUES (?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_double(stmt, 1, run.startedAt.timeIntervalSince1970)
            bindDouble(stmt, 2, run.completedAt?.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, run.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, run.macosBuild, -1, SQLITE_TRANSIENT)
            try checkDone(sqlite3_step(stmt))
            run.id = sqlite3_last_insert_rowid(db)
        } else {
            let sql = """
            UPDATE backupRun SET startedAt=?, completedAt=?, status=?, macosBuild=?
            WHERE id=?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_double(stmt, 1, run.startedAt.timeIntervalSince1970)
            bindDouble(stmt, 2, run.completedAt?.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, run.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, run.macosBuild, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, run.id!)
            try checkDone(sqlite3_step(stmt))
        }
    }

    func save(_ result: inout JobResult) throws {
        if result.id == nil {
            let sql = """
            INSERT INTO jobResult (runId, jobType, status, bytesTransferred, bytesTotal, durationSeconds)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_int64(stmt, 1, result.runId)
            sqlite3_bind_text(stmt, 2, result.jobType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, result.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, result.bytesTransferred)
            sqlite3_bind_int64(stmt, 5, result.bytesTotal)
            sqlite3_bind_int64(stmt, 6, Int64(result.durationSeconds))
            try checkDone(sqlite3_step(stmt))
            result.id = sqlite3_last_insert_rowid(db)
        } else {
            let sql = """
            UPDATE jobResult SET runId=?, jobType=?, status=?, bytesTransferred=?, bytesTotal=?, durationSeconds=?
            WHERE id=?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_int64(stmt, 1, result.runId)
            sqlite3_bind_text(stmt, 2, result.jobType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, result.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, result.bytesTransferred)
            sqlite3_bind_int64(stmt, 5, result.bytesTotal)
            sqlite3_bind_int64(stmt, 6, Int64(result.durationSeconds))
            sqlite3_bind_int64(stmt, 7, result.id!)
            try checkDone(sqlite3_step(stmt))
        }
    }

    func save(_ line: inout LogLine) throws {
        if line.id == nil {
            let sql = """
            INSERT INTO logLine (jobResultId, timestamp, line)
            VALUES (?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_int64(stmt, 1, line.jobResultId)
            sqlite3_bind_double(stmt, 2, line.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, line.line, -1, SQLITE_TRANSIENT)
            try checkDone(sqlite3_step(stmt))
            line.id = sqlite3_last_insert_rowid(db)
        } else {
            let sql = """
            UPDATE logLine SET jobResultId=?, timestamp=?, line=?
            WHERE id=?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
            sqlite3_bind_int64(stmt, 1, line.jobResultId)
            sqlite3_bind_double(stmt, 2, line.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, line.line, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, line.id!)
            try checkDone(sqlite3_step(stmt))
        }
    }

    // MARK: - Fetch

    func fetchRecentRuns(limit: Int) throws -> [BackupRun] {
        let sql = """
        SELECT id, startedAt, completedAt, status, macosBuild
        FROM backupRun ORDER BY startedAt DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var rows: [BackupRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let completedAt: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let status = RunStatus(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .failed
            let macosBuild = String(cString: sqlite3_column_text(stmt, 4))
            rows.append(BackupRun(id: id, startedAt: startedAt, completedAt: completedAt,
                                  status: status, macosBuild: macosBuild))
        }
        return rows
    }

    func fetchJobResults(forRun runId: Int64) throws -> [JobResult] {
        let sql = """
        SELECT id, runId, jobType, status, bytesTransferred, bytesTotal, durationSeconds
        FROM jobResult WHERE runId=?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        sqlite3_bind_int64(stmt, 1, runId)
        var rows: [JobResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let rId = sqlite3_column_int64(stmt, 1)
            let jobType = JobType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .disk
            let status = JobStatus(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .failed
            let bytesTransferred = sqlite3_column_int64(stmt, 4)
            let bytesTotal = sqlite3_column_int64(stmt, 5)
            let durationSeconds = Int(sqlite3_column_int64(stmt, 6))
            rows.append(JobResult(id: id, runId: rId, jobType: jobType, status: status,
                                  bytesTransferred: bytesTransferred, bytesTotal: bytesTotal,
                                  durationSeconds: durationSeconds))
        }
        return rows
    }

    func fetchLogLines(forJobResult jobResultId: Int64) throws -> [LogLine] {
        let sql = """
        SELECT id, jobResultId, timestamp, line
        FROM logLine WHERE jobResultId=? ORDER BY timestamp
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        sqlite3_bind_int64(stmt, 1, jobResultId)
        var rows: [LogLine] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let jrId = sqlite3_column_int64(stmt, 1)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let line = String(cString: sqlite3_column_text(stmt, 3))
            rows.append(LogLine(id: id, jobResultId: jrId, timestamp: timestamp, line: line))
        }
        return rows
    }

    // MARK: - Prune

    func pruneRuns(keepLast limit: Int) throws {
        let sql = """
        DELETE FROM backupRun
        WHERE id NOT IN (
            SELECT id FROM backupRun ORDER BY startedAt DESC LIMIT ?
        )
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        try checkDone(sqlite3_step(stmt))
    }

    // MARK: - Helpers

    private func checkOK(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func checkDone(_ code: Int32) throws {
        guard code == SQLITE_DONE else {
            throw DatabaseError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let v = value {
            sqlite3_bind_double(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
}
