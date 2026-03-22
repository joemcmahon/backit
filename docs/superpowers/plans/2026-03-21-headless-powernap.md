# Headless PowerNap-Compatible Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make backit run silently during macOS sleep/PowerNap when launched by launchd at the scheduled backup time, without waking the screen.

**Architecture:** Add `--headless` to the LaunchAgent plist's `ProgramArguments`. `AppDelegate` detects this flag and hands off to a new `HeadlessRunner` class instead of showing any UI. `HeadlessRunner` waits 30 seconds for devices to settle, runs the backup via the existing `BackupCoordinator`, posts a silent notification with per-job results, then quits.

**Tech Stack:** Swift, Foundation, AppKit, UserNotifications, XCTest

**Spec:** `docs/superpowers/specs/2026-03-21-headless-powernap-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `backit/LaunchAgent/LaunchAgentManager.swift` | Modify | Bump `currentPlistVersion` to 3; add `--headless` to `ProgramArguments`; set `RunAtLoad: false` |
| `backit/AppDelegate.swift` | Modify | Detect `--headless` after core objects created; hand off to `HeadlessRunner`; add `var headlessRunner` property; move UI setup to non-headless path only |
| `backit/Headless/HeadlessRunner.swift` | Create | Settle delay → `performBackup()` → notification → quit |
| `backitTests/LaunchAgentManagerTests.swift` | Modify | Add 2 tests for version-3 plist shape |
| `backitTests/HeadlessRunnerTests.swift` | Create | Unit tests for notification body logic + integration test |

---

## Task 1: Plist version 3

**Files:**
- Modify: `backit/LaunchAgent/LaunchAgentManager.swift`
- Modify: `backitTests/LaunchAgentManagerTests.swift`

### Step 1: Write failing tests

Note: these tests are synchronous `throws` functions — `LaunchAgentManager` is not `@MainActor`
and its tests do not import the `backit` module at the `@MainActor` level. Do NOT add `async`.

- [ ] Add these two tests to `LaunchAgentManagerTests`, after the existing tests:

```swift
func testPlistVersion3HasRunAtLoadFalse() throws {
    try sut.install()
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    let runAtLoad = plist["RunAtLoad"] as? Bool
    XCTAssertEqual(runAtLoad, false)
}

func testPlistVersion3HasHeadlessArgument() throws {
    try sut.install()
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    let args = plist["ProgramArguments"] as? [String] ?? []
    XCTAssertTrue(args.contains("--headless"), "ProgramArguments should contain --headless")
}
```

### Step 2: Run to confirm red

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests \
  2>&1 | grep -E '(Test case|FAILED|PASSED|error:)'
```

Expected: both new tests `FAILED` (RunAtLoad is currently `true`, no `--headless` arg).

### Step 3: Update `LaunchAgentManager`

- [ ] In `LaunchAgentManager.swift`, change `currentPlistVersion` from 2 to 3:

```swift
static let currentPlistVersion = 3
```

- [ ] In `install()`, update the plist dictionary — change `RunAtLoad` to `false` and add `--headless` to `ProgramArguments`:

```swift
let plist: [String: Any] = [
    "Label": label,
    "ProgramArguments": [execPath, "--headless"],
    "RunAtLoad": false,
    "KeepAlive": false,
    "ProcessType": "Background",
    "StartCalendarInterval": [
        "Hour": comps.hour ?? 23,
        "Minute": comps.minute ?? 0
    ],
    "BackitPlistVersion": Self.currentPlistVersion
]
```

### Step 4: Run LaunchAgentManager tests (green)

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests \
  2>&1 | grep -E '(Test case|FAILED|PASSED|error:)'
```

Expected: all 9 `LaunchAgentManagerTests` PASSED (7 existing + 2 new).

### Step 5: Run full test suite

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all suites PASSED, no regressions.

### Step 6: Commit

- [ ] Run:

```bash
git add backit/LaunchAgent/LaunchAgentManager.swift \
        backitTests/LaunchAgentManagerTests.swift
