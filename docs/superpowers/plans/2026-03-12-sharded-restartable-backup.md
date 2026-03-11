# Sharded Restartable Backup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break rclone backup into per-shard jobs (one per top-level Dropbox directory) with persistent state, enabling resume after sleep/crash without restarting from scratch.

**Architecture:** ShardStateManager persists progress to Application Support JSON. ShardDiscoverer lists top-level dirs via `rclone lsd`. BackupCoordinator orchestrates sequential per-shard DropboxJob runs using the existing DropboxJob (extended with an optional subPath). AppDelegate observes sleep/wake to cancel and offer resume.

**Tech Stack:** Swift 5.10+, SwiftUI, Combine, Foundation (JSONEncoder/Decoder), NSWorkspace notifications, rclone CLI

**Spec:** `docs/superpowers/specs/2026-03-12-sharded-restartable-backup-design.md`

---

## Chunk 1: State Model and Manager

### Task 1: ShardState data model

**Files:**
- Create: `backit/Backup/ShardState.swift`
- Test: `backitTests/ShardStateTests.swift`

- [ ] **Step 1: Create `backit/Backup/` directory and `ShardState.swift`**

```swift
import Foundation

enum ShardStatus: String, Codable {
    case pending, running, done, failed
}

struct ShardEntry: Codable, Equatable {
    let path: String
    var syncStatus: ShardStatus
    var verifyStatus: ShardStatus

    init(path: String) {
        self.path = path
        self.syncStatus = .pending
        self.verifyStatus = .pending
    }
}

struct ShardState: Codable {
    let startedAt: Date
    let remoteName: String
    let destinationPath: String
    var shards: [ShardEntry]

    static let ttlSeconds: TimeInterval = 18 * 3600

    var isExpired: Bool {
        Date().timeIntervalSince(startedAt) > Self.ttlSeconds
    }

    var completedSyncCount: Int { shards.filter { $0.syncStatus == .done }.count }
    var totalCount: Int { shards.count }
    var allSyncDone: Bool { shards.allSatisfy { $0.syncStatus == .done || $0.syncStatus == .failed } }
    var pendingSyncIndex: Int? { shards.firstIndex { $0.syncStatus == .pending || $0.syncStatus == .running } }
    var pendingVerifyShards: [ShardEntry] { shards.filter { $0.verifyStatus != .done } }
}
```

- [ ] **Step 2: Write tests for ShardState**

```swift
import XCTest
@testable import backit

final class ShardStateTests: XCTestCase {
    func testIsExpiredWhenOld() async {
        let old = Date().addingTimeInterval(-19 * 3600)
        let state = ShardState(startedAt: old, remoteName: "dropbox",
                               destinationPath: "/tmp/dest", shards: [])
        XCTAssertTrue(state.isExpired)
    }

    func testIsNotExpiredWhenRecent() async {
        let recent = Date().addingTimeInterval(-1 * 3600)
        let state = ShardState(startedAt: recent, remoteName: "dropbox",
                               destinationPath: "/tmp/dest", shards: [])
        XCTAssertFalse(state.isExpired)
    }

    func testCompletedSyncCount() async {
        var state = ShardState(startedAt: Date(), remoteName: "dropbox",
                               destinationPath: "/tmp/dest",
                               shards: [ShardEntry(path: "A"), ShardEntry(path: "B")])
        state.shards[0].syncStatus = .done
        XCTAssertEqual(state.completedSyncCount, 1)
        XCTAssertEqual(state.totalCount, 2)
    }

    func testPendingSyncIndex() async {
        var state = ShardState(startedAt: Date(), remoteName: "dropbox",
                               destinationPath: "/tmp/dest",
                               shards: [ShardEntry(path: "A"), ShardEntry(path: "B")])
        state.shards[0].syncStatus = .done
        XCTAssertEqual(state.pendingSyncIndex, 1)
    }
}
```

- [ ] **Step 3: Run tests** — `xcodebuild test -scheme backit -destination 'platform=macOS'`
Expected: PASS

- [ ] **Step 4: Commit**
```bash
git add backit/Backup/ShardState.swift backitTests/ShardStateTests.swift
git commit -m "Add ShardState model with TTL and shard status tracking"
```

---

### Task 2: ShardStateManager

