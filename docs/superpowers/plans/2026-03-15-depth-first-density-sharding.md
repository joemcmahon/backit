# Depth-First Density Sharding Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace recursive-file-count sharding with a depth-first Swift FileManager traversal that classifies each directory by its *flat* (non-recursive) file count, chunks wide directories into groups of files sent via `--files-from`, and adds a cleanup sync pass for each wide directory to handle remote deletions.

**Architecture:** `ShardDiscoverer.classifyTree` performs a pure-Swift depth-first traversal of the local backup volume mirror, classifying each directory bottom-up and producing a flat list of `ShardInvocation` values (directory sync, file chunk copy, or cleanup sync). `DropboxJob` is extended to materialise these invocations into rclone command lines. `BackupCoordinator.buildFreshState` is replaced with a single `classifyTree` call, and `runShardedDropboxSync` dispatches the appropriate rclone mode per invocation type. The 10-shard cap is removed; shard count equals the number of invocations from the tree walk.

**Tech Stack:** Swift 5.9+, Foundation (`FileManager`, `Process`, `Pipe`), XCTest async, rclone (`sync`, `copy`, `check`, `--files-from`, `--filter-from`)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `backit/Backup/ShardInvocation.swift` | **Create** | `ShardInvocation` enum: three cases, Codable, convenience accessors |
| `backit/Backup/ShardDiscoverer.swift` | **Modify** | Add `classifyTree` + private `classifyDir`; keep existing functions (they have tests); deprecate `expandOversizedDirs`, `maxTransfersForFileCount`, `countFiles` with comments |
| `backit/Backup/ShardState.swift` | **Modify** | Replace `ShardEntry.paths/totalBytes/maxTransfers` with `ShardEntry.invocation: ShardInvocation`; keep convenience accessors |
| `backit/Jobs/DropboxJob.swift` | **Modify** | Add `excludes: [String]` and `filesFrom: [String]?` init params; materialise filter/files-from temp files in `start()`; use `copy` mode when `filesFrom != nil` |
| `backit/Coordination/BackupCoordinator.swift` | **Modify** | Replace `buildFreshState` body with `classifyTree` call; update `runShardedDropboxSync` to dispatch by invocation type; update 409 hint recording |
| `backitTests/ShardInvocationTests.swift` | **Create** | Codable round-trip tests for all three cases |
| `backitTests/ShardDiscovererTests.swift` | **Modify** | Add tests for `classifyTree` using temp directory fixtures |
| `backitTests/ShardStateTests.swift` | **Modify** | Update for new `ShardEntry` shape |
| `backitTests/DropboxJobTests.swift` | **Modify** | Add tests for `excludes`/`filesFrom` init params |

---

## Test command

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(Test Suite|passed|failed|error:)'
```

---

## Chunk 1: ShardInvocation + ShardEntry

### Task 1: ShardInvocation enum

**Files:**
- Create: `backit/Backup/ShardInvocation.swift`
- Create: `backitTests/ShardInvocationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// backitTests/ShardInvocationTests.swift
import XCTest
@testable import backit

final class ShardInvocationTests: XCTestCase {
    // MARK: - Codable round-trips

    func testDirectoryCodableRoundTrip() throws {
        let inv = ShardInvocation.directory(remotePath: "Pictures", excludes: ["sub1/**"], transfers: 8)
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(ShardInvocation.self, from: data)
        XCTAssertEqual(inv, decoded)
    }

    func testFileChunkCodableRoundTrip() throws {
        let inv = ShardInvocation.fileChunk(remoteDirPath: "Documents", files: ["a.txt", "b.pdf"], transfers: 8)
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(ShardInvocation.self, from: data)
        XCTAssertEqual(inv, decoded)
    }

    func testCleanupSyncCodableRoundTrip() throws {
        let inv = ShardInvocation.cleanupSync(remotePath: "Documents", excludes: ["Work/**"], transfers: 4)
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(ShardInvocation.self, from: data)
        XCTAssertEqual(inv, decoded)
    }

    // MARK: - Convenience accessors

    func testTransfersAccessor() {
        XCTAssertEqual(ShardInvocation.directory(remotePath: "A", excludes: [], transfers: 2).transfers, 2)
        XCTAssertEqual(ShardInvocation.fileChunk(remoteDirPath: "B", files: [], transfers: 4).transfers, 4)
        XCTAssertEqual(ShardInvocation.cleanupSync(remotePath: "C", excludes: [], transfers: 1).transfers, 1)
    }

    func testDisplayPathAccessor() {
        XCTAssertEqual(ShardInvocation.directory(remotePath: "Photos", excludes: [], transfers: 8).displayPath, "Photos")
        XCTAssertEqual(ShardInvocation.fileChunk(remoteDirPath: "Code", files: [], transfers: 8).displayPath, "Code")
        XCTAssertEqual(ShardInvocation.cleanupSync(remotePath: "Music", excludes: [], transfers: 8).displayPath, "Music")
    }

