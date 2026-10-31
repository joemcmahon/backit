import XCTest
import SQLite3
@testable import backit

final class DatabaseTests: XCTestCase {
    var dbManager: DatabaseManager!

    override func setUp() {
        super.setUp()
        dbManager = try! DatabaseManager(inMemory: true)
    }

    func testCanInsertAndFetchRun() throws {
        var run = BackupRun(
            startedAt: Date(),
            completedAt: nil,
            status: .running,
            macosBuild: "23F79"
        )
        try dbManager.save(&run)
        XCTAssertNotNil(run.id)

        let fetched = try dbManager.fetchRecentRuns(limit: 10)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].macosBuild, "23F79")
    }

    func testCanInsertJobResult() throws {
        var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
        try dbManager.save(&run)

        var result = JobResult(
            runId: run.id!,
            jobType: .dropbox,
            status: .done,
            bytesTransferred: 1_000_000,
            bytesTotal: 5_000_000,
            durationSeconds: 42
        )
        try dbManager.save(&result)
        XCTAssertNotNil(result.id)
    }

    func testJobResultRoundTripsCompletedAt() throws {
        var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
        try dbManager.save(&run)

        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        var result = JobResult(
            runId: run.id!,
            jobType: .dropbox,
            status: .done,
            bytesTransferred: 500,
            bytesTotal: 500,
            durationSeconds: 90,
            completedAt: expected
        )
        try dbManager.save(&result)

        let fetched = try dbManager.fetchJobResults(forRun: run.id!)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(
            fetched[0].completedAt?.timeIntervalSince1970 ?? 0,
            expected.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testJobResultNilCompletedAtRoundTrips() throws {
        var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
        try dbManager.save(&run)

        var result = JobResult(
            runId: run.id!,
            jobType: .dropbox,
            status: .done,
            bytesTransferred: 0,
            bytesTotal: 0,
            durationSeconds: 10,
            completedAt: nil
        )
        try dbManager.save(&result)

        let fetched = try dbManager.fetchJobResults(forRun: run.id!)
        XCTAssertNil(fetched[0].completedAt)
    }

    func testCanInsertLogLine() throws {
        var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
        try dbManager.save(&run)
        var result = JobResult(runId: run.id!, jobType: .dropbox, status: .done, bytesTransferred: 0, bytesTotal: 0, durationSeconds: 0)
        try dbManager.save(&result)

        var line = LogLine(jobResultId: result.id!, timestamp: Date(), line: "sent 1,234 bytes")
        try dbManager.save(&line)
        XCTAssertNotNil(line.id)

        let lines = try dbManager.fetchLogLines(forJobResult: result.id!)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].line, "sent 1,234 bytes")
    }

    // MARK: - Legacy CCC history purge

    func testOpeningPurgesLegacyCCCHistory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("backit-test-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create the schema, then write rows the way a pre-Dropbox-only backit would have.
        _ = try DatabaseManager(path: path)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        let legacy = """
        INSERT INTO backupRun (id, startedAt, completedAt, status, macosBuild) VALUES
            (1, 100, 110, 'success', 'A'),
            (2, 200, 210, 'partial', 'A'),
            (3, 300, 310, 'success', 'A'),
            (4, 400, NULL, 'running', 'A');
        INSERT INTO jobResult (runId, jobType, status, bytesTransferred, bytesTotal, durationSeconds) VALUES
            (1, 'disk', 'done', 0, 0, 1),
            (2, 'disk', 'failed', 0, 0, 1),
            (2, 'dropbox', 'done', 0, 0, 1),
            (3, 'dropbox', 'done', 0, 0, 1);
        """
        XCTAssertEqual(sqlite3_exec(raw, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = try DatabaseManager(path: path)
        let runIds = try db.fetchRecentRuns(limit: 10).compactMap(\.id).sorted()
        // CCC-only run 1 is gone; mixed run 2 keeps only its Dropbox result;
        // run 4 (no results yet, e.g. in progress elsewhere) is left alone.
        XCTAssertEqual(runIds, [2, 3, 4])
        XCTAssertEqual(try db.fetchJobResults(forRun: 2).map(\.jobType), [.dropbox])
        XCTAssertEqual(try db.fetchJobResults(forRun: 3).map(\.jobType), [.dropbox])
    }
}
