import XCTest
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
            jobType: .disk,
            status: .done,
            bytesTransferred: 1_000_000,
            bytesTotal: 5_000_000,
            durationSeconds: 42
        )
        try dbManager.save(&result)
        XCTAssertNotNil(result.id)
    }

    func testCanInsertLogLine() throws {
        var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
        try dbManager.save(&run)
        var result = JobResult(runId: run.id!, jobType: .disk, status: .done, bytesTransferred: 0, bytesTotal: 0, durationSeconds: 0)
        try dbManager.save(&result)

        var line = LogLine(jobResultId: result.id!, timestamp: Date(), line: "sent 1,234 bytes")
        try dbManager.save(&line)
        XCTAssertNotNil(line.id)

        let lines = try dbManager.fetchLogLines(forJobResult: result.id!)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].line, "sent 1,234 bytes")
    }
}