git commit -m "Bump plist to version 3: add --headless arg, set RunAtLoad=false"
```

---

## Task 2: `AppDelegate` restructure

**Files:**
- Modify: `backit/AppDelegate.swift`

There are no unit tests for AppDelegate directly — this task uses build verification only.

### Step 1: Add `headlessRunner` stored property

- [ ] In `AppDelegate`, add a stored property alongside the existing ones (around line 14):

```swift
var helpWindow: NSWindow?
var headlessRunner: HeadlessRunner?   // ← add this line
```

### Step 2: Restructure `applicationDidFinishLaunching`

- [ ] Replace the entire body of `applicationDidFinishLaunching` with the restructured version below. Read the current implementation first to make sure no lines are lost:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Core objects needed by both headless and normal launch paths
    let settings = BackupSettings()
    let db = (try? DatabaseManager()) ?? (try! DatabaseManager(inMemory: true))
    let coordinator = BackupCoordinator(db: db, settings: settings)

    self.settings = settings
    self.db = db
    self.coordinator = coordinator

    // Headless mode: launched by launchd at backup time — no UI, no screen wake
    if CommandLine.arguments.contains("--headless") {
        let runner = HeadlessRunner(db: db, settings: settings, coordinator: coordinator)
        self.headlessRunner = runner
        Task { await runner.run() }
        return
    }

    // Normal (interactive) launch — full UI
    NSApp.setActivationPolicy(.regular)

    let scheduleManager = ScheduleManager(settings: settings)
    let launchAgent = LaunchAgentManager()
    self.scheduleManager = scheduleManager
    self.launchAgentManager = launchAgent

    scheduleManager.onBackupTriggered = { coordinator.runBackup() }
    scheduleManager.onBackupSkipped   = { coordinator.recordSkipped() }

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    registerNotificationCategories(center)

    showMainWindow()

    if launchAgent.needsInstall { try? launchAgent.install(backupTime: settings.backupTime) }

    settings.$backupTime
        .dropFirst()
        .sink { [weak self] newTime in
            try? self?.launchAgentManager?.install(backupTime: newTime)
        }
        .store(in: &cancellables)

    // If launched by launchd at backup time, ScheduleManager targets tomorrow.
    // Catch up if backup time was within the last 5 minutes and no backup has run today.
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
}
```

### Step 3: Build only

- [ ] Run:

```bash
xcodebuild build -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(error:|BUILD SUCCEEDED|BUILD FAILED)'
```

Expected: `BUILD FAILED` with exactly one error: `cannot find type 'HeadlessRunner' in scope`.
That error is correct at this step — `HeadlessRunner.swift` doesn't exist yet. Any other
error indicates a problem with the restructure that must be fixed before proceeding.

Note: SourceKit will show false-positive errors in the editor — ignore them. `xcodebuild` is
the only authoritative check.

### Step 4: Commit

- [ ] Run:

```bash
git add backit/AppDelegate.swift
git commit -m "Restructure AppDelegate: detect --headless flag, defer UI to non-headless path"
```

---

## Task 3: `HeadlessRunner`

**Files:**
- Create: `backit/Headless/HeadlessRunner.swift`
- Create: `backitTests/HeadlessRunnerTests.swift`

### Step 1: Create `HeadlessRunnerTests.swift` with failing tests

Note: all test methods in `HeadlessRunnerTests` must be `async` — `HeadlessRunner` is
`@MainActor` and lives in the `backit` module, so the `@MainActor` executor inference applies.

Note on spec vs plan test names: the spec listed `testRunPostsNotificationOnSuccess` and
`testRunPostsNotificationOnPartial` as test names. The plan implements that intent differently —
by extracting `notificationBody` as a pure static function and testing it directly
(`testNotificationBodyAllSucceeded`, `testNotificationBodyPartial`, etc.). This is intentional:
`UNUserNotificationCenter` cannot be injected in the current design, so the notification body
logic is tested independently. The integration tests (`testRunCallsTerminateHandler`,
`testRunRecordsBackupInDatabase`) cover the end-to-end run path. This fully satisfies the spec's
testing intent.

- [ ] Create `backitTests/HeadlessRunnerTests.swift`:

```swift
import XCTest
import UserNotifications
@testable import backit

final class HeadlessRunnerTests: XCTestCase {
    var db: DatabaseManager!
    var settings: BackupSettings!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(inMemory: true)
        settings = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    // MARK: - Notification body (pure logic, no HeadlessRunner instance needed)

    func testNotificationBodyAllSucceeded() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .done),
            makeJobResult(type: .dropbox, status: .done),
            makeJobResult(type: .icloud, status: .done)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .success, startedAt: startedAt)
        XCTAssertTrue(body.contains("succeeded"), "body: \(body)")
        XCTAssertTrue(body.contains("disk clone"), "body: \(body)")
        XCTAssertTrue(body.contains("Dropbox"), "body: \(body)")
        XCTAssertTrue(body.contains("iCloud"), "body: \(body)")
        XCTAssertFalse(body.contains("failed"), "body: \(body)")
    }

    func testNotificationBodyPartial() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .failed),
            makeJobResult(type: .dropbox, status: .done)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .partial, startedAt: startedAt)
        XCTAssertTrue(body.contains("Dropbox") && body.contains("succeeded"), "body: \(body)")
        XCTAssertTrue(body.contains("disk clone") && body.contains("failed"), "body: \(body)")
    }

    func testNotificationBodyAllFailed() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let results = [
            makeJobResult(type: .disk, status: .failed),
            makeJobResult(type: .dropbox, status: .failed)
        ]
        let body = HeadlessRunner.notificationBody(
            jobResults: results, lastRunStatus: .failed, startedAt: startedAt)
        XCTAssertTrue(body.contains("no jobs completed") || body.contains("failed"), "body: \(body)")
        XCTAssertFalse(body.contains("succeeded"), "body: \(body)")
    }

    func testNotificationBodyNoJobsConfigured() async {
        let startedAt = makeDate(hour: 2, minute: 0)
        let body = HeadlessRunner.notificationBody(
            jobResults: [], lastRunStatus: .success, startedAt: startedAt)
        XCTAssertTrue(body.contains("no jobs configured"), "body: \(body)")
    }

    func testNotificationBodyIncludesTime() async {
        let startedAt = makeDate(hour: 14, minute: 30)
        let body = HeadlessRunner.notificationBody(
            jobResults: [], lastRunStatus: .success, startedAt: startedAt)
        // Time should appear formatted — either "2:30 PM" or locale equivalent
        XCTAssertTrue(body.contains("30"), "body should contain minute: \(body)")
    }

    // MARK: - Integration: run() calls terminateHandler

    func testRunCallsTerminateHandler() async {
        var terminated = false
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { terminated = true }
            )
        }
        await runner.run()
        XCTAssertTrue(terminated)
    }

    func testRunRecordsBackupInDatabase() async {
        let job = MockHeadlessJob(jobType: .dropbox, shouldSucceed: true)
        let coordinator = await MainActor.run {
            BackupCoordinator(db: db, settings: settings) { _ in [job] }
        }
        let runner = await MainActor.run {
            HeadlessRunner(
                db: db,
                settings: settings,
                coordinator: coordinator,
                settleDelay: .zero,
                terminateHandler: { }
            )
        }
        await runner.run()
        let runs = try! db.fetchRecentRuns(limit: 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .success)
    }

    // MARK: - Helpers

    private func makeDate(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 21
        comps.hour = hour; comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    private func makeJobResult(type: JobType, status: JobStatus) -> JobResult {
        JobResult(id: nil, runId: 1, jobType: type, status: status,
                  bytesTransferred: 1024, bytesTotal: 1024, durationSeconds: 1)
    }
}

// Minimal mock job for HeadlessRunnerTests — defined here to avoid cross-file dependency
final class MockHeadlessJob: BackupJob {
    let jobType: JobType
    let progress: CurrentValueSubject<JobProgress, Never>
    private let shouldSucceed: Bool

    init(jobType: JobType, shouldSucceed: Bool) {
        self.jobType = jobType
        self.shouldSucceed = shouldSucceed
        self.progress = CurrentValueSubject(.idle)
    }

    func start() async throws {
        let status: JobStatus = shouldSucceed ? .done : .failed
        progress.send(JobProgress(fraction: 1.0, bytesTransferred: 1024,
                                  bytesTotal: 1024, transferRate: "", status: status))
    }

    func cancel() {
        progress.send(JobProgress(fraction: 0, bytesTransferred: 0,
                                  bytesTotal: 0, transferRate: "", status: .failed))
    }
}
```

### Step 2: Add `HeadlessRunnerTests.swift` to the test target

- [ ] In Xcode: right-click `backitTests` group → Add Files → select `backitTests/HeadlessRunnerTests.swift` → confirm it is added to the `backitTests` target only.

### Step 3: Run to confirm compile failure (red)

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/HeadlessRunnerTests \
  2>&1 | grep -E '(error:|FAILED|PASSED)'
```

Expected: `error: cannot find type 'HeadlessRunner' in scope`

### Step 4: Create `backit/Headless/HeadlessRunner.swift`

- [ ] In Xcode: right-click `backit` group → New Group → name it `Headless`. Then right-click `Headless` group → New File → Swift File → `HeadlessRunner.swift`. Confirm it is added to the `backit` target only.

- [ ] Write the following to `backit/Headless/HeadlessRunner.swift`:

```swift
import AppKit
import UserNotifications

@MainActor
final class HeadlessRunner {
    private let db: DatabaseManager
    private let settings: BackupSettings
    private let coordinator: BackupCoordinator
    private let settleDelay: Duration
    private let terminateHandler: () -> Void

