import Foundation

struct RcloneStats {
    let bytesTransferred: Int64
    let bytesTotal: Int64
    let fraction: Double
    let transferRate: String
}

enum RcloneStatsParser {
    private struct Response: Decodable {
        let bytes: Int64
        let totalBytes: Int64
        let speed: Double
    }

    static func parse(data: Data) throws -> RcloneStats {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let fraction = response.totalBytes > 0 ? Double(response.bytes) / Double(response.totalBytes) : 0.0
        let rate = formatSpeed(response.speed)
        return RcloneStats(
            bytesTransferred: response.bytes,
            bytesTotal: response.totalBytes,
            fraction: fraction,
            transferRate: rate
        )
    }

    private static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }
}