**Files:**
- Create: `backit/Backup/ShardStateManager.swift`
- Test: `backitTests/ShardStateManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import backit

final class ShardStateManagerTests: XCTestCase {
    var manager: ShardStateManager!
    var tmpURL: URL!

    override func setUp() async throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        manager = ShardStateManager(stateFileURL: tmpURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testRoundTrip() async throws {
        let state = ShardState(startedAt: Date(), remoteName: "dropbox",
                               destinationPath: "/tmp/dest",
                               shards: [ShardEntry(path: "Code")])
        manager.save(state)
        let loaded = manager.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.remoteName, "dropbox")
        XCTAssertEqual(loaded?.shards.count, 1)
    }

    func testLoadReturnsNilWhenMissing() async {
        XCTAssertNil(manager.load())
    }

    func testLoadReturnsNilWhenExpired() async {
        let old = Date().addingTimeInterval(-20 * 3600)
        let state = ShardState(startedAt: old, remoteName: "dropbox",
                               destinationPath: "/tmp", shards: [])
        manager.save(state)
        XCTAssertNil(manager.load())
    }

    func testClearDeletesFile() async {
        let state = ShardState(startedAt: Date(), remoteName: "dropbox",
                               destinationPath: "/tmp", shards: [])
        manager.save(state)
        manager.clear()
        XCTAssertNil(manager.load())
    }

    func testMarkSyncStatus() async {
        var state = ShardState(startedAt: Date(), remoteName: "dropbox",
                               destinationPath: "/tmp",
                               shards: [ShardEntry(path: "Code")])
        manager.save(state)
        manager.markSync("Code", status: .done)
        let loaded = manager.load()
        XCTAssertEqual(loaded?.shards.first?.syncStatus, .done)
    }
}
```

- [ ] **Step 2: Run tests** — Expected: FAIL (ShardStateManager not defined)

- [ ] **Step 3: Implement ShardStateManager**

```swift
import Foundation

final class ShardStateManager {
    static let shared = ShardStateManager()

    private let stateFileURL: URL

    init(stateFileURL: URL? = nil) {
        if let url = stateFileURL {
            self.stateFileURL = url
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("backit", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir,
                withIntermediateDirectories: true)
            self.stateFileURL = dir.appendingPathComponent("backup-state.json")
        }
    }

    func load() -> ShardState? {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(ShardState.self, from: data),
              !state.isExpired else {
            return nil
        }
        return state
    }

    func save(_ state: ShardState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    func markSync(_ path: String, status: ShardStatus) {
        guard var state = load() else { return }
        if let i = state.shards.firstIndex(where: { $0.path == path }) {
            state.shards[i].syncStatus = status
            save(state)
        }
    }

    func markVerify(_ path: String, status: ShardStatus) {
        guard var state = load() else { return }
        if let i = state.shards.firstIndex(where: { $0.path == path }) {
            state.shards[i].verifyStatus = status
            save(state)
        }
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add backit/Backup/ShardStateManager.swift backitTests/ShardStateManagerTests.swift
git commit -m "Add ShardStateManager with atomic JSON persistence and TTL enforcement"
```

---

## Chunk 2: Shard Discovery and DropboxJob Extension

### Task 3: ShardDiscoverer

**Files:**
- Create: `backit/Backup/ShardDiscoverer.swift`
- Test: `backitTests/ShardDiscovererTests.swift`

- [ ] **Step 1: Write failing test for output parsing**

```swift
import XCTest
@testable import backit

final class ShardDiscovererTests: XCTestCase {
    func testParseLsdOutput() async {
        let output = """
          -1 2024-01-01 00:00:00        -1 Code
          -1 2024-01-01 00:00:00        -1 Documents
          -1 2024-01-01 00:00:00        -1 Music
        """
        let paths = ShardDiscoverer.parseLsdOutput(output)
        XCTAssertEqual(paths, ["Code", "Documents", "Music"])
    }

    func testParseLsdOutputHandlesEmpty() async {
        XCTAssertEqual(ShardDiscoverer.parseLsdOutput(""), [])
    }
}
```

- [ ] **Step 2: Run tests** — Expected: FAIL

- [ ] **Step 3: Implement ShardDiscoverer**

