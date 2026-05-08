---
date: 2026-05-13T19:08:52Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 1ca8776
branch: main
repository: backit
topic: "Post-Partition Recovery and iCloud Removal"
tags: [swift, schedulemanager, icloud, rclone, dropbox, launchagent, recovery]
status: complete
last_updated: 2026-05-13
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Post-partition recovery, binary reinstall, iCloud backup removed

## Task(s)

| Task | Status |
|------|--------|
| Diagnose why backups weren't running after disk partition failure | ✅ Done |
| Reinstall correct binary to `/Applications/` (pre-fix build was installed) | ✅ Done |
| Fix `dropboxVolumePath` preference pointing to old volume name | ✅ Done |
| Remove iCloud backup entirely (unreliable auth + no Photos support) | ✅ Done |
| Rebuild and reinstall app post-iCloud removal | ✅ Done |

## Critical References

- `backit/Coordination/BackupCoordinator.swift` — job wiring, lock file, sequential runner
- `backit/Headless/HeadlessRunner.swift` — headless skip logic, notification body
- `backit/Coordination/ScheduleManager.swift` — timer drift fix (already committed as `a681124`)

## Recent Changes

- `1ca8776` — Removed `ICloudJob.swift`, `ICloudJobTests.swift`, all iCloud wiring from `BackupCoordinator`, `BackitMainView`, `BackupSettings`, `HeadlessRunner`, `HelpContent`, tests (521 lines deleted)
- `/Applications/backit.app` — rebuilt and reinstalled May 13 (binary: 2220704 bytes). Previous install was Apr 2 build predating timer drift fix.
- `defaults write com.pemungkah.backit dropboxVolumePath "/Volumes/Dropbox Backup"` — updated from stale `/Volumes/Backblaze_MacEx4TB57422399/Dropbox backup`

## Learnings

### Root Causes Diagnosed This Session

1. **Stale binary** — `/Applications/backit.app` was built Apr 2, before the timer drift fix (`a681124`, Apr 5). After partition failure/restore, user had an old app in `/Applications/`. Result: `ScheduleManager` drift caused runs at 10:50 AM, 13:44, 23:28 instead of 22:55.

2. **Wrong `dropboxVolumePath`** — Disk repartition renamed the backup volume from `Backblaze_MacEx4TB57422399` (with `Dropbox backup` subdirectory) to just `Dropbox Backup`. Preference was never updated. All Dropbox jobs failed instantly from Apr 14 onward.

3. **iCloud auth expiry** — `rclone iclouddrive` cookies expired after partition work. Manifests as `CRITICAL: HTTP error 400 Invalid Session Token` in `/tmp/backit-icloud-rclone-*.log`. Job fails with 0 duration and no DB log lines (fast-fail before rclone produces output). `rclone config reconnect` cannot bootstrap from an invalid token — requires full interactive `rclone config` re-auth.

4. **DB orphaned runs** — When a backup process is killed mid-run, `completedAt` is never set. On next startup, `BackupCoordinator.init()` calls `db.cleanupStaleRuns()` which marks them failed. Runs 85–86 sat as `running` for days until run 87 started.

### Volume Path Pattern

After repartitioning a backup drive, `dropboxVolumePath` preference must be manually updated. The volume name changed — backit has no auto-detection. Check with `ls /Volumes/` and update via Settings UI or `defaults write`.

### Headless + GUI Concurrency

Lock file at `/tmp/backit-backup.lock` (written by `BackupCoordinator.writeLockFile()`, contains PID). `HeadlessRunner.defaultBackupRunningChecker()` reads the PID and uses `kill(pid, 0)` to check liveness — stale locks from crashed processes are handled correctly. If GUI has a backup running when launchd fires at 22:55, headless sends "already in progress" notification and exits. **Correct behavior.** User should close GUI before 22:55 to let headless run uncontested.

### rclone iCloud Backend Limitations

- `rclone-icloud-authenticator` npm package does not exist
- `rclone config reconnect iCloud:` fails when token already invalid  
- Full re-auth requires interactive `rclone config` session
- Backend cannot access Photos library
- Replaced by third-party dedicated iCloud backup app (user's choice)

## Post-Mortem

### What Worked
- DB inspection with `datetime(col,'unixepoch','localtime')` quickly revealed run timing anomalies
- `launchctl print gui/$(id -u)/com.backit.joemcmahon` showed full job state including schedule
- `/tmp/backit-icloud-rclone-*.log` captured exact rclone error text even when DB had no log lines
- `ccc --history` revealed CCC tasks were working fine independently

### What Failed
- `cp -r` over existing `.app` bundle merges instead of replacing — old binary survived. Fix: `rm -rf` first, then `cp -r`.
- Started adding `criticalError` to `RcloneStats` for better auth error surfacing — user decided to remove iCloud instead, change reverted.

### Key Decisions
- **Remove iCloud entirely** rather than fix auth surfacing: rclone iclouddrive is fragile, tokens expire unpredictably, Photos not backed up. Third-party app handles iCloud+Photos better.
- **`dropboxVolumePath` fix via `defaults write`** (not Settings UI): faster, same effect since app reads pref at job creation time.

## Artifacts

- Commits this session: `1ca8776` (iCloud removal)
- Pre-session commit already in place: `a681124` (timer drift fix)
- Binary at `/Applications/backit.app/Contents/MacOS/backit` — May 13 build, 2220704 bytes
- Pref `dropboxVolumePath` = `/Volumes/Dropbox Backup`
- Pref `dropboxRemoteName` = `dropbox`
- Pref `diskCCCTaskName` = `Laptop Backup`

## Action Items & Next Steps

- **Verify tonight's 22:55 run** — first clean headless run with new binary + correct Dropbox path + no iCloud. Check with:
  ```
  sqlite3 ~/Library/Application\ Support/backit/backit.db "SELECT jr.jobType, jr.status, jr.durationSeconds FROM jobResult jr WHERE jr.runId=(SELECT MAX(id) FROM backupRun) ORDER BY jr.id;"
  ```
- **Future work candidates** (from `memory/project_future_backup_targets.md`): per-phase breakdown UI, disk offline message, log button improvements

## Other Notes

- backit is a regular NSWindow app — NOT menubar/status bar
- SourceKit IDE errors ("Cannot find type X in scope") on `BackupJob.swift`, `BackupCoordinator.swift`, etc. are persistent false positives — `xcodebuild` is authoritative
- Test command: `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "(Test Suite|FAILED|PASSED|error:|passed|failed)"`
- All XCTest methods must be `async` for classes in the `backit` module (Swift actor inference crash otherwise)
- Dropbox job now the only rclone job — `rcloneStats`/`lastRcloneSummary` on `BackupCoordinator` are Dropbox-only
- `RcloneStatsParser.swift` and `DropboxJob.swift` unchanged this session
- iCloud replaced by third-party app (user's own solution, not tracked in backit)
