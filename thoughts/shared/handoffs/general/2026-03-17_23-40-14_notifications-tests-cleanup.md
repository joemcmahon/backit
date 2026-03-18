---
date: 2026-03-18T06:40:14Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 19768c5353d4b8f98fed79058887ca707a9568e8
branch: main
repository: backit
topic: "Notification verification, test updates, and UI cleanup"
tags: [swift, schedulemanager, notifications, testing, ui]
status: complete
last_updated: 2026-03-17
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Notifications verified, tests green, SettingsView removed

## Task(s)

| Task | Status |
|------|--------|
| Verify notifications fire during live testing | ✅ Done — 11:20 PM reminder fired and stayed up |
| Add computed times display to schedule sheet | ✅ Done — commit `9083996` |
| Remove dead `SettingsView` | ✅ Done — commit `9083996` |
| Notify user when backup skipped due to missing drive | ✅ Done — commit `14ee13d` |
| Update `ScheduleManagerTests` for interval model | ✅ Done — commit `19768c5` |
| Fix stale `RcloneStatsParserTests` (JSON API removed) | ✅ Done — commit `19768c5` |

## Critical References

- `backit/Coordination/ScheduleManager.swift` — all timer/notification logic
- `backit/Settings/BackupSettings.swift` — `preflightIntervalMinutes` + `reminderIntervalMinutes`
- Previous handoffs: `thoughts/shared/handoffs/general/2026-03-17_23-10-55_interval-scheduling-notification-debugging.md`

## Recent Changes

- `backit/UI/BackitMainView.swift:264-269` — added `computedTimesLabel` computed property to `ScheduleSheetView`; shows "Reminder X · Final check Y · Backup Z" caption at bottom of Schedule section
- `backit/UI/BackitMainView.swift:312-314` — added `Text(computedTimesLabel)` caption to Schedule section
- `backit/UI/SettingsView.swift` — **deleted** (was dead code, never referenced anywhere)
- `backit/Coordination/ScheduleManager.swift:133-134` — added `notify()` call in `fireBackupTimer()` when disk not present, so backup-skipped is no longer silent
- `backitTests/ScheduleManagerTests.swift` — added `testDefaults` property; 6 new tests covering defaults, persistence, and computed fire times
- `backitTests/RcloneStatsParserTests.swift` — replaced stale JSON-based tests with line-based `updateStats`/`parseTimestamp`/`extractFileCount` tests

## Learnings

**Notification testing setup:** With the interval model, all computed times must be in the future when the app launches. Testing with backup=now+15min, preflight=5min, reminder=5min works reliably.

**`isUserActive()` guard:** `fireBackupReminder()` and `firePreflightWarning()` silently skip if no `.regular` activation policy app is frontmost. Normal at 11:25 PM if screen is locked — not a bug.

**Backup timer requires relaunch after build:** Timers are created at init; if the app is rebuilt while running, old timers are gone. Tested: after relaunch, backup fired correctly at scheduled time.

**`@Published` willSet ordering with Combine:** The Combine sink in `observeTimeSettings()` fires during `willSet`, at which point the property still has the old value. The real-app Combine rescheduling works (confirmed live), but a unit test asserting `nextBackupDate` changes synchronously is unreliable — removed that test.

**XCTest async crash pattern (documented in project memory):** Synchronous test methods that create/destroy `BackupSettings` (or other `backit`-module classes with `@MainActor` inference) crash via `swift_task_deinitOnExecutorImpl`. Fix: make test methods `async`.

**`SettingsView` was dead code:** Never referenced anywhere in the app. All its settings fields are covered by `ScheduleSheetView` (schedule/history/tonight/verify) plus the main view pickers (CCC task, Dropbox remote, volume path).

## Post-Mortem

### What Worked
- Live notification test with small intervals (5/5 min) confirmed everything fires correctly
- Deleting dead `SettingsView` rather than trying to wire it up — cleaner codebase
- `computedTimesLabel` as a computed property: reactive to `@Published` changes, no extra state needed
- Making persistence test methods `async` to avoid the known XCTest deinit crash

### What Failed
- `testNextBackupDateUpdatesWhenBackupTimeChanges`: attempted to test Combine rescheduling with `Task.sleep`, but unreliable due to `@Published` `willSet` ordering — removed
- First backup attempt missed (app rebuilt mid-session, new timers needed relaunch)

### Key Decisions
- **Silent skip → notification:** `fireBackupTimer()` now notifies when disk is offline. `skipTonight` remains silent (user's intentional choice).
- **Deleted `SettingsView`:** Was empty in practice (never wired up). No CCC/Dropbox text-field fallback needed since main view has menus populated from live data.
- **Dropped Combine rescheduling test:** Tests infrastructure timing, not domain logic. Real-app behavior confirmed working.

## Artifacts

- `backit/UI/BackitMainView.swift` — `ScheduleSheetView` with computed times caption
- `backit/Coordination/ScheduleManager.swift` — backup-skipped notification
- `backitTests/ScheduleManagerTests.swift` — 9 tests, all passing
- `backitTests/RcloneStatsParserTests.swift` — 5 tests, all passing

## Action Items & Next Steps

1. **Run full test suite** — only `ScheduleManagerTests` and `RcloneStatsParserTests` were run this session; confirm no regressions elsewhere
2. **Test backup-skipped notification** — connect drive, set backup time, disconnect drive, wait for timer to fire; verify "Backup Skipped" notification appears
3. **Task 10 (rclone + CCC live backup)** — per project memory, requires CCC running + backup drive + rclone. Warn user before starting.

## Other Notes

- All commits in this session: `9083996`, `782b9dc`, `14ee13d`, `19768c5`
- 14/14 tests passing across `ScheduleManagerTests` and `RcloneStatsParserTests`
- Backup fired successfully at 11:33 PM during live testing (after relaunch)
- `ScheduleManager.makeDaily(time:block:)` at `:91` — schedules for tomorrow if computed time is past; this is correct behavior
- SourceKit false positives are endemic in this project; `xcodebuild build` is authoritative
