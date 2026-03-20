# Sleep Prevention + Last-Run Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix "No backup yet" after relaunch and ensure the scheduled backup runs even when the machine has gone to sleep.

**Architecture:** Three self-contained changes: (1) `BackupCoordinator` reads last run from DB on init; (2) `BackupCoordinator` holds a `ProcessInfo` activity token during backup to prevent idle sleep; (3) `LaunchAgentManager` embeds `StartCalendarInterval` in the plist so launchd wakes the machine at backup time, with `AppDelegate` reinstalling on time change and triggering catch-up on startup.

**Tech Stack:** Swift, Foundation (ProcessInfo), SQLite3 (existing DatabaseManager), Combine (existing), XCTest (async test methods required throughout)

**Spec:** `docs/superpowers/specs/2026-03-19-sleep-prevention-last-run-restore-design.md`

---

## File Map

| File | Change |
|------|--------|
| `backit/Coordination/BackupCoordinator.swift` | Add `restoreLastRun()`, `sleepAssertion`, `preventSleep()`, `allowSleep()` |
| `backit/LaunchAgent/LaunchAgentManager.swift` | Add `backupTime: Date = Date()` to `install()`; embed `StartCalendarInterval` |
| `backit/AppDelegate.swift` | Add `import Combine`, `cancellables`; update existing `install()` call; add `$backupTime` observer; add startup catch-up check |
| `backitTests/BackupCoordinatorTests.swift` | Add tests: last-run restore from DB, no restore when run is in-progress |
| `backitTests/LaunchAgentManagerTests.swift` | Add test: plist contains correct `StartCalendarInterval` |

---

## Task 1: Restore last run from DB on startup

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`
- Test: `backitTests/BackupCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `BackupCoordinatorTests.swift` inside `final class BackupCoordinatorTests`:

```swift
func testRestoresLastRunDateAndStatusFromDB() async throws {
    // Insert a completed run directly into the DB
    var run = BackupRun(id: nil,
                        startedAt: Date().addingTimeInterval(-3600),
                        completedAt: Date().addingTimeInterval(-3600),
                        status: .success,
                        macosBuild: "24A1")
    try db.save(&run)

    // Creating a fresh coordinator should pick it up
    let coordinator = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [] }
    }
    XCTAssertNotNil(coordinator.lastRunDate)
    XCTAssertEqual(coordinator.lastRunStatus, .success)
}

func testDoesNotRestoreInProgressRun() async throws {
    // Insert a run with no completedAt (crashed mid-backup)
    // Note: this test will PASS even before implementation because lastRunStatus starts nil.
    // It documents correct post-implementation behavior, not a red/green cycle.
    var run = BackupRun(id: nil,
                        startedAt: Date().addingTimeInterval(-60),
                        completedAt: nil,
                        status: .running,
                        macosBuild: "24A1")
    try db.save(&run)

    let coordinator = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [] }
    }
    XCTAssertNil(coordinator.lastRunDate)
    XCTAssertNil(coordinator.lastRunStatus)
}
```

- [ ] **Step 2: Run the new tests to confirm the restore test fails**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/BackupCoordinatorTests/testRestoresLastRunDateAndStatusFromDB \
  -only-testing:backitTests/BackupCoordinatorTests/testDoesNotRestoreInProgressRun \
  2>&1 | grep -E '(FAILED|PASSED|error:)'