    init(db: DatabaseManager,
         settings: BackupSettings,
         coordinator: BackupCoordinator,
         settleDelay: Duration = .seconds(30),
         terminateHandler: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.db = db
        self.settings = settings
        self.coordinator = coordinator
        self.settleDelay = settleDelay
        self.terminateHandler = terminateHandler
    }

    func run() async {
        try? await Task.sleep(for: settleDelay)
        let startedAt = Date()
        await coordinator.performBackup()
        await postNotification(startedAt: startedAt)
        terminateHandler()
    }

    // MARK: - Notification

    private func postNotification(startedAt: Date) async {
        let recentRun = try? db.fetchRecentRuns(limit: 1).first
        // Use explicit closure return type — Optional.flatMap requires () -> T? not () -> [T]?
        let jobResults = recentRun.flatMap { run -> [JobResult]? in
            try? db.fetchJobResults(forRun: run.id!)
        } ?? []
        let body = Self.notificationBody(jobResults: jobResults,
                                         lastRunStatus: coordinator.lastRunStatus,
                                         startedAt: startedAt)
        let content = UNMutableNotificationContent()
        content.title = "Backit"
        content.body = body
        let request = UNNotificationRequest(identifier: "backit.headless.result",
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // Static so tests can call it without constructing a full HeadlessRunner
    static func notificationBody(jobResults: [JobResult],
                                 lastRunStatus: RunStatus?,
                                 startedAt: Date) -> String {
        let timeString = timeFormatter.string(from: startedAt)

        // No jobs configured: performBackup() records .success with zero JobResults
        if jobResults.isEmpty && lastRunStatus == .success {
            return "Backup skipped at \(timeString) — no jobs configured."
        }

        if jobResults.isEmpty {
            return "Backup failed at \(timeString) — no jobs completed."
        }

        let succeeded = jobResults.filter { $0.status == .done }.map { jobName($0.jobType) }
        let failed    = jobResults.filter { $0.status != .done }.map { jobName($0.jobType) }

        if failed.isEmpty {
            return "Backup completed at \(timeString) — \(listString(succeeded)) succeeded."
        } else if succeeded.isEmpty {
            return "Backup failed at \(timeString) — \(listString(failed)) failed."
        } else {
            return "Backup completed at \(timeString) — \(listString(succeeded)) succeeded; \(listString(failed)) failed."
        }
    }

    // MARK: - Helpers

    private static func jobName(_ type: JobType) -> String {
        switch type {
        case .disk:     return "disk clone"
        case .dropbox:  return "Dropbox"
        case .icloud:   return "iCloud"
        case .bootable: return "bootable clone"
        }
    }

    private static func listString(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default:
            let allButLast = items.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(items.last!)"
        }
    }

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }
}
```

### Step 5: Run HeadlessRunnerTests (green)

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/HeadlessRunnerTests \
  2>&1 | grep -E '(Test case|FAILED|PASSED|error:)'
```

Expected: all 7 `HeadlessRunnerTests` PASSED.

### Step 6: Run full test suite

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all suites PASSED, no regressions.

### Step 7: Commit

- [ ] Run:

```bash
git add backit/Headless/HeadlessRunner.swift \
        backitTests/HeadlessRunnerTests.swift
git commit -m "Add HeadlessRunner: silent background backup with notification on wake"
```

---

## Verification

After all three tasks are committed, smoke-test manually:

1. **Confirm plist updated:** Launch the app normally once (to trigger `needsInstall` reinstall):
   ```bash
   /usr/libexec/PlistBuddy -c "Print :BackitPlistVersion" ~/Library/LaunchAgents/backit.plist
   # Expected: 3
   /usr/libexec/PlistBuddy -c "Print :RunAtLoad" ~/Library/LaunchAgents/backit.plist
   # Expected: false
   /usr/libexec/PlistBuddy -c "Print :ProgramArguments" ~/Library/LaunchAgents/backit.plist
   # Expected: Array { /path/to/backit; --headless; }
   ```

2. **Simulate headless run:** Set backup time to 2 minutes from now, then put the machine to sleep.

3. **Verify silent operation:** Machine wakes at backup time; screen stays off; backit runs in background.

4. **Verify notification:** Wake the machine manually — a "Backit" notification appears with the job summary.

5. **Verify DB record:**
   ```bash
   # Open the database and check the most recent run
   sqlite3 ~/Library/Application\ Support/backit/backit.db \
     "SELECT status, completed_at FROM backup_runs ORDER BY id DESC LIMIT 1;"
   ```

6. **Verify no double-launch on login:** Log out and back in — confirm no headless backup fires at login (RunAtLoad is false).
