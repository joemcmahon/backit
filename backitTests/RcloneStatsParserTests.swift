import XCTest
@testable import backit

final class RcloneStatsParserTests: XCTestCase {

    // MARK: - JSON log format tests

    func testUpdateStatsTransferBytes() {
        var stats = RcloneStats()
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"notice","msg":"stats","stats":{"bytes":1048576,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":0,"eta":null,"fatalError":false,"listed":0,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":524288,"totalBytes":10485760,"totalChecks":0,"totalTransfers":10,"transferTime":0.05,"transfers":1},"source":"slog/logger.go:256"}
        """
        let matched = RcloneStatsParser.updateStats(&stats, from: line)
        XCTAssertTrue(matched)
        XCTAssertEqual(stats.bytesTransferred, 1_048_576)
    }

    func testUpdateStatsChecks() {
        var stats = RcloneStats()
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"notice","msg":"stats","stats":{"bytes":0,"checks":42,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":0,"eta":null,"fatalError":false,"listed":100,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":0,"totalChecks":100,"totalTransfers":0,"transferTime":0,"transfers":0},"source":"slog/logger.go:256"}
        """
        let matched = RcloneStatsParser.updateStats(&stats, from: line)
        XCTAssertTrue(matched)
        XCTAssertEqual(stats.checked, 42)
    }

    func testUpdateStatsUnrecognizedLineReturnsFalse() {
        var stats = RcloneStats()
        let matched = RcloneStatsParser.updateStats(&stats, from: "some random log output")
        XCTAssertFalse(matched)
    }

    func testParseTimestamp() {
        let line = """
        {"time":"2024-01-15T22:30:00.000-07:00","level":"info","msg":"Dropbox: Waiting for checks to finish","source":"slog/logger.go:256"}
        """
        let date = RcloneStatsParser.parseTimestamp(line)
        XCTAssertNotNil(date)
    }

    func testExtractFileCount() {
        // Legacy text format — still used by retry phase
        let line = "Transferred:   5 / 20 files, 25%"
        let count = RcloneStatsParser.extractFileCount(line)
        XCTAssertEqual(count, 5)
    }

    func testModtimeErrorsDetectedFromSummaryLine() {
        var stats = RcloneStats()

        // Stats line arrives with error count
        let statsLine = """
        {"time":"2026-04-02T04:03:15.000-07:00","level":"notice","msg":"stats","stats":{"bytes":0,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":140,"eta":null,"fatalError":false,"listed":0,"renames":0,"retryError":true,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":0,"totalChecks":0,"totalTransfers":0,"transferTime":0,"transfers":0},"source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: statsLine)
        XCTAssertEqual(stats.errors, 140)
        XCTAssertEqual(stats.modtimeErrors, 0)

        // Then modtime error summary line arrives
        let modtimeLine = """
        {"time":"2026-04-02T04:03:17.000-07:00","level":"error","msg":"Attempt 1/1 failed with 140 errors and: failed to set directory modtime: 10 errors: last error: chtimes /Volumes/Backup/some/path: no such file or directory","source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: modtimeLine)
        XCTAssertEqual(stats.modtimeErrors, 140)
        XCTAssertEqual(stats.realErrors, 0)
        XCTAssertTrue(stats.onlyRecoverableErrors)  // all errors are benign modtime errors
    }

    func testModtimeErrorsNotAddedToFailedPaths() {
        let line = """
        {"time":"2026-04-02T04:03:17.000-07:00","level":"error","msg":"Attempt 1/1 failed with 140 errors and: failed to set directory modtime: chtimes /path: no such file or directory","source":"slog/logger.go:256"}
        """
        let path = RcloneStatsParser.parseError(line)
        XCTAssertNil(path, "Modtime error summary should not be treated as a failed file path")
    }

    func testRealErrorsWithMixedErrors() {
        var stats = RcloneStats()

        // Stats line with 10 errors
        let statsLine = """
        {"time":"2026-04-02T04:03:15.000-07:00","level":"notice","msg":"stats","stats":{"bytes":0,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":10,"eta":null,"fatalError":false,"listed":0,"renames":0,"retryError":true,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":0,"totalChecks":0,"totalTransfers":0,"transferTime":0,"transfers":0},"source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: statsLine)

        // Real error line
        let errorLine = """
        {"time":"2026-04-02T04:03:16.000-07:00","level":"error","msg":"failed to copy: some real error","object":"some/file","objectType":"*dropbox.Object","source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: errorLine)
        XCTAssertEqual(stats.realErrors, 10)
        XCTAssertEqual(stats.modtimeErrors, 0)
    }

    func testParseLineReturnsProgressFromStats() {
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"notice","msg":"stats","stats":{"bytes":5242880,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":0,"eta":null,"fatalError":false,"listed":100,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":2621440,"totalBytes":10485760,"totalChecks":0,"totalTransfers":10,"transferTime":1.0,"transfers":5},"source":"slog/logger.go:256"}
        """
        let progress = RcloneStatsParser.parseLine(line)
        XCTAssertNotNil(progress)
        XCTAssertEqual(progress!.fraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(progress!.bytesTransferred, 5_242_880)
        XCTAssertEqual(progress!.bytesTotal, 10_485_760)
        XCTAssertEqual(progress!.transferRate, "2.5 MiB/s")
    }

    func testParseLineScanPhaseShowsListedCount() {
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"notice","msg":"stats","stats":{"bytes":0,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":2.0,"errors":0,"eta":null,"fatalError":false,"listed":4140,"renames":0,"retryError":false,"serverSideCopies":0,"serverSideCopyBytes":0,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":0,"totalChecks":0,"totalTransfers":0,"transferTime":0,"transfers":0},"source":"slog/logger.go:256"}
        """
        let progress = RcloneStatsParser.parseLine(line)
        XCTAssertNotNil(progress)
        XCTAssertTrue(progress!.transferRate.contains("4,140"))
    }

    func testParseErrorReturnsPathFromObject() {
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"error","msg":"Failed to copy: permission denied","object":"Camera Uploads/IMG_1234.jpg","objectType":"*dropbox.Object","source":"slog/logger.go:256"}
        """
        let path = RcloneStatsParser.parseError(line)
        XCTAssertEqual(path, "Camera Uploads/IMG_1234.jpg")
    }

    func testParseErrorFiltersRateLimits() {
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"error","msg":"Failed to copy: too_many_requests/...","object":"some/file.txt","objectType":"*dropbox.Object","source":"slog/logger.go:256"}
        """
        let path = RcloneStatsParser.parseError(line)
        XCTAssertNil(path)
    }

    func testParseDirectoryError() {
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"error","msg":"error reading source directory: couldn't list files","object":"Photos/2024","objectType":"*dropbox.Fs","source":"slog/logger.go:256"}
        """
        let path = RcloneStatsParser.parseDirectoryError(line)
        XCTAssertEqual(path, "Photos/2024")
    }

    func testRateLimitHitsCountedFromErrorLines() {
        var stats = RcloneStats()
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"error","msg":"Failed to copy: too_many_requests/retry_after","object":"some/file.txt","objectType":"*dropbox.Object","source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: line)
        XCTAssertEqual(stats.rateLimitHits, 1)
    }

    func testTransientErrorsCounted() {
        var stats = RcloneStats()
        let line = """
        {"time":"2026-01-15T22:30:00.000-07:00","level":"error","msg":"error reading source directory: connection reset","object":"Documents","objectType":"*dropbox.Fs","source":"slog/logger.go:256"}
        """
        _ = RcloneStatsParser.updateStats(&stats, from: line)
        XCTAssertEqual(stats.transientErrors, 1)
    }
}
