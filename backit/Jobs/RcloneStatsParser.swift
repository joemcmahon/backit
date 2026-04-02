import Foundation

enum RcloneStatsParser {
    // Parses a single line from rclone --stats output and returns a progress update if relevant.
    // Actual rclone output format (IEC units):
    //   Transferred:   553.658 KiB / 553.658 KiB, 100%, 0 B/s, ETA -
    //   Transferred:            1 / 1, 100%          ← count line, ignored
    //   Checks:             30916 / 30916, 100%, Listed 74687
    //   Elapsed time:      3m47.9s
    nonisolated static func parseLine(_ line: String) -> JobProgress? {
        if let p = parseTransferred(line) { return p }
        if let p = parseChecks(line) { return p }
        return nil
    }

    // Extracts the remote-relative path from an rclone file error line.
    // Format: "... ERROR : path/to/file: Failed to copy: <reason>"
    // Returns nil if it's a directory error (handled by parseDirectoryError).
    nonisolated static func parseError(_ line: String) -> String? {
        guard line.contains("ERROR : ") else { return nil }
        guard !line.contains("error reading source directory") else { return nil }
        guard !line.contains("failed to set directory modtime") else { return nil }
        guard !line.contains("failed to set modtime") else { return nil }
        guard let errorRange = line.range(of: "ERROR : ") else { return nil }
        let after = String(line[errorRange.upperBound...])
        guard let colonRange = after.range(of: ": ") else { return nil }
        let path = String(after[after.startIndex..<colonRange.lowerBound])
        return path.isEmpty ? nil : path
    }

    // Extracts the remote-relative directory path from a directory read error line.
    // Format: "... ERROR : path/to/dir: error reading source directory: <reason>"
    nonisolated static func parseDirectoryError(_ line: String) -> String? {
        guard line.contains("error reading source directory") else { return nil }
        guard let errorRange = line.range(of: "ERROR : ") else { return nil }
        let after = String(line[errorRange.upperBound...])
        guard let colonRange = after.range(of: ": ") else { return nil }
        let path = String(after[after.startIndex..<colonRange.lowerBound])
        return path.isEmpty ? nil : path
    }

    // Transferred:   553.658 KiB / 553.658 KiB, 100%, 45.6 MiB/s, ETA 1m30s
    // Ignores count lines like "Transferred: 1 / 1, 100%" (no byte unit present)
    nonisolated private static func parseTransferred(_ line: String) -> JobProgress? {
        guard line.contains("Transferred:") else { return nil }
        let fraction = extractPercent(line)
        let rate = extractRate(line)
        let (xferred, total) = extractBytes(line)
        // Only emit if we have actual byte transfer data (total > 0)
        guard total > 0 else { return nil }
        return JobProgress(
            fraction: fraction,
            bytesTransferred: xferred,
            bytesTotal: total,
            transferRate: rate,
            status: .running)
    }

    // Checks:   30916 / 30916, 100%, Listed 74687
    // In incremental runs checks = total (batch complete), but Listed N grows — use that as status.
    // In full runs Checks: X / Y with X < Y — show as normal progress.
    nonisolated private static func parseChecks(_ line: String) -> JobProgress? {
        guard line.contains("Checks:") else { return nil }

        // Try "Listed N" first — indicates scan progress in incremental runs
        if let listed = extractListed(line) {
            return JobProgress(
                fraction: 0,
                bytesTransferred: 0,
                bytesTotal: 0,
                transferRate: "Listed \(formatCount(listed)) files",
                status: .running)
        }

        return nil
    }

    // Extracts the timestamp from a rclone log line.
    // Format: "2026/03/11 17:35:06 NOTICE: ..."
    nonisolated static func parseTimestamp(_ line: String) -> Date? {
        let pattern = #"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: String(line[range]))
    }

    // Update a RcloneStats struct from a single stderr line. Returns true if something changed.
    nonisolated static func updateStats(_ stats: inout RcloneStats, from line: String) -> Bool {
        if line.contains("too_many_requests") {
            stats.rateLimitHits += 1
            return true
        }
        if line.contains("Checks:") {
            if let n = extractListed(line) { stats.listed = n }
            if let n = extractCheckedCount(line) { stats.checked = n }
            return true
        }
        if line.contains("Transferred:") {
            let (xferred, total) = extractBytes(line)
            if total > 0 {
                stats.bytesTransferred = xferred
                let rate = extractRate(line)
                if !rate.isEmpty { stats.transferRate = rate }
            } else if let n = extractFileCount(line) {
                stats.filesTransferred = n
            }
            return true
        }
        if line.contains("Errors:"), let n = extractErrorCount(line) {
            stats.errors = n
            return true
        }
        // Modtime errors on deleted paths: rclone summary "failed to set directory modtime"
        // These are benign — all files transferred, rclone just couldn't update dir timestamps.
        // When this summary appears, all errors at this point are modtime errors.
        if (line.contains("failed to set directory modtime") || line.contains("failed to set modtime"))
            && line.contains("no such file or directory") {
            stats.modtimeErrors = stats.errors
            return true
        }
        return false
    }

    nonisolated static func extractCheckedCount(_ line: String) -> Int64? {
        let pattern = #"Checks:\s+([\d,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return Int64(line[r].replacingOccurrences(of: ",", with: ""))
    }

    nonisolated static func extractFileCount(_ line: String) -> Int64? {
        // Count line: "Transferred:   1 / 1, 100%" — no byte unit
        let (_, total) = extractBytes(line)
        guard total == 0 else { return nil }
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

    nonisolated private static func extractListed(_ line: String) -> Int64? {
        let pattern = #"Listed\s+([\d,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return Int64(line[r].replacingOccurrences(of: ",", with: ""))
    }

    nonisolated private static func extractPercent(_ line: String) -> Double {
        let pattern = #"(\d+(?:\.\d+)?)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return 0 }
        return (Double(line[range]) ?? 0) / 100.0
    }

    // Matches IEC rates: 45.6 MiB/s, 0 B/s, 1.2 GiB/s
    nonisolated private static func extractRate(_ line: String) -> String {
        let pattern = #"([\d.]+\s*[KMGT]?i?B/s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[range])
    }

    // Matches IEC byte pairs: "553.658 KiB / 553.658 KiB" or "1.234 GiB / 5.678 GiB"
    nonisolated private static func extractBytes(_ line: String) -> (Int64, Int64) {
        let pattern = #"([\d.]+)\s*([KMGT]?i?B(?:ytes)?)\s*/\s*([\d.]+)\s*([KMGT]?i?B(?:ytes)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(match.range(at: 1), in: line),
              let r2 = Range(match.range(at: 2), in: line),
              let r3 = Range(match.range(at: 3), in: line),
              let r4 = Range(match.range(at: 4), in: line) else { return (0, 0) }
        let v1 = Double(line[r1]) ?? 0
        let v2 = Double(line[r3]) ?? 0
        return (toBytes(v1, unit: String(line[r2])), toBytes(v2, unit: String(line[r4])))
    }

    nonisolated private static func toBytes(_ value: Double, unit: String) -> Int64 {
        switch unit {
        case "TiB", "TBytes": return Int64(value * 1_099_511_627_776)
        case "GiB", "GBytes": return Int64(value * 1_073_741_824)
        case "MiB", "MBytes": return Int64(value * 1_048_576)
        case "KiB", "KBytes": return Int64(value * 1_024)
        default:               return Int64(value)
        }
    }

    nonisolated private static func formatCount(_ n: Int64) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
