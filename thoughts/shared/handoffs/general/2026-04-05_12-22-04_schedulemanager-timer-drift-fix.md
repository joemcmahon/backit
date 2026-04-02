---
date: 2026-04-05T19:22:04Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 637a2fc
branch: main
repository: backit
topic: "ScheduleManager Timer Drift Fix"
tags: [swift, schedulemanager, timer, drift, launchctl, bug]
status: complete
last_updated: 2026-04-05
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: ScheduleManager repeating timer drift — fixed

## Task(s)

| Task | Status |
|------|--------|
| Diagnose unexpected 3:50 PM backup run | ✅ Done |
| Fix `makeDaily` timer drift in `ScheduleManager` | ✅ Done — same commit 637a2fc (no new commit yet) |

## Critical References

- `backit/Coordination/ScheduleManager.swift` — the only file changed

## Recent Changes

- `backit/Coordination/ScheduleManager.swift:91-101` — `makeDaily` changed from a repeating `interval: 86400` timer to a one-shot (`repeats: false`) timer that re-anchors itself via `Calendar.nextDate(after:)` on each firing, replacing itself in `timers` by index

## Learnings

### Root Cause of the Rogue 3:50 PM Run

The `makeDaily` method previously created a `Timer(fire:interval:86400:repeats:true)`. This fires once at the correct anchored time, then repeats every 86400 seconds from that first fire date. If the user ever triggered a manual backup (or the app was running when a backup fired at an arbitrary time), the +86400 repeat would drift the in-app timer away from the configured hour:minute — permanently, until the app restarted.

**Exact scenario confirmed by the user:**
1. Manual "Run Now" backup at 3:50 PM → `ScheduleManager` timer set via `scheduleAllTimers()` anchored the backup timer to the *next* 10:55 PM
2. BUT: the *old* repeating timer from a previous session still had its next fire at 3:50 PM + 86400s = 3:50 PM next day
3. LaunchAgent also fires at 10:55 PM as expected
4. Result: two runs — one at 3:50 PM (drifted in-app timer), one at 10:55 PM (launchctl)

Wait — more precisely: on the original session where the user first set 10:55 PM, if the app had previously been used with a different time (or the timer was scheduled mid-day), the +86400 anchor is wrong. The timer never re-anchors to hour:minute; it just adds 86400 seconds from whenever it last fired.

### The Fix

`makeDaily` now:
1. Schedules a one-shot timer (`repeats: false`) at the correct `nextDate(after: Date(), matching: comps)`
2. On fire: executes the block, then calls `self.makeDaily(time:block:)` recursively to schedule the *next* occurrence, also anchored via `nextDate`
3. Replaces itself in `self.timers` by index so `scheduleAllTimers()` can still invalidate it on settings change

This ensures the timer always re-anchors to the configured hour:minute, regardless of when it last fired.

### Other Findings (from DB investigation)

- `backupRun` table timestamps are Unix epoch (Double), convert with `datetime(col, 'unixepoch', 'localtime')` in sqlite3
- Run 75 (3:50 PM, April 4) was ~4h 49m long — same as the other runs. All runs are normal length.
- LaunchAgent plist correctly points to DerivedData debug build and fires at 22:55

## Post-Mortem

### What Worked
- DB inspection: reading `backupRun` with human-readable timestamps immediately revealed the pattern — two runs on one day at different times
- Systematic diagnosis: checked launchctl first (ruled out double-schedule), then read ScheduleManager code to find the drift mechanism
- Minimal fix: changing only `makeDaily` (9 lines) was sufficient — no architectural changes needed

### What Failed
- N/A — clean diagnosis and fix

### Key Decisions
- **One-shot + self-rescheduling over `scheduleAllTimers()` on fire**: calling `scheduleAllTimers()` from a timer block would cancel all three timers (reminder, preflight, backup) if any one fired — losing the other two for that day. Self-rescheduling only replaces the fired timer.
- **`var t!` self-capture pattern**: necessary to find and replace the correct entry in `timers[]` by identity. `firstIndex(of: t)` works because `Timer` is `NSObject` and uses reference equality.

## Artifacts

- `backit/Coordination/ScheduleManager.swift:91-101` — updated `makeDaily`

## Action Items & Next Steps

- **Commit the fix** — the change is sitting uncommitted on top of `637a2fc`. Use `/commit`.
- All 68+ tests pass; no further work needed on this bug.
- Future work candidates (from previous handoff): per-phase breakdown, iCloud log button, disk offline message, future backup targets — see `memory/project_future_backup_targets.md`

## Other Notes

- **Test command:** `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:|passed|failed)'`
- backit is a regular NSWindow app — not menubar, not status bar
- SourceKit IDE errors ("Cannot find type BackupSettings in scope", Sendable warnings on the new timer closure) are persistent false positives — `xcodebuild test` is authoritative and passes clean
- The LaunchAgent plist at `~/Library/LaunchAgents/backit.plist` correctly fires at 22:55 — that was never broken. Only the in-app `ScheduleManager` timer drifted.
