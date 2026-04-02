# Per-Job Completion Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After each backup job finishes, its section in the main window shows "completed HH:MM:SS MMM D, YYYY · H:MM:SS" (or "failed …") in place of `--:--`, and the bottom bar shows total wall-clock run duration.

**Architecture:** Add `completedAt: Date?` to `JobResult` (model + DB), publish three per-job `JobResult?` properties from `BackupCoordinator` (set after each job, restored from DB at startup), and thread them into the two job section views where they replace the idle `--:--` timer.

**Tech Stack:** Swift, SwiftUI, SQLite3 (raw), XCTest

---

## File Map

| File | Change |
|------|--------|
| `backit/Database/Models.swift` | Add `completedAt: Date? = nil` to `JobResult` |
| `backit/Database/DatabaseManager.swift` | ALTER TABLE migration; update INSERT/UPDATE/SELECT for `completedAt` |
| `backit/Coordination/BackupCoordinator.swift` | 4 new `@Published` properties; set in `performBackup`/`performSingleJob`; extend `restoreLastRun` |
| `backit/UI/BackitMainView.swift` | Add `lastResult` param to `JobSectionView` + `RcloneStatusView`; wire coordinator; update bottom bar |
| `backitTests/DatabaseTests.swift` | 2 new tests for `completedAt` round-trip |
| `backitTests/BackupCoordinatorTests.swift` | 3 new tests for per-job published properties + startup restore |

---

## Task 1: Add `completedAt` to `JobResult` model and DB layer

**Files:**
- Modify: `backit/Database/Models.swift`
- Modify: `backit/Database/DatabaseManager.swift`
- Modify: `backitTests/DatabaseTests.swift`

- [ ] **Step 1: Write two failing tests in `DatabaseTests.swift`**

Add inside `final class DatabaseTests`:

```swift
func testJobResultRoundTripsCompletedAt() throws {
    var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
    try dbManager.save(&run)

    let expected = Date(timeIntervalSince1970: 1_700_000_000)
    var result = JobResult(
        runId: run.id!,
        jobType: .dropbox,
        status: .done,
        bytesTransferred: 500,
        bytesTotal: 500,
        durationSeconds: 90,
        completedAt: expected
    )
    try dbManager.save(&result)

    let fetched = try dbManager.fetchJobResults(forRun: run.id!)
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(
        fetched[0].completedAt?.timeIntervalSince1970 ?? 0,
        expected.timeIntervalSince1970,
        accuracy: 0.001
    )
}

func testJobResultNilCompletedAtRoundTrips() throws {
    var run = BackupRun(startedAt: Date(), completedAt: nil, status: .running, macosBuild: "23F79")
    try dbManager.save(&run)

    var result = JobResult(
        runId: run.id!,
        jobType: .disk,
        status: .done,
        bytesTransferred: 0,
        bytesTotal: 0,
        durationSeconds: 10,
        completedAt: nil
    )
    try dbManager.save(&result)

    let fetched = try dbManager.fetchJobResults(forRun: run.id!)
    XCTAssertNil(fetched[0].completedAt)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/joemcmahon/Code/backit
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: compile error — `JobResult` initializer has no `completedAt` parameter.

- [ ] **Step 3: Add `completedAt` to `JobResult` in `Models.swift`**

Replace the `JobResult` struct:

```swift
struct JobResult {
    var id: Int64?
    var runId: Int64
    var jobType: JobType
    var status: JobStatus
    var bytesTransferred: Int64
    var bytesTotal: Int64
    var durationSeconds: Int
    var completedAt: Date? = nil
}
```

- [ ] **Step 4: Run tests — expect DB-layer failures now (column missing)**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: compiles but `testJobResultRoundTripsCompletedAt` fails (completedAt comes back nil — column doesn't exist yet).

- [ ] **Step 5: Add migration and update `DatabaseManager.swift`**

**5a — `migrate()`:** After the closing `}` of the existing `guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK` block, add:

```swift
// Additive migration: add completedAt to jobResult if not present.
// Returns SQLITE_ERROR ("duplicate column name") on re-run — that's expected; ignore it.
sqlite3_exec(db, "ALTER TABLE jobResult ADD COLUMN completedAt REAL;", nil, nil, nil)
```

**5b — `save(_ result:)` INSERT** — replace the INSERT SQL and add the seventh binding:

```swift
let sql = """
INSERT INTO jobResult (runId, jobType, status, bytesTransferred, bytesTotal, durationSeconds, completedAt)
VALUES (?, ?, ?, ?, ?, ?, ?)
"""
var stmt: OpaquePointer?
defer { sqlite3_finalize(stmt) }
try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
sqlite3_bind_int64(stmt, 1, result.runId)
sqlite3_bind_text(stmt, 2, result.jobType.rawValue, -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 3, result.status.rawValue, -1, SQLITE_TRANSIENT)
sqlite3_bind_int64(stmt, 4, result.bytesTransferred)
sqlite3_bind_int64(stmt, 5, result.bytesTotal)
sqlite3_bind_int64(stmt, 6, Int64(result.durationSeconds))
bindDouble(stmt, 7, result.completedAt?.timeIntervalSince1970)
try checkDone(sqlite3_step(stmt))
result.id = sqlite3_last_insert_rowid(db)
```

**5c — `save(_ result:)` UPDATE** — replace the UPDATE SQL and adjust bindings (completedAt is 7th column, id is 8th bind):

```swift
let sql = """
UPDATE jobResult SET runId=?, jobType=?, status=?, bytesTransferred=?, bytesTotal=?, durationSeconds=?, completedAt=?
WHERE id=?
"""
var stmt: OpaquePointer?
defer { sqlite3_finalize(stmt) }
try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
sqlite3_bind_int64(stmt, 1, result.runId)
sqlite3_bind_text(stmt, 2, result.jobType.rawValue, -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 3, result.status.rawValue, -1, SQLITE_TRANSIENT)
sqlite3_bind_int64(stmt, 4, result.bytesTransferred)
sqlite3_bind_int64(stmt, 5, result.bytesTotal)
sqlite3_bind_int64(stmt, 6, Int64(result.durationSeconds))
bindDouble(stmt, 7, result.completedAt?.timeIntervalSince1970)
sqlite3_bind_int64(stmt, 8, result.id!)
try checkDone(sqlite3_step(stmt))
```

**5d — `fetchJobResults(forRun:)`** — add `completedAt` to SELECT and read column 7:

```swift
func fetchJobResults(forRun runId: Int64) throws -> [JobResult] {
    let sql = """
    SELECT id, runId, jobType, status, bytesTransferred, bytesTotal, durationSeconds, completedAt
    FROM jobResult WHERE runId=?
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    try checkOK(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
    sqlite3_bind_int64(stmt, 1, runId)
    var rows: [JobResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = sqlite3_column_int64(stmt, 0)
        let rId = sqlite3_column_int64(stmt, 1)
        let jobType = JobType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .disk
        let status = JobStatus(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .failed
        let bytesTransferred = sqlite3_column_int64(stmt, 4)
        let bytesTotal = sqlite3_column_int64(stmt, 5)
        let durationSeconds = Int(sqlite3_column_int64(stmt, 6))
        let completedAt: Date? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        rows.append(JobResult(id: id, runId: rId, jobType: jobType, status: status,
                              bytesTransferred: bytesTransferred, bytesTotal: bytesTotal,
                              durationSeconds: durationSeconds, completedAt: completedAt))
    }
    return rows
}
```

- [ ] **Step 6: Run tests to confirm all pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all tests PASSED including the two new DB tests.

- [ ] **Step 7: Commit**

```bash
git add backit/Database/Models.swift backit/Database/DatabaseManager.swift backitTests/DatabaseTests.swift
git commit -m "Add completedAt to JobResult model and DB layer"
```

---

## Task 2: Coordinator — publish per-job results and set them after each job

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`
- Modify: `backitTests/BackupCoordinatorTests.swift`

- [ ] **Step 1: Write two failing tests in `BackupCoordinatorTests.swift`**

Add inside `final class BackupCoordinatorTests`:

```swift
func testPerJobLastResultsSetAfterSuccessfulRun() async throws {
    let diskJob = MockJob(jobType: .disk)
    let dropboxJob = MockJob(jobType: .dropbox)
    let coordinator = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [diskJob, dropboxJob] }
    }
    await coordinator.performBackup()
    let cccResult = await MainActor.run { coordinator.cccLastResult }
    let dropboxResult = await MainActor.run { coordinator.dropboxLastResult }
    let duration = await MainActor.run { coordinator.lastRunDuration }
    XCTAssertNotNil(cccResult)
    XCTAssertEqual(cccResult?.status, .done)
    XCTAssertNotNil(cccResult?.completedAt)
    XCTAssertNotNil(dropboxResult)
    XCTAssertEqual(dropboxResult?.status, .done)
    XCTAssertNotNil(dropboxResult?.completedAt)
    XCTAssertNotNil(duration)
    XCTAssertGreaterThanOrEqual(duration ?? -1, 0)
}

func testPerJobLastResultsSetForFailedJob() async throws {
    let diskJob = MockJob(jobType: .disk)
    diskJob.shouldSucceed = false
    let coordinator = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [diskJob] }
    }
    await coordinator.performBackup()
    let cccResult = await MainActor.run { coordinator.cccLastResult }
    XCTAssertNotNil(cccResult)
    XCTAssertEqual(cccResult?.status, .failed)
    XCTAssertNotNil(cccResult?.completedAt)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: compile error — `coordinator.cccLastResult` does not exist.

- [ ] **Step 3: Add four `@Published` properties to `BackupCoordinator`**

In `BackupCoordinator.swift`, after the existing `@Published var icloudStats: RcloneStats = .idle` line, add:

```swift
@Published var cccLastResult: JobResult? = nil
@Published var dropboxLastResult: JobResult? = nil
@Published var icloudLastResult: JobResult? = nil
@Published var lastRunDuration: TimeInterval? = nil
```

- [ ] **Step 4: Set `completedAt` and update published properties in `performBackup`**

In `performBackup()`, find the block that saves `result` to the DB (currently `try? db.save(&result)`). Replace it with:

```swift
result.completedAt = Date()
try? db.save(&result)
switch job.jobType {
case .disk, .bootable: cccLastResult = result
case .dropbox:         dropboxLastResult = result
case .icloud:          icloudLastResult = result
}
```

Then, directly after `run.completedAt = Date()` and `try? db.save(&run)`, add:

```swift
lastRunDuration = run.completedAt.map { $0.timeIntervalSince(run.startedAt) }
```

- [ ] **Step 5: Set `completedAt` and update published properties in `performSingleJob`**

In `performSingleJob()`, find the block that saves `result` to the DB. Replace it with:

```swift
result.completedAt = Date()
try? db.save(&result)
switch job.jobType {
case .disk, .bootable: cccLastResult = result
case .dropbox:         dropboxLastResult = result
case .icloud:          icloudLastResult = result
}
```

Then, directly after `run.completedAt = Date()` and `try? db.save(&run)`, add:

```swift
lastRunDuration = run.completedAt.map { $0.timeIntervalSince(run.startedAt) }
```

- [ ] **Step 6: Run tests to confirm all pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all tests PASSED including the two new coordinator tests.

- [ ] **Step 7: Commit**

```bash
git add backit/Coordination/BackupCoordinator.swift backitTests/BackupCoordinatorTests.swift
git commit -m "Publish per-job last results from BackupCoordinator after each run"
```

---

## Task 3: Coordinator — restore per-job results at startup

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`
- Modify: `backitTests/BackupCoordinatorTests.swift`

- [ ] **Step 1: Write a failing test in `BackupCoordinatorTests.swift`**

```swift
func testPerJobLastResultsRestoredAtStartup() async throws {
    // Run a backup to populate the DB
    let diskJob = MockJob(jobType: .disk)
    let icloudJob = MockJob(jobType: .icloud)
    let coordinator1 = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [diskJob, icloudJob] }
    }
    await coordinator1.performBackup()

    // Create a fresh coordinator pointing at the same DB (simulates app restart)
    let coordinator2 = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [] }
    }
    let cccResult = await MainActor.run { coordinator2.cccLastResult }
    let icloudResult = await MainActor.run { coordinator2.icloudLastResult }
    let duration = await MainActor.run { coordinator2.lastRunDuration }
    XCTAssertNotNil(cccResult)
    XCTAssertEqual(cccResult?.status, .done)
    XCTAssertNotNil(icloudResult)
    XCTAssertNil(await MainActor.run { coordinator2.dropboxLastResult })  // not in this run
    XCTAssertNotNil(duration)
}
```

- [ ] **Step 2: Run tests to confirm the new test fails**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: `testPerJobLastResultsRestoredAtStartup` FAILED — `cccLastResult` is nil on fresh coordinator.

- [ ] **Step 3: Extend `restoreLastRun()` in `BackupCoordinator.swift`**

Replace the existing `restoreLastRun()` body:

```swift
private func restoreLastRun() {
    guard let run = try? db.fetchRecentRuns(limit: 1).first,
          run.completedAt != nil else { return }
    lastRunDate = run.completedAt
    lastRunStatus = run.status
    let results = (try? db.fetchJobResults(forRun: run.id!)) ?? []
    for r in results {
        switch r.jobType {
        case .disk, .bootable: cccLastResult = r
        case .dropbox:         dropboxLastResult = r
        case .icloud:          icloudLastResult = r
        }
    }
    if let end = run.completedAt {
        lastRunDuration = end.timeIntervalSince(run.startedAt)
    }
}
```

- [ ] **Step 4: Run tests to confirm all pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all tests PASSED including `testPerJobLastResultsRestoredAtStartup`.

- [ ] **Step 5: Commit**

```bash
git add backit/Coordination/BackupCoordinator.swift backitTests/BackupCoordinatorTests.swift
git commit -m "Restore per-job last results and run duration from DB at startup"
```

---

## Task 4: UI — per-job summary line in `JobSectionView` and `RcloneStatusView`

No unit tests — manual build verification only.

**Files:**
- Modify: `backit/UI/BackitMainView.swift`

- [ ] **Step 1: Add `lastResult` parameter and summary logic to `JobSectionView`**

In `struct JobSectionView`, add the parameter after `var onSingleRun`:

```swift
var lastResult: JobResult? = nil
```

In `body`, find the `else { Text("--:--") ... }` branch of the timer section and replace the entire `if/else` chain:

```swift
if progress.status == .running, let startDate {
    TimelineView(.periodic(from: startDate, by: 1.0)) { context in
        Text(elapsed(from: startDate, to: context.date))
            .font(.caption2)
            .foregroundColor(.secondary)
            .monospacedDigit()
    }
} else if let result = lastResult, let completedAt = result.completedAt {
    Text(completionSummary(result: result, completedAt: completedAt))
        .font(.caption2)
        .foregroundColor(result.status == .done ? .green : .red)
        .monospacedDigit()
} else {
    Text("--:--")
        .font(.caption2)
        .foregroundColor(.secondary)
        .monospacedDigit()
}
```

Add two private helpers to `JobSectionView` (alongside the existing `elapsed(from:to:)` and `progressLabel`):

```swift
private func completionSummary(result: JobResult, completedAt: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .short
    fmt.timeStyle = .medium
    let label = result.status == .done ? "completed" : "failed"
    return "\(label) \(fmt.string(from: completedAt)) · \(elapsedFromSeconds(result.durationSeconds))"
}

private func elapsedFromSeconds(_ total: Int) -> String {
    let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
```

- [ ] **Step 2: Add `lastResult` parameter and summary logic to `RcloneStatusView`**

In `struct RcloneStatusView`, add the parameter after `var onSingleRun`:

```swift
var lastResult: JobResult? = nil
```

In `body`, find the `else { Text("--:--")... }` branch of the timer section (inside the `HStack` at the bottom of the view) and replace:

```swift
if stats.status == .running, let startDate {
    TimelineView(.periodic(from: startDate, by: 1.0)) { context in
        Text(elapsed(from: startDate, to: context.date))
            .font(.caption2).foregroundColor(.secondary).monospacedDigit()
    }
} else if let result = lastResult, let completedAt = result.completedAt {
    Text(completionSummary(result: result, completedAt: completedAt))
        .font(.caption2)
        .foregroundColor(result.status == .done ? .green : .red)
        .monospacedDigit()
} else {
    Text("--:--").font(.caption2).foregroundColor(.secondary).monospacedDigit()
}
```

Add the same two helpers to `RcloneStatusView`:

```swift
private func completionSummary(result: JobResult, completedAt: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .short
    fmt.timeStyle = .medium
    let label = result.status == .done ? "completed" : "failed"
    return "\(label) \(fmt.string(from: completedAt)) · \(elapsedFromSeconds(result.durationSeconds))"
}

private func elapsedFromSeconds(_ total: Int) -> String {
    let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(BUILD|error:)'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add backit/UI/BackitMainView.swift
git commit -m "Add per-job completion summary line to job section views"
```

---

## Task 5: Wire coordinator results into views and update bottom bar

**Files:**
- Modify: `backit/UI/BackitMainView.swift`

- [ ] **Step 1: Pass `lastResult` to `JobSectionView` (CCC)**

In `BackitMainView.body`, find the `JobSectionView(...)` call and add `lastResult`:

```swift
JobSectionView(
    title: "Internal disk (CCC)",
    systemImage: "externaldrive.fill",
    sourcePicker: { AnyView(cccTaskPicker) },
    destPicker: { AnyView(cccVolumePicker) },
    progress: coordinator.cccProgress,
    startDate: coordinator.currentJobType == .disk ? coordinator.currentJobStartDate : nil,
    isRunning: coordinator.isRunning,
    lastResult: coordinator.cccLastResult,
    onSingleRun: { coordinator.runSingleJob(.disk) }
)
```

- [ ] **Step 2: Pass `lastResult` to Dropbox `RcloneStatusView`**

```swift
RcloneStatusView(
    title: "Dropbox (rclone)",
    customImage: "dropbox-icon",
    sourcePicker: { AnyView(rcloneRemotePicker) },
    destPicker: { AnyView(rcloneFolderPicker) },
    stats: coordinator.rcloneStats,
    startDate: coordinator.currentJobType == .dropbox ? coordinator.currentJobStartDate : nil,
    isRunning: coordinator.isRunning,
    lastResult: coordinator.dropboxLastResult,
    onSingleRun: { coordinator.runSingleJob(.dropbox) }
)
```

- [ ] **Step 3: Pass `lastResult` to iCloud `RcloneStatusView`**

```swift
RcloneStatusView(
    title: "iCloud Drive (rclone)",
    systemImage: "icloud",
    sourcePicker: { AnyView(icloudRemotePicker) },
    destPicker: { AnyView(icloudFolderPicker) },
    stats: coordinator.icloudStats,
    startDate: coordinator.currentJobType == .icloud ? coordinator.currentJobStartDate : nil,
    isRunning: coordinator.isRunning,
    lastResult: coordinator.icloudLastResult,
    onSingleRun: { coordinator.runSingleJob(.icloud) }
)
```

- [ ] **Step 4: Update bottom bar to show total run duration**

In `BackitMainView.body`, find the bottom bar `if let date = coordinator.lastRunDate, let status = coordinator.lastRunStatus` block. Replace the entire `if/else` (keep the `Text("No backup yet")` else branch and the `Text("Next automatic backup: …")` line that follows — those are unchanged):

```swift
if let date = coordinator.lastRunDate, let status = coordinator.lastRunStatus {
    let fmt = DateFormatter()
    let _ = { fmt.dateStyle = .medium; fmt.timeStyle = .short }()
    let dateStr = fmt.string(from: date)
    let labelStr: String = {
        guard let dur = coordinator.lastRunDuration else { return dateStr }
        let total = Int(dur)
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        let durStr = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
        return "\(dateStr) · \(durStr) total"
    }()
    Label(labelStr,
          systemImage: status == .success ? "checkmark.circle.fill" :
                       status == .skipped ? "minus.circle.fill" :
                       "exclamationmark.triangle.fill")
        .foregroundColor(status == .success ? .green :
                         status == .skipped ? .secondary : .orange)
        .font(.caption)
} else {
    Text("No backup yet").font(.caption).foregroundColor(.secondary)
}
```

- [ ] **Step 5: Run all tests**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all tests PASSED.

- [ ] **Step 6: Commit**

```bash
git add backit/UI/BackitMainView.swift
git commit -m "Wire per-job completion summaries and total duration into main window"
```

---

## Manual Verification Checklist

After completing all tasks, run the app and verify:

1. **After a successful run:** Each job section shows e.g. `completed 10:15:32 AM 4/2/26 · 2:13:34` in green where `--:--` used to appear.
2. **After a failed job:** That job's section shows e.g. `failed 10:15:32 AM 4/2/26 · 0:42` in red.
3. **Bottom bar:** Shows e.g. `Apr 2, 2026 at 10:15 AM · 2:45:12 total`.
4. **App restart:** Quit and relaunch — all three summary lines are still shown (restored from DB).
5. **Before first run:** All sections still show `--:--`.
6. **During a run:** The live elapsed timer still ticks; summary lines are not shown for the running job (they appear after it finishes).
