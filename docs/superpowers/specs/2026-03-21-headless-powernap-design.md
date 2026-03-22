# Design: Headless / PowerNap-Compatible Backup

**Date:** 2026-03-21
**Status:** Approved

---

## Problem

When macOS is asleep at the scheduled backup time, `StartCalendarInterval` causes launchd to wake
the machine and launch backit. However, `applicationDidFinishLaunching` always opens a window and
activates the app, which wakes the screen and defeats silent background operation. If the machine
is in PowerNap, this is undesirable. The backup runs, but the user's screen lights up.

Additionally, external USB disks need a brief settling period after the machine wakes before they
appear as mounted volumes.

---

## Design

### Detection

`LaunchAgentManager.install()` adds `--headless` as a second entry in `ProgramArguments` and
changes `RunAtLoad` to `false` (see Plist Changes below):

```swift
"ProgramArguments": [execPath, "--headless"]
```

`currentPlistVersion` is bumped to 3. The existing `needsInstall` logic detects the stale plist
and reinstalls automatically on the next user-initiated launch.

`AppDelegate.applicationDidFinishLaunching` is restructured so that the headless check occurs
immediately after the core objects (`db`, `settings`, `coordinator`) are created, but before
`NSApp.setActivationPolicy(.regular)`, `showMainWindow()`, the Combine observer, and the
startup catch-up block:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    let settings = BackupSettings()
    let db = (try? DatabaseManager()) ?? (try! DatabaseManager(inMemory: true))
    let coordinator = BackupCoordinator(db: db, settings: settings)
    // ... store on self ...

    if CommandLine.arguments.contains("--headless") {
        let runner = HeadlessRunner(db: db, settings: settings, coordinator: coordinator)
        self.headlessRunner = runner          // strong reference — see Lifetime note
        Task { await runner.run() }
        return                                // ← early return skips ALL UI and catch-up
    }

    NSApp.setActivationPolicy(.regular)       // only reached in normal (non-headless) launch
    // ... scheduleManager, notifications, showMainWindow(), Combine observer, catch-up ...
}
```

The early return guarantees:
- `NSApp.setActivationPolicy(.regular)` is never called in headless mode
- The startup catch-up block (which calls `coordinator.runBackup()`) never executes, preventing
  a double-backup race
- No window is created; no Combine observers are wired

**Lifetime:** `AppDelegate` adds a `var headlessRunner: HeadlessRunner?` stored property.
This keeps the runner alive until `NSApp.terminate(nil)` is called from within `runner.run()`.

---

### `HeadlessRunner`

New file: `backit/Headless/HeadlessRunner.swift`

```swift
@MainActor
final class HeadlessRunner {
    private let db: DatabaseManager
    private let settings: BackupSettings
    private let coordinator: BackupCoordinator
    private let settleDelay: Duration

    init(db: DatabaseManager,
         settings: BackupSettings,
         coordinator: BackupCoordinator,
         settleDelay: Duration = .seconds(30)) {
        self.db = db
        self.settings = settings
        self.coordinator = coordinator
        self.settleDelay = settleDelay
    }