```swift
import Foundation

enum ShardDiscoverer {
    // Returns top-level directory names in the remote, sorted alphabetically.
    static func discover(remoteName: String) async -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath())
        proc.arguments = ["lsd", "\(remoteName):"]
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
        return parseLsdOutput(output)
    }

    // Parses `rclone lsd` output. Format: "  -1 date time  -1 DirName"
    nonisolated static func parseLsdOutput(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                // lsd format: <size> <date> <time> <objects> <name>
                guard parts.count >= 5 else { return nil }
                let name = parts[4...].joined(separator: " ")
                return name.isEmpty ? nil : name
            }
            .sorted()
    }

    private static func rclonePath() -> String {
        let candidates = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"]
        for path in candidates {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        return "/usr/local/bin/rclone"
    }
}
```

- [ ] **Step 4: Run tests** — Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add backit/Backup/ShardDiscoverer.swift backitTests/ShardDiscovererTests.swift
git commit -m "Add ShardDiscoverer to list top-level Dropbox directories via rclone lsd"
```

---

### Task 4: Extend DropboxJob with subPath support

**Files:**
- Modify: `backit/Jobs/DropboxJob.swift`
- Modify: `backitTests/DropboxJobTests.swift`

- [ ] **Step 1: Add test for subPath construction**

```swift
func testSubPathUsedInInit() async {
    let job = DropboxJob(remoteName: "dropbox", volumePath: "/dest", subPath: "Code")
    // Can't easily test rclone args without running — verify init doesn't crash
    XCTAssertNotNil(job)
}
```

- [ ] **Step 2: Run test** — Expected: FAIL (no subPath parameter)

- [ ] **Step 3: Add `subPath` parameter to DropboxJob**

In `DropboxJob.swift`, add `private let subPath: String?` and update `init`:

```swift
init(remoteName: String, volumePath: String, verify: Bool = true, subPath: String? = nil) {
    self.remoteName = remoteName
    self.volumePath = volumePath
    self.verify = verify
    self.subPath = subPath
    self.progress = CurrentValueSubject(.idle)
}
```

Update the rclone sync arguments:
```swift
let remoteSpec = subPath.map { "\(remoteName):\($0)" } ?? "\(remoteName):"
let localPath = subPath.map { "\(volumePath.trimmingCharacters(in: .whitespaces))/\($0)" }
               ?? volumePath.trimmingCharacters(in: .whitespaces)

proc.arguments = [
    "sync", remoteSpec, localPath,
    // ... rest of args unchanged
]
```

Apply the same pattern to `cleanupFailedDirectories` and `runVerification` where they construct paths.

- [ ] **Step 4: Run tests** — Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add backit/Jobs/DropboxJob.swift backitTests/DropboxJobTests.swift
git commit -m "Add optional subPath to DropboxJob for per-shard sync and verify"
```

---

## Chunk 3: Coordinator Integration

### Task 5: BackupCoordinator sharded sync

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`

- [ ] **Step 1: Add shard progress published properties**

```swift
@Published var currentShardIndex: Int = 0
@Published var totalShards: Int = 0
@Published var currentShardName: String = ""
@Published var pendingResume: Bool = false
```

- [ ] **Step 2: Add `runShardedDropboxSync()` method**

```swift
private func runShardedDropboxSync(state: inout ShardState) async {
    totalShards = state.shards.count
    for (i, shard) in state.shards.enumerated() {
        guard shard.syncStatus != .done else { continue }
        currentShardIndex = i + 1
        currentShardName = shard.path
        ShardStateManager.shared.markSync(shard.path, status: .running)

        let job = DropboxJob(
            remoteName: settings.dropboxRemoteName,
            volumePath: settings.dropboxVolumePath,
            verify: false,   // verify runs separately in verify phase
            subPath: shard.path
        )
        let statsTask = Task { [weak self] in
            for await s in job.statsSubject.values { self?.rcloneStats = s }
        }
        let progressTask = Task { [weak self] in
            for await p in job.progress.values { self?.dropboxProgress = p }
        }

        do { try await job.start() } catch {}

        progressTask.cancel()
        statsTask.cancel()

        let success = job.progress.value.status == .done
        ShardStateManager.shared.markSync(shard.path, status: success ? .done : .failed)

        if Task.isCancelled { break }
    }
    currentShardIndex = 0
    totalShards = 0
    currentShardName = ""
}
```

- [ ] **Step 3: Update `performBackup()` to use sharding for Dropbox jobs**

Replace the single `DropboxJob` run in the jobs loop with:
```swift
if job.jobType == .dropbox, let dropboxJob = job as? DropboxJob {
    // Use sharded sync instead of single job
    var state = ShardStateManager.shared.load()
             ?? (await buildFreshState())
    await runShardedDropboxSync(state: &state)
    if !Task.isCancelled {
        ShardStateManager.shared.clear()
    }
} else {
    // CCC and other jobs run as before
    try await job.start()
}
```

Add `buildFreshState()`:
```swift
private func buildFreshState() async -> ShardState {
    let dirs = await ShardDiscoverer.discover(remoteName: settings.dropboxRemoteName)
    let shards = dirs.map { ShardEntry(path: $0) }
    let state = ShardState(
        startedAt: Date(),
        remoteName: settings.dropboxRemoteName,
        destinationPath: settings.dropboxVolumePath,
        shards: shards.isEmpty
            ? [ShardEntry(path: "")]  // fallback: one shard for the whole remote
            : shards
    )
    ShardStateManager.shared.save(state)
    return state
}
```

- [ ] **Step 4: Add sleep/wake handlers**

```swift
func handleSleep() {
    guard isRunning else { return }
    // Mark current shard back to pending so it reruns on resume
    if !currentShardName.isEmpty {
        ShardStateManager.shared.markSync(currentShardName, status: .pending)
    }
    cancelBackup()
}