```

Expected: `testRestoresLastRunDateAndStatusFromDB` FAILED, `testDoesNotRestoreInProgressRun` PASSED (it starts nil before implementation too — that's expected).

- [ ] **Step 3: Add `restoreLastRun()` to `BackupCoordinator`**

In `BackupCoordinator.swift`, add a call at the end of `init`:

```swift
init(db: DatabaseManager,
     settings: BackupSettings,
     jobFactory: @escaping @MainActor (BackupSettings) -> [any BackupJob] = BackupCoordinator.defaultFactory) {
    self.db = db
    self.settings = settings
    self.jobFactory = jobFactory
    restoreLastRun()   // ← add this line
}
```

Add the private method after `init`:

```swift
private func restoreLastRun() {
    // fetchRecentRuns is a synchronous SQLite read — no async needed here
    guard let run = try? db.fetchRecentRuns(limit: 1).first,
          run.completedAt != nil else { return }
    lastRunDate = run.completedAt
    lastRunStatus = run.status
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/BackupCoordinatorTests 2>&1 \
  | grep -E '(FAILED|PASSED|error:)'
```

Expected: all BackupCoordinatorTests PASSED.

- [ ] **Step 5: Commit**

```bash
git add backit/Coordination/BackupCoordinator.swift \
        backitTests/BackupCoordinatorTests.swift
git commit -m "Restore last run date/status from DB on coordinator init"
```

---

## Task 2: Prevent idle sleep during backup

**Files:**
- Modify: `backit/Coordination/BackupCoordinator.swift`
- Test: `backitTests/BackupCoordinatorTests.swift`

Note: `ProcessInfo.beginActivity` cannot be directly asserted in unit tests (it calls into the OS). We test the observable contract instead: `isRunning` is true during backup and false after, which is when the assertion is held/released. The sleep assertion is an implementation detail.

- [ ] **Step 1: Write a test confirming isRunning is false after performBackup completes**

This contract already holds, but add an explicit check to document the lifecycle:

```swift
func testIsRunningFalseAfterBackupCompletes() async throws {
    let coordinator = await MainActor.run {
        BackupCoordinator(db: db, settings: settings) { _ in [] }
    }
    await coordinator.performBackup()
    let running = await MainActor.run { coordinator.isRunning }
    XCTAssertFalse(running)
}
```

- [ ] **Step 2: Run the test to confirm it passes (it should — this is documenting existing behavior)**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/BackupCoordinatorTests/testIsRunningFalseAfterBackupCompletes \
  2>&1 | grep -E '(FAILED|PASSED|error:)'
```

Expected: PASSED.

- [ ] **Step 3: Add sleep assertion to `BackupCoordinator`**

Add a stored property and two private methods to `BackupCoordinator.swift`:

```swift
// Add with other private properties (after `private var runningTask`)
private var sleepAssertion: NSObjectProtocol?

private func preventSleep() {
    guard sleepAssertion == nil else { return }
    sleepAssertion = ProcessInfo.processInfo.beginActivity(
        .idleSystemSleepDisabled,
        reason: "Backup in progress"
    )
}

private func allowSleep() {
    sleepAssertion = nil  // endActivity called automatically when token deallocates
}
```

- [ ] **Step 4: Add `preventSleep()` + `defer` to each `perform*` method**

In `performBackup()`, add at the very top of the function body (before `isRunning = true`):

```swift
func performBackup() async {
    preventSleep()
    defer { allowSleep() }
    isRunning = true
    // ... rest unchanged
```

In `performSingleJob(_:)`, same pattern:

```swift
func performSingleJob(_ targetType: JobType) async {
    preventSleep()
    defer { allowSleep() }
    isRunning = true
    // ... rest unchanged
```

In `performVerification()`, same pattern:

```swift
func performVerification() async {
    preventSleep()
    defer { allowSleep() }
    isRunning = true
    // ... rest unchanged
```

- [ ] **Step 5: Run all coordinator tests**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/BackupCoordinatorTests 2>&1 \
  | grep -E '(FAILED|PASSED|error:)'
```

Expected: all PASSED.

- [ ] **Step 6: Commit**

```bash
git add backit/Coordination/BackupCoordinator.swift \
        backitTests/BackupCoordinatorTests.swift
git commit -m "Prevent idle sleep during backup with ProcessInfo activity assertion"
```

---

## Task 3: LaunchAgent wake schedule

**Files:**
- Modify: `backit/LaunchAgent/LaunchAgentManager.swift`
- Test: `backitTests/LaunchAgentManagerTests.swift`

- [ ] **Step 1: Write failing test**

Add to `LaunchAgentManagerTests.swift`:

```swift
func testInstallEmbeddsStartCalendarInterval() throws {
    // Use a specific known time: 23:15
    var comps = DateComponents()
    comps.hour = 23; comps.minute = 15
    let backupTime = Calendar.current.date(from: comps)!

    try sut.install(backupTime: backupTime)

    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data,
                                                           format: nil) as! [String: Any]
    let interval = plist["StartCalendarInterval"] as? [String: Int]
    XCTAssertEqual(interval?["Hour"], 23)
    XCTAssertEqual(interval?["Minute"], 15)
}
```

- [ ] **Step 2: Run the new test to confirm it fails**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests/testInstallEmbeddsStartCalendarInterval \
  2>&1 | grep -E '(FAILED|PASSED|error:)'
```

Expected: FAILED.

- [ ] **Step 3: Update `LaunchAgentManager.install()`**

Replace the current `install()` method in `LaunchAgentManager.swift`:

