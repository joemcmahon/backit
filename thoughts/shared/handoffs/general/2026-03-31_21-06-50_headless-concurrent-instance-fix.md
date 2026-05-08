---
date: 2026-04-01T04:06:50Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 6f8ae191ce4e1419db07673551acd392375fe9be
branch: main
repository: backit
topic: "Headless Concurrent-Instance Bug — Fix + Diagnostics"
tags: [swift, headless, powernap, concurrent-instances, lock-file, dropbox, debugging]
status: complete
last_updated: 2026-03-31
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Headless concurrent-instance fix — implemented, all tests passing

## Task(s)

| Task | Status |
|------|--------|
| Resumed from headless-powernap-complete handoff; began live testing | ✅ Done |
| Investigated Dropbox backup failures during headless sleep runs | ✅ Root cause found |
| Fixed concurrent-instance bug (headless + interactive both running) | ✅ Complete — uncommitted |
| Save Parachute Backup note to memory | ✅ Done |

**The fix is implemented and all tests pass but has NOT been committed yet.**

## Critical References

- `backit/Headless/HeadlessRunner.swift` — where the guard was added
- `backit/Coordination/BackupCoordinator.swift` — where the lock file is written/removed
- `thoughts/shared/handoffs/general/2026-03-21_22-44-48_headless-powernap-complete.md` — prior handoff

## Recent Changes

All changes are **unstaged/uncommitted** on `main`:

- `backit/Coordination/BackupCoordinator.swift:25-40` — added `backupLockFile` static URL, `writeLockFile()`, `removeLockFile()` methods; called in `performBackup()` and `performSingleJob()` with `defer` cleanup
- `backit/Headless/HeadlessRunner.swift:10,18-21,29-51,54-60` — added `backupRunningChecker: () -> Bool` injected parameter; `run()` now checks it first and posts a "skipped" notification + exits if another instance is active; added `defaultBackupRunningChecker()` static using PID lock file + `kill(pid, 0)`
- `backitTests/HeadlessRunnerTests.swift` — added 2 new tests: `testRunSkipsWhenAnotherInstanceIsBackingUp`, `testRunProceedsWhenNoOtherInstanceIsBackingUp`
- `backitTests/BackupCoordinatorTests.swift` — added `MockJobWithSideEffect` class, 2 new tests: `testLockFileExistsDuringBackup`, `testLockFileRemovedAfterBackup`

## Learnings

**Root cause of Dropbox failures:** Two backit instances were running simultaneously.

Evidence from DB: runs 65 and 66 started 11 seconds apart. Run 65 = interactive instance (6.3 hours, success). Run 66 = headless instance (96 minutes, partial — disk done, dropbox failed, iCloud never ran).

**Why they clobbered each other:**
- Both instances' `DropboxJob.start()` calls `killOrphanedRclones()` (`pkill -f rclone`) ≈1 second apart, killing each other's rclone process
- Both wrote to `/tmp/backit-rclone.log` simultaneously (same fixed path, not per-run)
- Both created separate `backupRun` DB records

**How the headless instance is triggered while interactive is running:**
- User has backit open and running an interactive backup
- `launchd` fires at the scheduled backup time and launches a second headless `backit --headless` process
- Both run `performBackup()` concurrently with no cross-process awareness

**Why iCloud never ran in run 66:** After Dropbox failed, `Task.isCancelled` may have been set (macOS SIGTERM during PowerNap end), OR the run completed normally but iCloud settings were different in that instance context. No iCloud record = it never started.

**`onlyRateLimitErrors` logic is correct but fragile:** `rateLimitHits` counts log lines containing `"too_many_requests"`, `errors` is set from rclone's `Errors: N` stats block. These can differ. For the successful 6-hour run (run 65), they happened to match (17 each). For the killed-early run 66, rclone exited abnormally with errors that didn't generate matching `too_many_requests` log lines.

**`logLine` table is empty** — backit doesn't currently write to it. No per-run rclone logs are persisted. The `/tmp/backit-rclone.log` fixed path gets overwritten every run.

**Lock file mechanism:**
- `BackupCoordinator.backupLockFile` = `/tmp/backit-backup.lock` (cleaned on reboot)
- Contains the writing process's PID as a string
- `kill(pid, 0) == 0` checks if that PID is still alive (handles stale locks from crashes)
- Written before `isRunning = true`; removed via `defer` so survives exceptions

