import XCTest
@testable import backit

final class RcloneStatsParserTests: XCTestCase {
    func testParsesStats() throws {
        let json = """
        {
          "bytes": 1048576,
          "totalBytes": 10485760,
          "speed": 524288.0,
          "transferring": [{}]
        }
        """
        let stats = try RcloneStatsParser.parse(data: json.data(using: .utf8)!)
        XCTAssertEqual(stats.bytesTransferred, 1_048_576)
        XCTAssertEqual(stats.bytesTotal, 10_485_760)
        XCTAssertEqual(stats.fraction, 0.1, accuracy: 0.001)
        XCTAssertEqual(stats.transferRate, "512.0 KB/s")
    }

    func testHandlesZeroTotal() throws {
        let json = #"{"bytes": 0, "totalBytes": 0, "speed": 0.0}"#
        let stats = try RcloneStatsParser.parse(data: json.data(using: .utf8)!)
        XCTAssertEqual(stats.fraction, 0.0)
    }
}
