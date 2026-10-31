import Foundation

enum ProcessRunner {
    /// Runs `proc` to completion and returns its stderr, or nil if it couldn't be launched.
    /// Stderr goes to a temp file rather than a pipe: a pipe nobody reads until exit fills
    /// at ~64 KB and blocks the child forever, which hung post-sync retries for a whole day.
    static func runCollectingStderr(_ proc: Process) async -> String? {
        let errURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backit-stderr-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let errHandle = try? FileHandle(forWritingTo: errURL) else { return nil }
        defer {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }
        proc.standardError = errHandle
        guard (try? proc.run()) != nil else { return nil }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                continuation.resume()
            }
        }
        return (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    }
}