## Post-Mortem

### What Worked
- **DB evidence**: Querying `backupRun` and `jobResult` tables directly revealed the two concurrent runs (IDs 65 and 66) starting 11 seconds apart — this was the key diagnostic breakthrough
- **rclone log**: The `/tmp/backit-rclone.log` file confirmed the successful 6-hour run; all errors were `too_many_requests`, so the transfer itself was fine
- **PID lock file pattern**: Simple, cross-process, handles stale locks via `kill(pid, 0)`. No frameworks needed.
- **Injectable `backupRunningChecker`**: Consistent with existing `terminateHandler`/`notificationPoster` injection pattern in HeadlessRunner; made tests clean

### What Failed
- **System logs**: `log show --predicate 'process == "backit"'` returned nothing — backit doesn't use os_log
- **`logLine` table**: Empty; no per-run rclone output is stored, so the failing run's actual error output was lost
- **Initial theory (Dropbox auth/network)**: Started investigating token expiry and PowerNap network restrictions before the DB data revealed the real cause was concurrent instances

### Key Decisions
- **`/tmp/backit-backup.lock`**: Chosen over `~/Library/Application Support/backit/` because `/tmp` is cleared on reboot (prevents stale locks from persisting across reboots) and is the same location as the rclone log
- **Both `performBackup()` and `performSingleJob()` write lock**: Consistent protection; single-job runs from UI can also conflict with headless
- **Skip without running (not defer)**: Headless instance skips entirely if interactive is running. Doesn't try to wait and run after. Rationale: the interactive instance is already handling it.
- **Notification on skip**: User sees "Backup already in progress — skipping scheduled headless run." so the skip is visible, not silent

## Artifacts

- `backit/Coordination/BackupCoordinator.swift:25-55` — lock file static + methods
- `backit/Coordination/BackupCoordinator.swift:227-234` — `performBackup()` write + defer
- `backit/Coordination/BackupCoordinator.swift:157-164` — `performSingleJob()` write + defer
- `backit/Headless/HeadlessRunner.swift:10` — `backupRunningChecker` stored property
- `backit/Headless/HeadlessRunner.swift:13-27` — updated `init` with new parameter
- `backit/Headless/HeadlessRunner.swift:29-51` — `run()` guard + skip path
- `backit/Headless/HeadlessRunner.swift:54-60` — `defaultBackupRunningChecker()` static
- `backitTests/HeadlessRunnerTests.swift:71-117` — 2 new concurrent-instance tests
- `backitTests/BackupCoordinatorTests.swift:1-22` — `MockJobWithSideEffect`
- `backitTests/BackupCoordinatorTests.swift:155-176` — 2 new lock file tests

## Action Items & Next Steps

1. **Commit the fix** — use `/commit` skill. Suggested message: "Prevent headless instance from clobbering active interactive backup"

2. **Investigate the underlying Dropbox failure** — now that concurrent instances are prevented, the next headless run should either succeed or fail for a different reason. Monitor:
   - Is Dropbox now succeeding in headless mode?
   - If still failing, add per-run rclone log persistence (timestamped file or write to `logLine` table) to capture the actual error

3. **Per-run rclone log** — `/tmp/backit-rclone.log` is overwritten every run. Consider writing to a timestamped path like `/tmp/backit-rclone-{timestamp}.log` or appending run metadata to the `logLine` DB table. Low priority once concurrent-instance bug is confirmed fixed.

4. **Parachute Backup** — user flagged this paid macOS app as a potential replacement for `ICloudJob` (rclone iCloud). It handles iCloud Drive AND Photos incrementally. Saved to memory. No action needed now.

## Other Notes

- **Build command:** `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'`
- **DB location:** `~/Library/Application Support/backit/backit.db` — tables: `backupRun`, `jobResult`, `logLine`
- **rclone log:** `/tmp/backit-rclone.log` — overwritten each Dropbox or iCloud job run
- **Lock file:** `/tmp/backit-backup.lock` — written by `BackupCoordinator.performBackup()` / `performSingleJob()`; cleaned on reboot
- Full test suite: 65+ tests, all passing after this change
- `xcodebuild -runFirstLaunch` may be needed if build fails with IDESimulatorFoundation plugin error
- backit is a **regular NSWindow app** — not menubar, not status bar
