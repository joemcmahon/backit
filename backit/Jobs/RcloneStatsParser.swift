import Foundation

enum RcloneStatsParser {

    // MARK: - JSON log line parsing

    nonisolated private static func parseJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // Parses a JSON log line and returns a progress update if it contains a stats object.
    nonisolated static func parseLine(_ line: String) -> JobProgress? {
        guard let json = parseJSON(line),
              let s = json["stats"] as? [String: Any] else { return nil }

        let totalBytes = (s["totalBytes"] as? NSNumber)?.int64Value ?? 0
        let bytes = (s["bytes"] as? NSNumber)?.int64Value ?? 0
        let listed = (s["listed"] as? NSNumber)?.int64Value ?? 0
        let speed = (s["speed"] as? NSNumber)?.doubleValue ?? 0

        // Scan phase: no bytes yet, show listed count
        if totalBytes == 0 && listed > 0 {
            return JobProgress(
                fraction: 0,
                bytesTransferred: 0,
                bytesTotal: 0,
                transferRate: "Listed \(formatCount(listed)) files",
                status: .running)
        }

        guard totalBytes > 0 else { return nil }

        return JobProgress(
            fraction: Double(bytes) / Double(totalBytes),
            bytesTransferred: bytes,
            bytesTotal: totalBytes,
            transferRate: formatSpeed(speed),
            status: .running)
    }

    // Extracts the remote-relative path from a JSON error log line.
    nonisolated static func parseError(_ line: String) -> String? {
        guard let json = parseJSON(line),
              (json["level"] as? String) == "error" else { return nil }
        let msg = json["msg"] as? String ?? ""
        guard !msg.contains("too_many_requests") else { return nil }
        guard !msg.contains("error reading source directory") else { return nil }
        guard !msg.contains("failed to set directory modtime") else { return nil }
        guard !msg.contains("failed to set modtime") else { return nil }
        guard let path = json["object"] as? String, !path.isEmpty else { return nil }
        return path
    }

    // Extracts the remote-relative directory path from a directory read error.
    nonisolated static func parseDirectoryError(_ line: String) -> String? {
        guard let json = parseJSON(line),
              (json["level"] as? String) == "error",
              let msg = json["msg"] as? String,
              msg.contains("error reading source directory") else { return nil }
        guard !msg.contains("too_many_requests") else { return nil }
        guard let path = json["object"] as? String, !path.isEmpty else { return nil }
        return path
    }

    // Parses the ISO 8601 timestamp from a JSON log line.
    nonisolated static func parseTimestamp(_ line: String) -> Date? {
        guard let json = parseJSON(line),
              let timeStr = json["time"] as? String else { return nil }
        return parseISO8601(timeStr)
    }

    // Update RcloneStats from a JSON log line. Returns true if something changed.
    nonisolated static func updateStats(_ stats: inout RcloneStats, from line: String) -> Bool {
        guard let json = parseJSON(line) else { return false }

        // Stats object — bulk update counters
        if let s = json["stats"] as? [String: Any] {
            stats.listed = (s["listed"] as? NSNumber)?.int64Value ?? stats.listed
            stats.checked = (s["checks"] as? NSNumber)?.int64Value ?? stats.checked
            stats.filesTransferred = (s["transfers"] as? NSNumber)?.int64Value ?? stats.filesTransferred
            stats.bytesTransferred = (s["bytes"] as? NSNumber)?.int64Value ?? stats.bytesTransferred
            stats.errors = (s["errors"] as? NSNumber)?.intValue ?? stats.errors
            let speed = (s["speed"] as? NSNumber)?.doubleValue ?? 0
            if speed > 0 { stats.transferRate = formatSpeed(speed) }
            if let lastErr = s["lastError"] as? String, !lastErr.isEmpty,
               !lastErr.contains("too_many_requests"),
               !lastErr.contains("failed to set directory modtime"),
               !lastErr.contains("failed to set modtime") {
                stats.lastError = lastErr
            }
            return true
        }

        // Error lines — classify by message content
        guard (json["level"] as? String) == "error" else { return false }
        let msg = json["msg"] as? String ?? ""

        if msg.contains("too_many_requests") {
            stats.rateLimitHits += 1
            return true
        }

        if (msg.contains("failed to set directory modtime") || msg.contains("failed to set modtime"))
            && msg.contains("no such file or directory") {
            stats.modtimeErrors = stats.errors
            return true
        }

        if msg.contains("error reading source directory") || msg.contains("march failed") {
            stats.transientErrors += 1
            return true
        }

        // Real error — update lastError
        if let obj = json["object"] as? String, !obj.isEmpty {
            stats.lastError = "\(obj): \(msg)"
        } else {
            stats.lastError = msg
        }
        return true
    }

    // MARK: - Legacy text extractors (retry phase stderr doesn't use --use-json-log)

    nonisolated static func extractCheckedCount(_ line: String) -> Int64? {
        let pattern = #"Checks:\s+([\d,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return Int64(line[r].replacingOccurrences(of: ",", with: ""))
    }

    nonisolated static func extractFileCount(_ line: String) -> Int64? {
        let pattern = #"Transferred:\s+([\d,]+)\s*/\s*[\d,]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return Int64(line[r].replacingOccurrences(of: ",", with: ""))
    }

    nonisolated static func extractErrorCount(_ line: String) -> Int? {
        let pattern = #"Errors:\s+([\d,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[r].replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - Formatting helpers

    nonisolated private static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 { return String(format: "%.1f GiB/s", bytesPerSec / 1_073_741_824) }
        if bytesPerSec >= 1_048_576 { return String(format: "%.1f MiB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.1f KiB/s", bytesPerSec / 1024) }
        return String(format: "%.0f B/s", bytesPerSec)
    }

    nonisolated private static func formatCount(_ n: Int64) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    nonisolated private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
