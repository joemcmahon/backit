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
}