func handleWake() {
    guard let state = ShardStateManager.shared.load(), !state.isExpired else { return }
    guard state.pendingSyncIndex != nil else { return }
    pendingResume = true
}
```

- [ ] **Step 5: Add `resumeBackup()` and `discardResumeAndStartFresh()`**

```swift
func resumeBackup() {
    pendingResume = false
    runBackup()  // performBackup will load existing state
}

func discardResumeAndStartFresh() {
    pendingResume = false
    ShardStateManager.shared.clear()
    runBackup()
}
```

- [ ] **Step 6: Run existing tests** — `xcodebuild test -scheme backit -destination 'platform=macOS'`
Expected: PASS (existing tests unaffected)

- [ ] **Step 7: Commit**
```bash
git add backit/Coordination/BackupCoordinator.swift
git commit -m "Integrate sharded Dropbox sync into BackupCoordinator with sleep/wake support"
```

---

## Chunk 4: UI Integration

### Task 6: Sleep/wake wiring in AppDelegate

**Files:**
- Modify: `backit/AppDelegate.swift`

- [ ] **Step 1: Add NSWorkspace sleep/wake observers in `applicationDidFinishLaunching`**

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: nil, queue: .main) { @MainActor [weak self] _ in
    self?.coordinator?.handleSleep()
}
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil, queue: .main) { @MainActor [weak self] _ in
    self?.coordinator?.handleWake()
}
```

Also call `coordinator.handleWake()` at app launch to catch state from a previous crashed/killed run:
```swift
// After setting up coordinator:
coordinator.handleWake()
```

- [ ] **Step 2: Commit**
```bash
git add backit/AppDelegate.swift
git commit -m "Observe sleep/wake notifications to cancel backup and offer resume"
```

---

### Task 7: ResumeBackupSheet

**Files:**
- Create: `backit/UI/ResumeBackupSheet.swift`

- [ ] **Step 1: Create the sheet**

```swift
import SwiftUI

struct ResumeBackupSheet: View {
    let completedCount: Int
    let totalCount: Int
    let onResume: () -> Void
    let onStartOver: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Backup Interrupted")
                    .font(.headline)
            }

            Text("The last backup was interrupted after \(completedCount) of \(totalCount) shards completed.")
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Skip Tonight") { onSkip() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Start Over") { onStartOver() }
                    .buttonStyle(.bordered)
                Button("Resume") { onResume() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 400)
    }
}
```

- [ ] **Step 2: Wire into BackitMainView**

Add `@State private var showResumeSheet = false` and observe `coordinator.pendingResume`:

```swift
.onChange(of: coordinator.pendingResume) { _, pending in
    if pending { showResumeSheet = true }
}
.sheet(isPresented: $showResumeSheet) {
    if let state = ShardStateManager.shared.load() {
        ResumeBackupSheet(
            completedCount: state.completedSyncCount,
            totalCount: state.totalCount,
            onResume: { showResumeSheet = false; coordinator.resumeBackup() },
            onStartOver: { showResumeSheet = false; coordinator.discardResumeAndStartFresh() },
            onSkip: { showResumeSheet = false; coordinator.pendingResume = false }
        )
    }
}
```

