import Foundation

enum CCCTaskLoader {
    static func load() async -> [CCCTaskEntry] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/Applications/Carbon Copy Cloner.app/Contents/MacOS/ccc")
        proc.arguments = ["--uuids"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                continuation.resume()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: .newlines).compactMap { line -> CCCTaskEntry? in
            // Format: "UUID: Task Name"
            let parts = line.components(separatedBy: ": ")
            guard parts.count >= 2 else { return nil }
            let uuid = parts[0].trimmingCharacters(in: .whitespaces)
            let name = parts[1...].joined(separator: ": ").trimmingCharacters(in: .whitespaces)
            guard !uuid.isEmpty, !name.isEmpty else { return nil }
            return CCCTaskEntry(id: uuid, name: name)
        }
    }
}

enum RcloneRemoteLoader {
    static func load() async -> [String] {
        let candidates = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"]
        let rclonePath = candidates
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let rclonePath else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath)
        proc.arguments = ["listremotes"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                continuation.resume()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        // Strip trailing colon from each remote (e.g. "dropbox:" → "dropbox")
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }
    }
}
