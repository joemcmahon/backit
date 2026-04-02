import XCTest
@testable import backit

final class RcloneStatsParserTests: XCTestCase {

    func testUpdateStatsTransferBytes() {
        var stats = RcloneStats()
        let line = "Transferred:   1.000 MiB / 10.000 MiB, 10%, 512.000 KiB/s, ETA 17s"
        let matched = RcloneStatsParser.updateStats(&stats, from: line)
        XCTAssertTrue(matched)
        XCTAssertEqual(stats.bytesTransferred, 1_048_576)
    }

    func testUpdateStatsChecks() {
        var stats = RcloneStats()
        let line = "Checks:                42 / 100, 42%"
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
        let line = "2024/01/15 22:30:00 INFO  : Dropbox: Waiting for checks to finish"
        let date = RcloneStatsParser.parseTimestamp(line)
        XCTAssertNotNil(date)
    }

    func testExtractFileCount() {
        let line = "Transferred:   5 / 20 files, 25%"
        let count = RcloneStatsParser.extractFileCount(line)
        XCTAssertEqual(count, 5)
    }

    func testModtimeErrorsDetectedFromSummaryLine() {
        var stats = RcloneStats()
        // Simulate the Errors: count from the stats block arriving first
        _ = RcloneStatsParser.updateStats(&stats, from: "Errors:              140")
        XCTAssertEqual(stats.errors, 140)
        XCTAssertEqual(stats.modtimeErrors, 0)

        // Then the modtime summary line arrives
        let summary = "2026/04/02 04:03:17 ERROR : Attempt 1/1 failed with 140 errors and: failed to set directory modtime: 10 errors: last error: chtimes /Volumes/Backup/some/path: no such file or directory"
        _ = RcloneStatsParser.updateStats(&stats, from: summary)
        XCTAssertEqual(stats.modtimeErrors, 140)
        XCTAssertEqual(stats.realErrors, 0)
        XCTAssertFalse(stats.onlyRateLimitErrors)  // no rate limit hits
    }

    func testModtimeErrorsNotAddedToFailedPaths() {
        let line = "2026/04/02 04:03:17 ERROR : Attempt 1/1 failed with 140 errors and: failed to set directory modtime: chtimes /path: no such file or directory"
        let path = RcloneStatsParser.parseError(line)
        XCTAssertNil(path, "Modtime error summary should not be treated as a failed file path")
    }

    func testRealErrorsWithMixedErrors() {
        var stats = RcloneStats()
        _ = RcloneStatsParser.updateStats(&stats, from: "Errors:               10")
        _ = RcloneStatsParser.updateStats(&stats, from: "2026/04/02 ERROR : some/file: failed to copy: some real error")
        // Only 10 errors, no modtime summary → all real
        XCTAssertEqual(stats.realErrors, 10)
        XCTAssertEqual(stats.modtimeErrors, 0)
    }
}
