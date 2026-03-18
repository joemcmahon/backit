---
date: 2026-03-18T05:42:59Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: b4506654d4ec485de2fe481b8df6b5eb03eda1e0
branch: main
repository: backit
topic: "Schedule notification rework and backup trigger behavior"
tags: [swift, schedulemanager, notifications, backup, ux]
status: complete
last_updated: 2026-03-17
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Schedule notification rework — awaiting user QA in Xcode

## Task(s)

| Task | Status |
|------|--------|
| Rename `earlyReminderTime`/`lateReminderTime` to `backupReminderTime`/`preflightWarningTime` | ✅ Done |
| Rework notification logic per user-story analysis | ✅ Done |
| Remove Enter key shortcut from Run Backup button | ✅ Done |
| Commit app icon assets | ✅ Done |
| User QA in Xcode | ⏳ Pending |

## Critical References

- `backit/Coordination/ScheduleManager.swift` — all notification/timer logic lives here
- `backit/Settings/BackupSettings.swift` — renamed properties + new UserDefaults keys
- `backit/AppDelegate.swift` — wiring of `onBackupSkipped` closure

## Recent Changes

All changes are in commit `b450665`:

- `backit/Settings/BackupSettings.swift:8-9` — renamed `earlyReminderTime` → `backupReminderTime`, `lateReminderTime` → `preflightWarningTime` (new UserDefaults keys — existing stored prefs reset to defaults: 5pm / 9pm)
- `backit/Coordination/ScheduleManager.swift:11-12` — added `onBackupSkipped: (() -> Void)?` closure
- `backit/Coordination/ScheduleManager.swift:91-121` — reworked all three timer actions (see Learnings)
- `backit/Coordination/BackupCoordinator.swift` — added `recordSkipped()`: sets `lastRunStatus = .skipped` / `lastRunDate = Date()`
- `backit/AppDelegate.swift:31` — wired `onBackupSkipped = { coordinator.recordSkipped() }`
- `backit/AppDelegate.swift` — removed `STOP_WORK` action, replaced `LATE_CHECK` category with `PREFLIGHT_WARNING` (single "Skip Tonight" action)
- `backit/UI/BackitMainView.swift:85` — removed `.keyboardShortcut(.return, modifiers: [])` from Run Backup button
- `backit/UI/BackitMainView.swift`, `backit/UI/SettingsView.swift` — labels updated to "Backup reminder" / "Preflight warning"
- `backit/Assets.xcassets/AppIcon.appiconset/` — app icon assets committed (`9e0e174`)

## Learnings

**User story analysis drove the design.** Before writing code, we worked through the user stories to derive the correct behavior:

- **US1.1** (user asleep, disk connected): backup runs silently at timer time ✅
- **US1.2** (user active, disk connected): backup just runs — no "are you working?" prompt
- **US2** (user active, no disk): preflight warning fires; if user ignores it, backup records `.skipped`
- **US3** (user asleep, no disk): no notification (pointless); backup records `.skipped`

**Key rule that fell out of the analysis:** Only show notifications when the user is active. Silent actions (run backup, record skipped) happen regardless of presence.

**Resulting timer logic:**

| Timer | Disk present | Disk absent |
|-------|-------------|-------------|
| `fireBackupReminder()` | notify if active: "Backup at X tonight" | notify if active: "Backup at X, disk not connected" |
| `firePreflightWarning()` | nothing | notify if active: "Backup imminent, connect drive" |
| `fireBackupTimer()` | run it | call `onBackupSkipped?()` |

**`isUserActive()`** checks `NSWorkspace.shared.runningApplications` for any `.regular` activation policy app that `isActive` (i.e. frontmost). Used in `fireBackupReminder()` and `firePreflightWarning()` only — not at backup time.

**SourceKit false positives are endemic** — all "Cannot find type X in scope" errors from SourceKit are stale-index noise. `xcodebuild build` passes cleanly. Never act on SourceKit warnings.

**Enter key was bound to Run Backup** via `.keyboardShortcut(.return, modifiers: [])` — user accidentally triggered it twice. Removed.

## Post-Mortem

### What Worked
- User-story analysis before coding: prevented over-engineering the `isUserActive()` logic
- Deriving a single unified rule ("only notify when active; always act silently") made the implementation clean and consistent
- `xcodebuild build` as the source of truth over SourceKit diagnostics

### What Failed
- Nothing significant — the implementation fell out cleanly from the analysis

### Key Decisions
- **Always run backup at timer time, never gate on user presence**: The old behavior asked "are you still working?" via LATE_CHECK notification. User preference: just run it.
- **`onBackupSkipped` closure instead of passing status through `onBackupTriggered`**: Keeps the two outcomes semantically distinct and lets `BackupCoordinator.recordSkipped()` be a clean, testable method.
- **New UserDefaults keys for renamed properties**: Simpler than maintaining mismatched key/property names. Existing prefs reset to defaults (5pm / 9pm) — acceptable for a personal dev app.

## Artifacts

- `backit/Coordination/ScheduleManager.swift` — fully reworked
- `backit/Coordination/BackupCoordinator.swift` — `recordSkipped()` added
- `backit/Settings/BackupSettings.swift` — renamed properties
- `backit/AppDelegate.swift` — updated wiring and notification categories
- `backit/UI/BackitMainView.swift` — Enter key removed, label updated
- `backit/UI/SettingsView.swift` — labels updated

## Action Items & Next Steps

1. **User QA**: Build and run in Xcode. Verify:
   - Run Backup button no longer fires on Enter
   - Timed backup fires at scheduled time (test by setting `backupTime` to 2 min from now)
   - `skipTonight` records `.skipped` status in UI
   - No disk → `.skipped` recorded
2. **Update `ScheduleManagerTests`** — existing tests only cover disk presence and `nextBackupDate`. New behavior (notification suppression when idle, `onBackupSkipped` firing) is untested.
3. **Remaining low-priority item**: `retryFailedPaths` temp files still use fixed names `rclone-retry-1.txt`/`rclone-retry-2.txt`. Not urgent (single-job flow, no concurrency).

## Other Notes

- No worktrees in use — all work on `main`
- `RunStatus.skipped` already existed in `backit/Database/Models.swift:4` — no model changes needed
- The `PREFLIGHT_WARNING` notification category is registered in `AppDelegate.registerNotificationCategories()` but the "Skip Tonight" action only sets `settings.skipTonight = true` — the actual skip+record happens at `fireBackupTimer()` time, not at notification response time
- Shard state file `~/Library/Application Support/backit/backup-state.json` may still exist from prior QA runs — safe to delete before testing