- [ ] **Step 3: Commit**
```bash
git add backit/UI/ResumeBackupSheet.swift backit/UI/BackitMainView.swift
git commit -m "Add ResumeBackupSheet for interrupted backup recovery"
```

---

### Task 8: Shard progress in stats panel

**Files:**
- Modify: `backit/UI/BackitMainView.swift`

- [ ] **Step 1: Show shard progress in RcloneStatusView label**

In `RcloneStatusView`, add optional `shardInfo: String?` parameter. When set, append it to the title:

```swift
Label(stats.verifyMode
      ? "Dropbox (rclone check)"
      : shardInfo.map { "Dropbox — \($0)" } ?? "Dropbox (rclone)",
      systemImage: ...)
```

In `BackitMainView`, pass shard info:
```swift
let shardInfo: String? = coordinator.totalShards > 0
    ? "Shard \(coordinator.currentShardIndex)/\(coordinator.totalShards): \(coordinator.currentShardName)"
    : nil

RcloneStatusView(
    sourcePicker: ...,
    destPicker: ...,
    stats: coordinator.rcloneStats,
    startDate: ...,
    shardInfo: shardInfo
)
```

- [ ] **Step 2: Commit**
```bash
git add backit/UI/BackitMainView.swift
git commit -m "Show current shard progress in rclone stats panel header"
```

---

### Task 9: Clear Backup State in settings

**Files:**
- Modify: `backit/UI/BackitMainView.swift`

- [ ] **Step 1: Add "Clear Backup State" to ScheduleSheetView**

```swift
Section("Backup State") {
    Button("Clear Backup State") {
        ShardStateManager.shared.clear()
    }
    .foregroundColor(.red)
}
```

- [ ] **Step 2: Commit**
```bash
git add backit/UI/BackitMainView.swift
git commit -m "Add Clear Backup State button to schedule settings sheet"
```

---

## Chunk 5: Sharded Verify Phase

### Task 10: Per-shard verify in BackupCoordinator

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`

- [ ] **Step 1: Add `runShardedVerify()` method**

```swift
private func runShardedVerify() async {
    guard let state = ShardStateManager.shared.load() else { return }
    let pending = state.pendingVerifyShards
    guard !pending.isEmpty else { return }

    totalShards = pending.count
    for (i, shard) in pending.enumerated() {
        currentShardIndex = i + 1
        currentShardName = shard.path
        ShardStateManager.shared.markVerify(shard.path, status: .running)

        let job = DropboxJob(
            remoteName: settings.dropboxRemoteName,
            volumePath: settings.dropboxVolumePath,
            verify: true,
            subPath: shard.path.isEmpty ? nil : shard.path
        )
        let statsTask = Task { [weak self] in
            for await s in job.statsSubject.values { self?.rcloneStats = s }
        }
        await job.verifyOnly()
        statsTask.cancel()

        ShardStateManager.shared.markVerify(shard.path, status: .done)
        if Task.isCancelled { break }
    }
    totalShards = 0
    currentShardIndex = 0
    currentShardName = ""
}
```

- [ ] **Step 2: Wire verify into `runVerifyOnly()`**

Replace `performVerification()` to use per-shard approach:
```swift
func performVerification() async {
    isRunning = true
    rcloneStats = RcloneStats(status: .running)
    currentJobStartDate = Date()
    await runShardedVerify()
    isRunning = false
    currentJobType = nil
    currentJobStartDate = nil
    runningTask = nil
}
```

- [ ] **Step 3: Run all tests** — Expected: PASS

- [ ] **Step 4: Commit**
```bash
git add backit/Coordination/BackupCoordinator.swift
git commit -m "Add per-shard verify phase using ShardStateManager verify status"
```

---

## Final Steps

- [ ] **Build and run** — launch app, trigger a backup, verify shard progress shows in title
- [ ] **Test sleep/wake** — let one shard complete, put machine to sleep, wake up, verify resume sheet appears
- [ ] **Test start-over** — click Start Over, verify state file is deleted and fresh backup begins
- [ ] **Test expiry** — manually edit state file `startedAt` to 20 hours ago, relaunch, verify no resume prompt
- [ ] **Test Clear State** — open schedule sheet, click Clear Backup State, verify prompt does not reappear
- [ ] **Commit and merge to main**