```swift
func install(backupTime: Date = Date()) throws {
    let execPath = Bundle.main.executablePath ?? "/Applications/backit.app/Contents/MacOS/backit"
    let label = "com.backit.\(NSUserName())"
    let comps = Calendar.current.dateComponents([.hour, .minute], from: backupTime)

    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [execPath],
        "RunAtLoad": true,
        "KeepAlive": false,
        "ProcessType": "Background",
        "StartCalendarInterval": [
            "Hour": comps.hour ?? 23,
            "Minute": comps.minute ?? 0
        ]
    ]

    try FileManager.default.createDirectory(at: agentDirectory,
                                            withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    try data.write(to: plistURL)
}
```

- [ ] **Step 4: Run all LaunchAgentManager tests**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests 2>&1 \
  | grep -E '(FAILED|PASSED|error:)'
```

Expected: all PASSED (existing tests use `install()` with no args; the default parameter preserves them).

- [ ] **Step 5: Commit**

```bash
git add backit/LaunchAgent/LaunchAgentManager.swift \
        backitTests/LaunchAgentManagerTests.swift
git commit -m "Embed StartCalendarInterval in LaunchAgent plist to wake machine at backup time"
```

---

## Task 4: AppDelegate — time-change observer + startup catch-up

**Files:**
- Modify: `backit/AppDelegate.swift`

AppDelegate is not directly unit-testable, but we extract the catch-up decision into a pure function so it can be tested in isolation if needed. The wiring itself is verified by running the app.

- [ ] **Step 1: Add `import Combine` and `cancellables` to `AppDelegate.swift`**

At the top of `AppDelegate.swift`, change:

```swift
import AppKit
import SwiftUI
import UserNotifications
```

to:

```swift
import AppKit
import Combine
import SwiftUI
import UserNotifications
```

Add a stored property inside the `AppDelegate` class (alongside the other `var` declarations):

```swift
private var cancellables = Set<AnyCancellable>()
```

- [ ] **Step 2: Update the initial `install()` call to pass backup time**

In `applicationDidFinishLaunching`, find this line:

```swift
if !launchAgent.isInstalled { try? launchAgent.install() }
```

Replace with:

```swift
if !launchAgent.isInstalled { try? launchAgent.install(backupTime: settings.backupTime) }
```

- [ ] **Step 3: Add `$backupTime` observer to reinstall LaunchAgent on change**

In `applicationDidFinishLaunching`, after the existing LaunchAgent install line, add:

```swift
settings.$backupTime
    .dropFirst()
    .sink { [weak self] newTime in
        try? self?.launchAgentManager?.install(backupTime: newTime)
    }
    .store(in: &cancellables)
```

- [ ] **Step 4: Add the startup catch-up check**

In `applicationDidFinishLaunching`, after wiring `scheduleManager.onBackupTriggered` and `onBackupSkipped` (and after the LaunchAgent install), add:

```swift
// If we launched because launchd fired StartCalendarInterval at backup time,
// the ScheduleManager timer targets tomorrow. Catch up if backup time was
// within the last 5 minutes and no backup has run today.
let backupComps = Calendar.current.dateComponents([.hour, .minute], from: settings.backupTime)
if let lastFired = Calendar.current.nextDate(
    after: Date().addingTimeInterval(-600),
    matching: backupComps,
    matchingPolicy: .nextTime) {
    let elapsed = Date().timeIntervalSince(lastFired)
    let noRunToday = coordinator.lastRunDate.map {
        !Calendar.current.isDateInToday($0)
    } ?? true
    if elapsed >= 0 && elapsed < 5 * 60 && noRunToday {
        coordinator.runBackup()
    }
}
```

Note: `coordinator.lastRunDate` is already populated by `restoreLastRun()` (called in `BackupCoordinator.init`), so the `noRunToday` check is accurate at this point.

- [ ] **Step 5: Build to confirm no compile errors**

```bash
xcodebuild build -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(error:|BUILD SUCCEEDED|BUILD FAILED)'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Run the full test suite**

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' 2>&1 \
  | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all suites PASSED.

- [ ] **Step 7: Commit**

```bash
git add backit/AppDelegate.swift
git commit -m "Wire LaunchAgent time-change observer and startup backup catch-up in AppDelegate"
```

---

## Verification

After all tasks, smoke-test manually:

1. Run the app, confirm the bottom bar shows the last backup date (not "No backup yet") if a backup has run previously.
2. Check `~/Library/LaunchAgents/backit.plist` contains `StartCalendarInterval` with the correct hour/minute.
3. Change the backup time in Settings — recheck the plist to confirm it updated.
4. To test catch-up: set backup time to 2 minutes from now, quit the app, wait for it to re-launch via launchd (or manually launch within the window), confirm backup runs on startup.