    func run() async {
        // 1. Settle delay — give USB devices time to spin up after wake
        try? await Task.sleep(for: settleDelay)

        // 2. Record start time for notification
        let startedAt = Date()

        // 3. Run backup (handles partial failures internally)
        await coordinator.performBackup()

        // 4. Notify
        await postNotification(startedAt: startedAt)

        // 5. Quit
        NSApp.terminate(nil)
    }
}
```

`HeadlessRunner` is `@MainActor` because `BackupCoordinator` is `@MainActor`.

---

### Settle Delay

A flat 30-second `Task.sleep` at startup. This gives USB disks time to spin up and mount after the
machine wakes from sleep. 30 seconds is chosen as a conservative upper bound; in practice most
disks appear within 5–10 seconds. If a disk has not appeared within this window, the corresponding
job will fail with its own error — CCC reports its own failure reason — and `performBackup()`
records the partial result normally.

No per-job prerequisite polling is added. The existing failure-handling in `performBackup()` is
sufficient.

The `settleDelay` parameter is injected so tests can pass `.zero` and run instantly.

---

### Notification

Posted via `UNUserNotificationCenter` after `performBackup()` completes. Silent notifications are
held by the OS and delivered on next user wake — they do not wake the screen.

**Permission dependency:** Headless mode does not request notification authorization. It depends
on a prior interactive launch having granted permission. For a personal app where the user has
launched backit at least once, this is always satisfied. If permission has not been granted,
notifications are silently dropped — the backup still runs and is recorded in the database.

**Title:** `Backit`

**Body** (derived from a database query — see Data Source below):

| Outcome | Body |
|---------|------|
| All succeeded | "Backup completed at 2:00 AM — disk clone, Dropbox, and iCloud succeeded." |
| Partial | "Backup completed at 2:00 AM — Dropbox and iCloud succeeded; disk clone failed." |
| All failed | "Backup failed at 2:00 AM — no jobs completed." |
| No jobs configured | "Backup skipped at 2:00 AM — no jobs configured." |

The time shown is `startedAt` formatted in the user's locale (hour and minute only, 12-hour with
AM/PM). No action buttons — informational only.

Notification is posted with `UNMutableNotificationContent`, no trigger (immediate delivery
intent), using a fixed identifier (`"backit.headless.result"`) so repeated headless runs replace
rather than stack the previous notification.

**Data source for per-job attribution:** `BackupCoordinator` resets all per-job `@Published`
progress values to `.idle` by the time `performBackup()` returns, so they cannot be used.
Instead, `HeadlessRunner.postNotification` queries the database:

```swift
let recentRun = try? db.fetchRecentRuns(limit: 1).first
// BackupRun.id is non-nil for all rows returned from fetchRecentRuns (DB always sets it)
let jobResults = recentRun.flatMap { try? db.fetchJobResults(forRun: $0.id!) } ?? []
```

Note: the correct external argument label is `forRun:`. `BackupRun.id` is `Int64?` but is always
non-nil for rows returned from the database; the force-unwrap is safe here. If the DB read fails,
`postNotification` terminates silently with no notification — the backup result is still recorded.

`JobResult` records each job's final `.done` or `.failed` status. The notification body is built
by mapping `jobResults` to human-readable job names ("disk clone", "Dropbox", "iCloud") and
partitioning into succeeded/failed lists.

**"No jobs configured" detection:** When no jobs are configured, `performBackup()` records
`RunStatus.success` with zero `JobResult` rows (empty job list = vacuous success). `HeadlessRunner`
detects this as `jobResults.isEmpty && lastRunStatus == .success` and posts the "no jobs
configured" body. No new `RunStatus` case is needed.

---

### Plist Changes (version 3)

Two changes from version 2:

| Key | Version 2 | Version 3 |
|-----|-----------|-----------|
| `ProgramArguments` | `[execPath]` | `[execPath, "--headless"]` |
| `RunAtLoad` | `true` | `false` |

`RunAtLoad: true` is removed because with `--headless` in `ProgramArguments`, every login would
trigger a headless backup run. `StartCalendarInterval` alone is sufficient to fire backit at the
scheduled time; `RunAtLoad` is no longer needed or desirable.

---

### `performBackup()` — unchanged

No changes to `BackupCoordinator.performBackup()`. It already:
- Runs all configured jobs sequentially
- Records per-job `JobResult` entries to the database
- Derives `.success`, `.partial`, or `.failed` overall status
- Stores `lastRunStatus` and `lastRunDate`

---

## Files Changed

| File | Change |
|------|--------|
| `backit/Headless/HeadlessRunner.swift` | New file |
| `backit/LaunchAgent/LaunchAgentManager.swift` | Add `--headless` to `ProgramArguments`; `RunAtLoad: false`; bump `currentPlistVersion` to 3 |
| `backit/AppDelegate.swift` | Restructure to detect `--headless` after core objects created; store `headlessRunner`; add `var headlessRunner: HeadlessRunner?` property |

---

## Files NOT Changed

- `BackupCoordinator.swift` — unchanged
- `BackupJob` protocol — unchanged
- `CCCJob`, `DropboxJob`, `ICloudJob` — unchanged
- `BackupSettings` — unchanged

---

## Testing

### Unit tests (`HeadlessRunnerTests`)

All test methods must be `async` — `HeadlessRunner` is `@MainActor` and lives in the `backit`
module.

- `testRunPostsNotificationOnSuccess` — mock coordinator sets `lastRunStatus = .success`; mock db
  returns all-succeeded `JobResult`s; assert notification body contains "succeeded"
- `testRunPostsNotificationOnPartial` — mock coordinator sets `lastRunStatus = .partial`; mock db
  returns mixed `JobResult`s; assert notification body names the failing job
- `testRunTerminatesAfterBackup` — assert `NSApp.terminate` called after `performBackup()` returns
- `testSettleDelayIsZeroInTests` — pass `settleDelay: .zero`; confirm test completes instantly
- `testPlistVersion3HasRunAtLoadFalse` — install via `LaunchAgentManager`; read written plist;
  assert `RunAtLoad == false` and `ProgramArguments` contains `"--headless"`

### Manual smoke test

1. Install backit normally (interactive launch) so notification permission is granted.
2. Set backup time to 2 minutes from now.
3. Put machine to sleep.
4. Wait for backup time — machine wakes, screen stays off, backit runs silently.
5. Wake machine manually — notification appears with job summary.
6. Check `~/Library/Application Support/backit/backit.db` — backup run recorded.
7. Check `~/Library/LaunchAgents/backit.plist`:
   - `ProgramArguments` = `["/path/to/backit", "--headless"]`
   - `RunAtLoad` = `false`
   - `BackitPlistVersion` = `3`

```bash
/usr/libexec/PlistBuddy -c "Print :BackitPlistVersion" ~/Library/LaunchAgents/backit.plist
# Expected: 3
/usr/libexec/PlistBuddy -c "Print :RunAtLoad" ~/Library/LaunchAgents/backit.plist
# Expected: false
/usr/libexec/PlistBuddy -c "Print :ProgramArguments" ~/Library/LaunchAgents/backit.plist
# Expected: Array { /path/to/backit; --headless; }
```
