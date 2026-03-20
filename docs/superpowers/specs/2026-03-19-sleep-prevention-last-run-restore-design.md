# Design: Sleep Prevention + Last-Run Restore

**Date:** 2026-03-19
**Status:** Approved

---

## Problems

### 1. "No backup yet" after restart
`BackupCoordinator` initializes `lastRunDate` and `lastRunStatus` as `nil`. The SQLite DB already contains backup history, but nothing reads it into those fields on launch. Result: the UI always shows "No backup yet" after a quit/relaunch.

### 2. Machine sleeps before backup time
The scheduled backup relies on a `Timer` in `ScheduleManager`. If the machine sleeps before the timer fires, the backup never runs. Two sub-cases:
- **Idle sleep**: machine sleeps on its own due to inactivity
- **Manual sleep**: user puts machine to sleep (lid close, Apple menu)

Note: the external disk is connected via a hub on a direct machine USB port (not through the monitor), so display sleep does not cause the disk to unmount.

---

## Design

### Fix 1: Startup last-run restore

**Where:** `BackupCoordinator.init`

Add a private `restoreLastRun()` call at the end of `init`. It queries the DB for the most recent completed run and sets `lastRunDate` / `lastRunStatus`:

```swift
private func restoreLastRun() {
    guard let run = try? db.fetchRecentRuns(limit: 1).first,
          run.completedAt != nil else { return }
    lastRunDate = run.completedAt
    lastRunStatus = run.status
}
```

`fetchRecentRuns(limit:)` is a synchronous SQLite read; no `async` is needed here and `init` does not need to become `async`.

If the most recent run has `completedAt == nil` (app crashed mid-backup), `restoreLastRun()` returns without setting anything and the UI shows "No backup yet." This is deliberate — a run that never completed should not be shown as the last result.

No new tables or queries. Uses `fetchRecentRuns(limit:)` which already exists.

---

### Fix 2a: Activity assertion during backup

**Where:** `BackupCoordinator`

Hold an `NSObjectProtocol` activity token (via `ProcessInfo`, part of Foundation — no additional framework linkage required) while any backup operation is running. This prevents idle system sleep during backup.

```swift
private var sleepAssertion: NSObjectProtocol?

private func preventSleep() {
    guard sleepAssertion == nil else { return }
    sleepAssertion = ProcessInfo.processInfo.beginActivity(
        .idleSystemSleepDisabled,
        reason: "Backup in progress"
    )
}

private func allowSleep() {
    sleepAssertion = nil  // endActivity called automatically on token dealloc
}
```

Call `preventSleep()` at the top of `performBackup()`, `performSingleJob()`, and `performVerification()`. Use `defer { allowSleep() }` immediately after to guarantee the assertion is released even on early returns:

```swift
func performBackup() async {
    preventSleep()
    defer { allowSleep() }
    // ... existing implementation
}
```

This pattern handles all early-return paths in `performSingleJob()` (lines 109 and 113) and any future early returns without requiring per-path `allowSleep()` calls.

---

### Fix 2b: LaunchAgent wake schedule

**Where:** `LaunchAgentManager` + `AppDelegate`

#### Plist change

Add a `backupTime` parameter with a default to `install()` so existing call sites continue to compile without changes:

```swift
func install(backupTime: Date = Date()) throws {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: backupTime)
    plist["StartCalendarInterval"] = [
        "Hour": comps.hour ?? 23,
        "Minute": comps.minute ?? 0
    ]
    // ... rest of install (unchanged)
}
```

launchd fires at this time daily, waking the machine from sleep if needed.

#### Update existing install call in AppDelegate

`AppDelegate.swift` line 44 currently reads:

```swift
if !launchAgent.isInstalled { try? launchAgent.install() }
```

Update to pass the configured time:

```swift
if !launchAgent.isInstalled { try? launchAgent.install(backupTime: settings.backupTime) }
```

#### Reinstall on time change

Add `import Combine` at the top of `AppDelegate.swift` and add a `private var cancellables = Set<AnyCancellable>()` instance property. Then in `applicationDidFinishLaunching`, after setup:

```swift
settings.$backupTime
    .dropFirst()
    .sink { [weak self] newTime in
        try? self?.launchAgentManager?.install(backupTime: newTime)
    }
    .store(in: &cancellables)
```

#### Startup catch-up check

When backit launches (e.g. woken by launchd), the `ScheduleManager` timer is set to the *next* occurrence of backup time — so it won't fire today if we're already past it. Add a check in `applicationDidFinishLaunching` after all objects are initialized and `restoreLastRun()` has run (ordering is guaranteed since `BackupCoordinator.init` runs before this code):

```swift
let backupComps = Calendar.current.dateComponents([.hour, .minute], from: settings.backupTime)
let lastFired = Calendar.current.nextDate(
    after: Date().addingTimeInterval(-600),
    matching: backupComps,
    matchingPolicy: .nextTime
) ?? .distantPast
let elapsed = Date().timeIntervalSince(lastFired)
let noRunToday = coordinator.lastRunDate.map {
    !Calendar.current.isDateInToday($0)
} ?? true

if elapsed >= 0 && elapsed < 5 * 60 && noRunToday {
    coordinator.runBackup()
}
```

If backup time fired within the last 5 minutes and no backup has run today, trigger immediately.

Note: this check calls `coordinator.runBackup()` directly, bypassing `ScheduleManager.fireBackupTimer()`. This means it does **not** respect `settings.skipTonight`. The rationale: if the machine was put to sleep, there was no opportunity to tap "Skip Tonight" at preflight time; waking for a scheduled backup should proceed.

---

## Files Changed

| File | Change |
|------|--------|
| `backit/Coordination/BackupCoordinator.swift` | Add `restoreLastRun()`, `preventSleep()`, `allowSleep()`, `sleepAssertion`; call `restoreLastRun()` at end of `init`; use `preventSleep()` + `defer { allowSleep() }` at top of each `perform*` method |
| `backit/LaunchAgent/LaunchAgentManager.swift` | Add `backupTime: Date = Date()` param to `install()`; embed `StartCalendarInterval` in plist |
| `backit/AppDelegate.swift` | Add `import Combine`; add `cancellables` property; pass `backupTime` to existing `install()` call; observe `settings.$backupTime` to reinstall; add startup catch-up check |

---

## What Is NOT Changed

- `ScheduleManager` — no changes
- Database schema — no changes
- `BackupSettings` — no changes
- UI — no changes

---

## Testing Notes

- All existing tests are async; this change is additive (new methods, no signature changes to tested paths)
- `LaunchAgentManager` existing tests call `install()` with no args — the default parameter preserves this; no test changes needed for existing tests
- New tests to add:
  - `BackupCoordinator`: a DB with a completed run populates `lastRunDate`/`lastRunStatus` on init; a DB with only an in-progress run leaves them nil
  - `LaunchAgentManager`: installed plist contains `StartCalendarInterval` with correct hour/minute when `backupTime` is passed
  - `AppDelegate` startup catch-up: extract the elapsed/noRunToday logic into a pure function for unit testing
