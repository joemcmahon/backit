---
date: 2026-03-18T06:10:55Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 667d5203f87149a3fb31858b62f0c55f930b87ba
branch: main
repository: backit
topic: "Interval-based scheduling and notification debugging"
tags: [swift, schedulemanager, notifications, scheduling, ux]
status: in_progress
last_updated: 2026-03-17
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Interval scheduling done; notifications still not firing in testing

## Task(s)

| Task | Status |
|------|--------|
| Replace absolute reminder times with relative intervals | ✅ Done — commit `667d520` |
| Rename "Preflight warning" → "Final pre-backup check" in UI | ✅ Done |
| Reorder schedule pickers (reminder → preflight → backup) | ✅ Done |
| Add "Next automatic backup: HH:MM" to status bar | ✅ Done |
| Verify notifications fire during live testing | ❌ Still failing — see below |

## Critical References

- `backit/Coordination/ScheduleManager.swift` — all timer/notification logic
- `backit/Settings/BackupSettings.swift` — now uses `preflightIntervalMinutes` + `reminderIntervalMinutes`
- Previous handoff: `thoughts/shared/handoffs/general/2026-03-17_22-42-59_schedule-rework-enter-key-fix.md`

## Recent Changes (this session)

- `backit/Settings/BackupSettings.swift:7-11` — replaced `backupReminderTime`/`preflightWarningTime` Date properties with `preflightIntervalMinutes: Int` (default 30) and `reminderIntervalMinutes: Int` (default 120)
- `backit/Coordination/ScheduleManager.swift:64-87` — `scheduleAllTimers()` now computes fire times via `scheduledPreflightTime()` and `scheduledReminderTime()` helpers; `observeTimeSettings()` updated to observe the new Int properties
- `backit/UI/BackitMainView.swift:246-302` — Schedule section replaced with Picker (presets: 5/10/30/60/120 min) + Custom Stepper; `@State` vars `preflightCustom`/`reminderCustom` control stepper visibility
- `backit/UI/BackitMainView.swift:40-62` — Bottom bar now shows two lines: last run status AND "Next automatic backup: X"
- `backit/UI/SettingsView.swift` — same Picker+Stepper changes as BackitMainView
- `backit/Coordination/ScheduleManager.swift` — added `observeTimeSettings()` via Combine so timers reschedule when settings change (earlier fix in this session)

## The Notification Problem

**Root cause of 11:10 failure:** After switching to interval-based model, default values are `preflightIntervalMinutes=30` and `reminderIntervalMinutes=120`. If the user's `backupTime` is, say, 11:15 PM:
- `scheduledPreflightTime()` = 11:15 PM − 30 min = **10:45 PM** (already past)
- `scheduledReminderTime()` = 10:45 PM − 120 min = **8:45 PM** (already past)

`makeDaily(time:)` uses `Calendar.current.nextDate(after: Date(), matching:)` — if the computed time is in the past, it schedules for **tomorrow**. So no notification fires tonight.

**How to test correctly with the new interval model:**
1. Set `backupTime` to at least `reminderInterval + preflightInterval + 5` minutes from now
2. Use small intervals (5 min each) so both fire soon after setting
3. Example: backup = now + 15 min, preflight = 5 min, reminder = 5 min → reminder fires in 5 min, preflight in 10 min, backup in 15 min

**Earlier failures (also in this session):**
- First test: notifications were OFF in System Settings → Notifications → backit. Enable these first.
- Second test: user was active (in browser talking to Claude) but `isUserActive()` was unclear — now moot since notification perms were off

## Learnings

**Interval model is correct but testing setup matters.** `makeDaily` always finds the NEXT occurrence of a given h:m. If computed time (backupTime − interval) is already past today, the timer schedules for tomorrow. For live testing, the sum of all intervals must be less than the time remaining before `backupTime`.

**`isUserActive()` checks if any `.regular` activation policy app is frontmost** (`isActive = true`). A browser, Xcode, or terminal qualifies. Desktop/screensaver does not. This was confirmed — the guard in `fireBackupReminder()` and `firePreflightWarning()` is correct.

**ScheduleManager timers reschedule on any settings change** via `observeTimeSettings()` Combine sink — confirmed working. Changing backup time or intervals in the UI immediately invalidates old timers and creates new ones.

**`fireBackupTimer()` always runs, no `isUserActive()` check** — this is intentional per user decision. Backup runs silently whether or not user is at keyboard.

**SourceKit false positives** — endemic in this project. All "Cannot find type X" from SourceKit are stale index noise. `xcodebuild build` is authoritative.

## Post-Mortem

### What Worked
- User-story driven design: working through US1.1, US1.2, US2, US3 before coding prevented over-engineering
- Interval model: completely eliminates ordering/clamping complexity, more intuitive UX
- Combine observer on settings changes: timers now live-update without restart
- `xcodebuild build` as ground truth over SourceKit

### What Failed
- Absolute-time DatePicker approach: required clamping logic, ordering enforcement — replaced entirely
- First live test: notifications were off in System Settings
- Second live test (11:10): intervals defaulted to 30/120 min, computed fire times already past → timers scheduled for tomorrow

### Key Decisions
- **Reminder interval relative to preflight, not backup time**: "before final check" is more natural than "before backup"
- **Picker presets + Custom Stepper**: cleaner than raw DatePicker; Custom mode uses `@State preflightCustom` to show/hide Stepper without changing stored value
- **Default intervals**: 30 min for preflight, 120 min for reminder (2 hours before final check)

## Artifacts

- `backit/Coordination/ScheduleManager.swift` — updated timer logic
- `backit/Settings/BackupSettings.swift` — interval properties
- `backit/UI/BackitMainView.swift` — Picker UI + two-line status bar
- `backit/UI/SettingsView.swift` — Picker UI

## Action Items & Next Steps

1. **Debug notifications not firing** — enable System Settings → Notifications → backit if not already done, then test with: backup time = now+15min, preflightInterval=5, reminderInterval=5. Both computed times must be in the future.
2. **Consider adding a "computed times" display** in the settings UI — e.g. "Final check at 10:45 PM · Reminder at 8:45 PM" so the user can see exactly when things will fire without mental math.
3. **Update `ScheduleManagerTests`** — existing 3 tests only cover disk presence and `nextBackupDate`. New interval properties and notification suppression logic are untested.
4. **Commit remaining items** — handoff documents from this session are unstaged.

## Other Notes

- `makeDaily(time:block:)` is in `backit/Coordination/ScheduleManager.swift:83` — uses `Calendar.current.nextDate(after: Date(), matching: [.hour, .minute], matchingPolicy: .nextTime)` + `RunLoop.main.add(t, forMode: .common)`. Always fires tomorrow if time is past.
- `RunStatus.skipped` (`.minus.circle.fill`, secondary color) now distinguished from `.failed` (orange warning) in the status bar — added this session
- Future backup targets brainstorm saved to memory: Gmail, iPhotos, Contacts, Calendar, Reminders, Notes, 1Password, Authenticator.app