    func testUnknownTypeDecodesAsDirectory() throws {
        let json = """
        {"type":"unknown","remotePath":"X","transfers":8}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ShardInvocation.self, from: json)
        XCTAssertEqual(decoded, .directory(remotePath: "X", excludes: [], transfers: 8))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/ShardInvocationTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: compile error — `ShardInvocation` not defined.

- [ ] **Step 3: Create ShardInvocation.swift**

```swift
// backit/Backup/ShardInvocation.swift
import Foundation

/// Describes a single rclone invocation produced by the depth-first tree classifier.
enum ShardInvocation: Codable, Equatable {
    /// rclone sync with optional --filter-from (for handled child excludes).
    case directory(remotePath: String, excludes: [String], transfers: Int)
    /// rclone copy --files-from for a chunk of loose files in a wide directory.
    case fileChunk(remoteDirPath: String, files: [String], transfers: Int)
    /// rclone sync --filter-from to remove deleted files from a wide directory after chunk copies.
    case cleanupSync(remotePath: String, excludes: [String], transfers: Int)

    private enum CodingKeys: String, CodingKey {
        case type, remotePath, excludes, transfers, files
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let p, let e, let t):
            try c.encode("directory", forKey: .type)
            try c.encode(p, forKey: .remotePath)
            try c.encode(e, forKey: .excludes)
            try c.encode(t, forKey: .transfers)
        case .fileChunk(let p, let f, let t):
            try c.encode("fileChunk", forKey: .type)
            try c.encode(p, forKey: .remotePath)
            try c.encode(f, forKey: .files)
            try c.encode(t, forKey: .transfers)
        case .cleanupSync(let p, let e, let t):
            try c.encode("cleanupSync", forKey: .type)
            try c.encode(p, forKey: .remotePath)
            try c.encode(e, forKey: .excludes)
            try c.encode(t, forKey: .transfers)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let path = try c.decode(String.self, forKey: .remotePath)
        let transfers = (try? c.decode(Int.self, forKey: .transfers)) ?? 8
        switch type {
        case "directory":
            let excludes = (try? c.decode([String].self, forKey: .excludes)) ?? []
            self = .directory(remotePath: path, excludes: excludes, transfers: transfers)
        case "fileChunk":
            let files = (try? c.decode([String].self, forKey: .files)) ?? []
            self = .fileChunk(remoteDirPath: path, files: files, transfers: transfers)
        case "cleanupSync":
            let excludes = (try? c.decode([String].self, forKey: .excludes)) ?? []
            self = .cleanupSync(remotePath: path, excludes: excludes, transfers: transfers)
        default:
            self = .directory(remotePath: path, excludes: [], transfers: transfers)
        }
    }

    var transfers: Int {
        switch self {
        case .directory(_, _, let t), .fileChunk(_, _, let t), .cleanupSync(_, _, let t): return t
        }
    }

    var displayPath: String {
        switch self {
        case .directory(let p, _, _), .fileChunk(let p, _, _), .cleanupSync(let p, _, _): return p
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/ShardInvocationTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: `Test Suite 'ShardInvocationTests' passed`

- [ ] **Step 5: Commit**

```bash
git add backit/Backup/ShardInvocation.swift backitTests/ShardInvocationTests.swift
git commit -m "Add ShardInvocation enum (Codable, three cases)"
```

---

### Task 2: Update ShardEntry to use ShardInvocation

**Files:**
- Modify: `backit/Backup/ShardState.swift`
- Modify: `backitTests/ShardStateTests.swift`

- [ ] **Step 1: Write failing tests for new ShardEntry shape**

Add these tests to `backitTests/ShardStateTests.swift` (alongside existing tests):

```swift
// Add to ShardStateTests

func testShardEntryHoldsInvocation() {
    let inv = ShardInvocation.directory(remotePath: "Pictures", excludes: [], transfers: 8)
    let entry = ShardEntry(invocation: inv)
    XCTAssertEqual(entry.invocation, inv)
    XCTAssertEqual(entry.transfers, 8)
    XCTAssertEqual(entry.displayPath, "Pictures")
}

func testShardEntryCodableRoundTrip() throws {
    let inv = ShardInvocation.fileChunk(remoteDirPath: "Code", files: ["a.swift"], transfers: 8)
    let entry = ShardEntry(invocation: inv)
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(ShardEntry.self, from: data)
    XCTAssertEqual(entry, decoded)
}

func testShardStateWithMixedInvocations() throws {
    let shards = [
        ShardEntry(invocation: .directory(remotePath: "A", excludes: [], transfers: 8)),
        ShardEntry(invocation: .fileChunk(remoteDirPath: "B", files: ["f.txt"], transfers: 8)),
        ShardEntry(invocation: .cleanupSync(remotePath: "B", excludes: [], transfers: 4))
    ]
    let state = ShardState(startedAt: Date(), remoteName: "dropbox",
                           destinationPath: "/vol", shards: shards)
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(ShardState.self, from: data)
    XCTAssertEqual(decoded.shards.count, 3)
    XCTAssertEqual(decoded.shards[1].displayPath, "B")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/ShardStateTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: compile errors — `ShardEntry(invocation:)` not defined.

- [ ] **Step 3: Replace ShardEntry in ShardState.swift**

Replace the entire `ShardEntry` struct (keep `ShardStatus` and `ShardState` unchanged except removing references to old fields):

```swift
struct ShardEntry: Codable, Equatable {
    let invocation: ShardInvocation
    var syncStatus: ShardStatus
    var verifyStatus: ShardStatus

    init(invocation: ShardInvocation) {
        self.invocation = invocation
        self.syncStatus = .pending
        self.verifyStatus = .pending
    }

    var transfers: Int { invocation.transfers }
    var displayPath: String { invocation.displayPath }
}
```

Also update the computed properties on `ShardState` that referenced the old fields:
- `displayPath` on `ShardEntry` replaces `.paths.first ?? ""`
- Remove `completedSyncCount`, `totalCount`, `allSyncSettled`, `pendingSyncIndex`, `pendingVerifyShards` only if they still compile; they reference `shards` which is still `[ShardEntry]` — they should still work.

Check and update `ShardState` convenience properties:
```swift
// These still work as-is — no changes needed:
var completedSyncCount: Int { shards.filter { $0.syncStatus == .done }.count }
var totalCount: Int { shards.count }
var allSyncSettled: Bool { shards.allSatisfy { $0.syncStatus == .done || $0.syncStatus == .failed } }
var pendingSyncIndex: Int? { shards.firstIndex { $0.syncStatus == .pending || $0.syncStatus == .running } }
var pendingVerifyShards: [ShardEntry] { shards.filter { $0.verifyStatus == .pending || $0.verifyStatus == .running } }
```

- [ ] **Step 4: Fix existing ShardState tests that used old ShardEntry init**

The old tests used `ShardEntry(path:)` and `ShardEntry(paths:totalBytes:maxTransfers:)`. Update them to use `ShardEntry(invocation:)`. For example:
```swift
// Old:
ShardEntry(path: "Photos")
// New:
ShardEntry(invocation: .directory(remotePath: "Photos", excludes: [], transfers: 8))
```

- [ ] **Step 5: Fix BackupCoordinator.buildFreshState and runShardedDropboxSync compile errors**

The coordinator uses `ShardEntry(path:)`, `shard.paths`, `shard.totalBytes`, `shard.maxTransfers`, and `shard.displayPath`. These will fail to compile. Stub them with temporary replacements so the project builds:

In `buildFreshState`, replace the shard construction block temporarily:
```swift
// TEMPORARY: full replacement in Task 6
let shards = [ShardEntry(invocation: .directory(remotePath: "", excludes: [], transfers: 8))]
```

In `runShardedDropboxSync`, change `shard.maxTransfers` → `shard.transfers`, `shard.displayPath` stays the same (accessor already added), and replace `for path in shard.paths` with a single path from the invocation:
```swift
// TEMPORARY stub — replaced in Task 6
let path: String
switch shard.invocation {
case .directory(let p, _, _), .fileChunk(let p, _, _), .cleanupSync(let p, _, _):
    path = p
}
let job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: false,
                     subPath: path.isEmpty ? nil : path,
                     transfers: shard.transfers)
```

Same pattern for `runShardedVerify`.

Also update `ShardStateManager.markSync/markVerify` — they just use `state.shards[index]` which still compiles.

- [ ] **Step 6: Run full test suite to verify it passes**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(Test Suite|passed|failed|error:)'
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add backit/Backup/ShardState.swift backit/Coordination/BackupCoordinator.swift \
        backitTests/ShardStateTests.swift
git commit -m "Replace ShardEntry.paths with ShardEntry.invocation: ShardInvocation"
```

---

## Chunk 2: classifyTree

### Task 3: ShardDiscoverer.classifyTree

**Files:**
- Modify: `backit/Backup/ShardDiscoverer.swift`
- Modify: `backitTests/ShardDiscovererTests.swift`

Background: `classifyTree` is a pure-Swift depth-first traversal using `FileManager` on the local backup volume. It classifies each directory bottom-up by flat file count (files directly in the dir, not in subdirs). No `find` processes are spawned.

Classification rules:
- **Package** (`isFileDensePackage` returns true): one `.directory` invocation, `transfers: 1`, do not recurse.
- **409 hint** exists for this dir: use the stored `maxTransfers` from `ThrottleHintsStore`.
- **Fully covered**: zero flat files AND all subdirs have been handled → return child invocations only, no invocation for this dir.
- **Skinny** (flat file count ≤ `skinnyThreshold`): one `.directory` invocation with `excludes` listing handled children.
- **Wide** (flat file count > `skinnyThreshold`): N `.fileChunk` invocations (files split into groups of `skinnyThreshold`) + one `.cleanupSync` invocation.

- [ ] **Step 1: Write failing classifyTree tests**

Add to `backitTests/ShardDiscovererTests.swift`:

```swift
// MARK: - classifyTree tests

// Helper: creates a temporary directory with given structure and returns its path.
// `tree` is a list of relative paths. Paths ending in "/" are directories; others are files.
private func makeTempTree(_ tree: [String]) -> String {
    let base = NSTemporaryDirectory() + UUID().uuidString
    for entry in tree {
        let full = base + "/" + entry
        if entry.hasSuffix("/") {
            try! FileManager.default.createDirectory(atPath: full.dropLast().description,
                                                      withIntermediateDirectories: true)
        } else {
            FileManager.default.createFile(atPath: full, contents: nil)
        }
    }
    return base
}

func testClassifyTreeSingleSkinnyDir() async {
    // A top-level dir with 3 loose files and no subdirs → one .directory invocation
    let vol = makeTempTree(["Photos/", "Photos/a.jpg", "Photos/b.jpg", "Photos/c.jpg"])
    defer { try? FileManager.default.removeItem(atPath: vol) }

    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Photos"], volumePath: vol
    )

    XCTAssertEqual(invocations.count, 1)
    guard case .directory(let path, let excludes, let transfers) = invocations[0] else {
        return XCTFail("Expected .directory")
    }
    XCTAssertEqual(path, "Photos")
    XCTAssertTrue(excludes.isEmpty)
    XCTAssertEqual(transfers, 8)
}

func testClassifyTreeWideDir() async {
    // A dir with more files than skinnyThreshold → fileChunk + cleanupSync
    let skinny = 3
    var entries = ["Wide/"]
    let files = (1...10).map { "Wide/file\($0).txt" }
    entries += files
    let vol = makeTempTree(entries)
    defer { try? FileManager.default.removeItem(atPath: vol) }

    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Wide"], volumePath: vol, skinnyThreshold: skinny
    )

    // 10 files / 3 per chunk = 4 chunks (3+3+3+1) + 1 cleanupSync
    let chunks = invocations.filter { if case .fileChunk = $0 { return true }; return false }
    let cleanups = invocations.filter { if case .cleanupSync = $0 { return true }; return false }
    XCTAssertEqual(chunks.count, 4)
    XCTAssertEqual(cleanups.count, 1)

    // Each chunk should have ≤ skinnyThreshold files
    for chunk in chunks {
        guard case .fileChunk(_, let chunkFiles, _) = chunk else { continue }
        XCTAssertLessThanOrEqual(chunkFiles.count, skinny)
    }
    // All files accounted for across all chunks
    let allFiles = chunks.flatMap { inv -> [String] in
        guard case .fileChunk(_, let f, _) = inv else { return [] }
        return f
    }
    XCTAssertEqual(Set(allFiles), Set(files.map { URL(fileURLWithPath: $0).lastPathComponent }))
}

func testClassifyTreeFullyCoveredParent() async {
    // Parent with no loose files and all subdirs handled → no invocation for parent itself
    let vol = makeTempTree([
        "Books/", "Books/Novels/", "Books/Novels/a.epub",
        "Books/Comics/", "Books/Comics/b.cbz"
    ])
    defer { try? FileManager.default.removeItem(atPath: vol) }

    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Books"], volumePath: vol
    )

    // Should have invocations for Novels and Comics, but NOT for Books itself
    let paths = invocations.map { $0.displayPath }
    XCTAssertTrue(paths.contains("Books/Novels"))
    XCTAssertTrue(paths.contains("Books/Comics"))
    XCTAssertFalse(paths.contains("Books"))
}

func testClassifyTreeDirWithLooseFilesAndSubdirs() async {
    // Parent has both loose files and subdirs → .directory invocation with excludes
    let vol = makeTempTree([
        "Docs/", "Docs/readme.txt",
        "Docs/Work/", "Docs/Work/report.pdf"
    ])
    defer { try? FileManager.default.removeItem(atPath: vol) }

    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Docs"], volumePath: vol
    )

    let docsInv = invocations.first { $0.displayPath == "Docs" }
    XCTAssertNotNil(docsInv)
    guard case .directory(_, let excludes, _) = docsInv! else {
        return XCTFail("Expected .directory for Docs")
    }
    XCTAssertTrue(excludes.contains("Work/**"))
}

func testClassifyTreeMissingVolume() async {
    // Volume doesn't exist → returns one whole-remote fallback invocation
    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Photos"], volumePath: "/nonexistent/volume"
    )
    XCTAssertEqual(invocations.count, 1)
    guard case .directory(let path, _, _) = invocations[0] else {
        return XCTFail("Expected fallback .directory")
    }
    XCTAssertEqual(path, "Photos")
}

func testClassifyTree409HintUsedForTransfers() async {
    let vol = makeTempTree(["Code/", "Code/main.swift"])
    defer { try? FileManager.default.removeItem(atPath: vol) }

    let hintsURL = URL(fileURLWithPath: vol + "/hints.json")
    let store = ThrottleHintsStore(fileURL: hintsURL)
    store.record(maxTransfers: 2, reason: "409", for: "Code")

    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: ["Code"], volumePath: vol, hints: store
    )

    XCTAssertEqual(invocations.count, 1)
    XCTAssertEqual(invocations[0].transfers, 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/ShardDiscovererTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: compile errors — `classifyTree` not defined.

- [ ] **Step 3: Implement classifyTree and classifyDir in ShardDiscoverer.swift**

Add after the existing `rclonePath()` function (before the closing `}`):

```swift
// MARK: - Depth-first density classification

/// Classifies each directory in `topLevelDirs` by flat file count and produces
/// a list of ShardInvocation values. Uses the local backup volume as a size oracle.
/// Falls back to one .directory per top-level dir if the volume path doesn't exist.
static func classifyTree(
    topLevelDirs: [String],
    volumePath: String,
    skinnyThreshold: Int = 20,
    hints: ThrottleHintsStore = .shared,
    onProgress: ((String) -> Void)? = nil
) async -> [ShardInvocation] {
    let vol = volumePath.trimmingCharacters(in: .whitespaces)
    guard !vol.isEmpty, FileManager.default.fileExists(atPath: vol) else {
        // Volume not mounted: one whole-dir invocation per top-level dir, no classification
        return topLevelDirs.map { .directory(remotePath: $0, excludes: [], transfers: 8) }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [ShardInvocation] = []
            for dir in topLevelDirs {
                result.append(contentsOf: classifyDir(
                    relativePath: dir,
                    volumePath: vol,
                    skinnyThreshold: skinnyThreshold,
                    hints: hints,
                    onProgress: onProgress
                ))
            }
            continuation.resume(returning: result)
        }
    }
}

/// Recursive depth-first classifier. Returns the invocations produced for `relativePath`
/// and all of its descendants. Runs synchronously — call only from a background queue.
private static func classifyDir(
    relativePath: String,
    volumePath: String,
    skinnyThreshold: Int,
    hints: ThrottleHintsStore,
    onProgress: ((String) -> Void)?
) -> [ShardInvocation] {
    let fullPath = volumePath + "/" + relativePath
    onProgress?(relativePath)

    // Package: atomic unit, do not recurse, always 1 transfer
    if isFileDensePackage(at: fullPath) {
        hints.record(maxTransfers: 1, reason: "package", for: relativePath)
        return [.directory(remotePath: relativePath, excludes: [], transfers: 1)]
    }

    // 409 hint overrides classification; still recurse so children get their own entries,
    // but use the hinted transfers for this dir's own invocation (if it gets one).
    let hintedTransfers: Int? = hints.hint(for: relativePath).map { $0.transfers }

    // List directory contents
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: fullPath) else {
        // Unreadable dir: one fallback invocation
        return [.directory(remotePath: relativePath, excludes: [], transfers: hintedTransfers ?? 8)]
    }

    // Separate into flat files and subdirectories (skip hidden entries)
    var flatFiles: [String] = []
    var subdirNames: [String] = []
    for entry in entries.sorted() {
        guard !entry.hasPrefix(".") else { continue }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: fullPath + "/" + entry, isDirectory: &isDir)
        if isDir.boolValue { subdirNames.append(entry) } else { flatFiles.append(entry) }
    }

    // Recurse into subdirs first (depth-first, bottom-up)
    var childInvocations: [ShardInvocation] = []
    var handledChildren: [String] = []
    for subdir in subdirNames {
        let childPath = relativePath + "/" + subdir
        let childInvs = classifyDir(
            relativePath: childPath,
            volumePath: volumePath,
            skinnyThreshold: skinnyThreshold,
            hints: hints,
            onProgress: onProgress
        )
        childInvocations.append(contentsOf: childInvs)
        handledChildren.append(subdir)
    }

    // Fully covered: no loose files AND all subdirs handled → no invocation for this dir
    if flatFiles.isEmpty {
        return childInvocations
    }

    let transfers = hintedTransfers ?? 8
    let excludes = handledChildren.map { "\($0)/**" }

    if flatFiles.count <= skinnyThreshold {
        // Skinny: one directory invocation
        return childInvocations + [.directory(remotePath: relativePath, excludes: excludes, transfers: transfers)]
    } else {
        // Wide: chunk loose files + cleanup sync
        var chunks: [[String]] = stride(from: 0, to: flatFiles.count, by: skinnyThreshold).map {
            Array(flatFiles[$0..<min($0 + skinnyThreshold, flatFiles.count)])
        }
        let chunkInvocations = chunks.map {
            ShardInvocation.fileChunk(remoteDirPath: relativePath, files: $0, transfers: transfers)
        }
        let cleanup = ShardInvocation.cleanupSync(remotePath: relativePath, excludes: excludes, transfers: transfers)
        return childInvocations + chunkInvocations + [cleanup]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/ShardDiscovererTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: all ShardDiscoverer tests pass, including existing ones.

- [ ] **Step 5: Commit**

```bash
git add backit/Backup/ShardDiscoverer.swift backitTests/ShardDiscovererTests.swift
git commit -m "Add ShardDiscoverer.classifyTree: depth-first flat-file-density classification"
```

---

## Chunk 3: DropboxJob + BackupCoordinator wiring

### Task 4: DropboxJob — excludes and filesFrom

**Files:**
- Modify: `backit/Jobs/DropboxJob.swift`
- Modify: `backitTests/DropboxJobTests.swift`

`DropboxJob` needs two new init parameters:
- `excludes: [String] = []` — written to a `--filter-from` temp file (each line `- pattern/**`). Used with `rclone sync`.
- `filesFrom: [String]? = nil` — written to a `--files-from` temp file. Switches mode to `rclone copy`.

When `filesFrom` is non-nil, the job:
- Uses `rclone copy` instead of `rclone sync`
- Passes `--files-from /tmp/backit-files-from-NNNNN.txt`
- Skips the verify pass (verify is called separately for `.directory` shards only)

When `excludes` is non-empty (and `filesFrom` is nil):
- Writes filter lines to a `--filter-from` temp file: each entry becomes `- entry`
- Passes `--filter-from /tmp/backit-filter-NNNNN.txt`
- Uses `rclone sync` as before

- [ ] **Step 1: Write failing tests**

Add to `backitTests/DropboxJobTests.swift`:

```swift
func testExcludesDefaultsToEmpty() async {
    let job = DropboxJob(remoteName: "dropbox", volumePath: "/dest")
    XCTAssertTrue(job.excludes.isEmpty)
}

func testFilesFromDefaultsToNil() async {
    let job = DropboxJob(remoteName: "dropbox", volumePath: "/dest")
    XCTAssertNil(job.filesFrom)
}

func testExcludesAcceptsCustomValue() async {
    let job = DropboxJob(remoteName: "dropbox", volumePath: "/dest",
                         excludes: ["Work/**", "tmp/**"])
    XCTAssertEqual(job.excludes, ["Work/**", "tmp/**"])
}

func testFilesFromAcceptsCustomValue() async {
    let job = DropboxJob(remoteName: "dropbox", volumePath: "/dest",
                         filesFrom: ["a.txt", "b.pdf"])
    XCTAssertEqual(job.filesFrom, ["a.txt", "b.pdf"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/DropboxJobTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: compile errors — `excludes` and `filesFrom` not in `DropboxJob`.

- [ ] **Step 3: Update DropboxJob.init and start()**

In `DropboxJob.swift`:

**1. Add stored properties** (after the existing `let transfers: Int` line):
```swift
let excludes: [String]
let filesFrom: [String]?
```

**2. Update init**:
```swift
init(remoteName: String, volumePath: String, verify: Bool = true,
     subPath: String? = nil, transfers: Int = 8,
     excludes: [String] = [], filesFrom: [String]? = nil) {
    self.remoteName = remoteName
    self.volumePath = volumePath
    self.verify = verify
    self.subPath = subPath
    self.transfers = transfers
    self.excludes = excludes
    self.filesFrom = filesFrom
    self.progress = CurrentValueSubject(.idle)
}
```

**3. Update start() command construction** — replace the `proc.arguments = [...]` block with:

```swift
var isCopy = false
var filterTmpURL: URL? = nil
var filesTomURL: URL? = nil

if let files = filesFrom {
    // fileChunk mode: rclone copy --files-from
    isCopy = true
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backit-files-from-\(UUID().uuidString).txt")
    try? files.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    filesTomURL = url
} else if !excludes.isEmpty {
    // directory mode with excludes: rclone sync --filter-from
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backit-filter-\(UUID().uuidString).txt")
    let filterLines = excludes.map { "- \($0)" }.joined(separator: "\n")
    try? filterLines.write(to: url, atomically: true, encoding: .utf8)
    filterTmpURL = url
}

let command = isCopy ? "copy" : "sync"
var args: [String] = [command, remoteSpec, localPath,
    "--metadata", "--fast-list",
    "--tpslimit", "12", "--tpslimit-burst", "0",
    "--transfers", "\(transfers)", "--checkers", "8",
    "--retries", "1", "--low-level-retries", "1",
    "--ignore-errors",
    "--stats", "2s", "--stats-log-level", "NOTICE"]
if let url = filesTomURL {
    args += ["--files-from", url.path]
}
if let url = filterTmpURL {
    args += ["--filter-from", url.path]
}
proc.arguments = args
```

Add temp file cleanup after the process finishes (after `logFileHandle = nil`):
```swift
if let url = filesTomURL { try? FileManager.default.removeItem(at: url) }
if let url = filterTmpURL { try? FileManager.default.removeItem(at: url) }
```

Also skip the verify call when `filesFrom != nil` (copy mode has no deletion semantics):
```swift
if verify && filesFrom == nil { await runVerification() }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/DropboxJobTests 2>&1 \
  | grep -E '(passed|failed|error:)'
```
Expected: all DropboxJob tests pass.

- [ ] **Step 5: Commit**

```bash
git add backit/Jobs/DropboxJob.swift backitTests/DropboxJobTests.swift
git commit -m "DropboxJob: add excludes (--filter-from) and filesFrom (--files-from / copy mode)"
```

---

### Task 5: BackupCoordinator — wire classifyTree and dispatch by invocation type

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`

This task replaces `buildFreshState` with a `classifyTree`-based implementation and updates `runShardedDropboxSync` and `runShardedVerify` to dispatch the appropriate `DropboxJob` configuration per `ShardInvocation` case.

- [ ] **Step 1: Replace buildFreshState**

Replace the entire `buildFreshState` method body:

```swift
private func buildFreshState() async -> ShardState {
    planningPhase = "Checking remote"
    let dirs = await ShardDiscoverer.discover(remoteName: settings.dropboxRemoteName)

    planningPhase = "Classifying directories"
    scanningFileCount = 0
    let invocations = await ShardDiscoverer.classifyTree(
        topLevelDirs: dirs,
        volumePath: settings.dropboxVolumePath,
        hints: ThrottleHintsStore.shared,
        onProgress: { [weak self] path in
            Task { @MainActor [weak self] in
                self?.planningPhase = "Classifying \(path)"
            }
        }
    )
    planningPhase = ""

    let shards = invocations.map { ShardEntry(invocation: $0) }
    let state = ShardState(
        startedAt: Date(),
        remoteName: settings.dropboxRemoteName,
        destinationPath: settings.dropboxVolumePath,
        shards: shards.isEmpty
            ? [ShardEntry(invocation: .directory(remotePath: "", excludes: [], transfers: 8))]
            : shards
    )
    ShardStateManager.shared.save(state)
    return state
}
```

- [ ] **Step 2: Update runShardedDropboxSync**

Replace the job-creation block inside the shard loop:

```swift
// Replace the inner "for path in shard.paths" block with:
var shardSucceeded = true
if Task.isCancelled { break }

let job: DropboxJob
switch shard.invocation {
case .directory(let remotePath, let excludes, let transfers):
    job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: false,
                     subPath: remotePath.isEmpty ? nil : remotePath,
                     transfers: transfers,
                     excludes: excludes)
case .fileChunk(let remoteDirPath, let files, let transfers):
    job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: false,
                     subPath: remoteDirPath.isEmpty ? nil : remoteDirPath,
                     transfers: transfers,
                     filesFrom: files)
case .cleanupSync(let remotePath, let excludes, let transfers):
    job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: false,
                     subPath: remotePath.isEmpty ? nil : remotePath,
                     transfers: transfers,
                     excludes: excludes)
}

let statsTask = Task { [weak self] in
    for await s in job.statsSubject.values { self?.rcloneStats = s }
}
let progressTask = Task { [weak self] in
    for await p in job.progress.values { self?.dropboxProgress = p }
}
do { try await job.start() } catch {}
progressTask.cancel()
statsTask.cancel()
if job.progress.value.status != .done { shardSucceeded = false }

// Record 409 hint (directory and cleanupSync shards only; fileChunks share the parent path)
let hintPath: String?
switch shard.invocation {
case .directory(let p, _, let t), .cleanupSync(let p, _, let t):
    hintPath = p.isEmpty ? nil : p
    if let hp = hintPath, job.statsSubject.value.rateLimitHits > 0 {
        let newMaxT = max(1, t / 2)
        ThrottleHintsStore.shared.record(maxTransfers: newMaxT, reason: "409", for: hp)
    }
case .fileChunk:
    break  // parent dir's cleanupSync will record the hint if needed
}
```

Remove the old `for path in shard.paths` loop.

- [ ] **Step 3: Update runShardedVerify**

Replace the job-creation block in the verify loop:

```swift
// Skip cleanupSync shards — they handle deletions, not content correctness
if case .cleanupSync = shard.invocation {
    ShardStateManager.shared.markVerify(at: shardIdx, status: .done)
    continue
}

let job: DropboxJob
switch shard.invocation {
case .directory(let path, let excludes, let transfers):
    job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: true,
                     subPath: path.isEmpty ? nil : path,
                     transfers: transfers,
                     excludes: excludes)
case .fileChunk(let path, let files, let transfers):
    job = DropboxJob(remoteName: settings.dropboxRemoteName,
                     volumePath: settings.dropboxVolumePath,
                     verify: true,
                     subPath: path.isEmpty ? nil : path,
                     transfers: transfers,
                     filesFrom: files)
case .cleanupSync:
    fatalError("unreachable — handled above")
}

let statsTask = Task { [weak self] in
    for await s in job.statsSubject.values { self?.rcloneStats = s }
}
await job.verifyOnly()
statsTask.cancel()
```

Also remove the now-dead `for path in shard.paths` loop in `runShardedVerify`.

- [ ] **Step 4: Run full test suite**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(Test Suite|passed|failed|error:)'
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add backit/Coordination/BackupCoordinator.swift
git commit -m "BackupCoordinator: wire classifyTree, dispatch by ShardInvocation type"
```

---

## Chunk 4: Cleanup

### Task 6: Remove dead code and deprecate obsolete functions

**Files:**
- Modify: `backit/Backup/ShardDiscoverer.swift`

The following functions are now superseded by `classifyTree`:
- `expandOversizedDirs` — size-based subdivision (replaced by depth-first density)
- `maxTransfersForFileCount` — recursive-count thresholds (replaced by flat count in classifyTree)
- `measureSizes`, `packShards`, `targetShardCount` — bin-packing pipeline (replaced by classifyTree)
- `countFiles` — recursive find-based counter (no longer used by coordinator)

The `isFileDensePackage` function is still used by `classifyTree` — keep it.

**Strategy:** Mark unused functions with `// DEPRECATED: superseded by classifyTree` comments, then remove them. Removing them will cause compile errors if anything references them — use those errors as a checklist.

- [ ] **Step 1: Remove expandOversizedDirs, maxTransfersForFileCount, measureSizes, packShards, targetShardCount, countFiles**

Delete these functions from `ShardDiscoverer.swift`. Also delete their private helpers: `subdirectories(at:)` and `measureSubdirSizes(parentPath:subdirs:parentKey:)` (used only by `expandOversizedDirs`).

- [ ] **Step 2: Fix any compile errors**

If `buildFreshState` or tests reference the deleted functions, they will error. The coordinator was updated in Task 5 — these should all be gone. If tests in `ShardDiscovererTests.swift` test the deleted functions, remove those tests (they are superseded).

- [ ] **Step 3: Run full test suite**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(Test Suite|passed|failed|error:)'
```
Expected: all tests pass with fewer functions, no references to deleted symbols.

- [ ] **Step 4: Remove scanningFileCount from BackupCoordinator** (optional — if no longer updated)

`scanningFileCount` was driven by `countFiles`'s `onProgress`. The new `classifyTree` uses `planningPhase` for progress. If `scanningFileCount` is no longer set anywhere, remove the `@Published var scanningFileCount: Int = 0` property and its UI binding in `BackitMainView.swift`.

Check with:
```bash
grep -r "scanningFileCount" backit/ backitTests/
```
If only one definition and no setters remain, remove it.

- [ ] **Step 5: Commit**

```bash
git add backit/Backup/ShardDiscoverer.swift backit/Coordination/BackupCoordinator.swift \
        backit/UI/BackitMainView.swift backitTests/ShardDiscovererTests.swift
git commit -m "Remove superseded ShardDiscoverer functions (expandOversizedDirs, packShards, etc.)"
```

---

## Notes for implementation

- The `hintedTransfers` logic in `classifyDir` uses the **stored** maxTransfers from a 409 hint but still recurses normally. This means a dir that triggered 409s last run will use the reduced transfer count without re-scanning its flat file count.

- `rclone copy --files-from` does not delete destination files. This is intentional: the `.cleanupSync` invocation that follows the `.fileChunk` group handles deletions by running `rclone sync --filter-from` (which excludes handled children but syncs everything else in the parent dir, including deletions).

- The old 10-shard cap (`max(1, min(10, count))`) is gone. Shard count = number of invocations from `classifyTree`. For a typical Dropbox with ~70 top-level dirs and moderate nesting, expect 100-300 invocations total. This is fine — each is one rclone process run sequentially.

- Hidden directories (names starting with `.`) are skipped in `classifyDir`. This matches Dropbox's behaviour of not syncing most hidden directories.
