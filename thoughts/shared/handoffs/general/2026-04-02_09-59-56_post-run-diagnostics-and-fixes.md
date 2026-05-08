---
date: 2026-04-02T16:59:55Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: e9e085f18f3b802f3ebd5fe62fe04db9b3c021d0
branch: main
repository: backit
topic: "Post-Run Diagnostics and Bug Fixes"
tags: [swift, rclone, dropbox, icloud, stale-runs, modtime-errors, diagnostics]
status: complete
last_updated: 2026-04-02
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Post-run diagnostic fixes — stale runs + chtimes false-failure

## Task(s)

| Task | Status |
|------|--------|
| Resumed from headless-concurrent-instance-fix handoff | ✅ Done |
| Added per-run timestamped rclone log files | ✅ Complete — commit f717600 |
| Investigated yesterday's run: disk offline, Dropbox 140 errors, UI showing no status | ✅ Root causes found |
| Fixed stale "running" DB records at startup | ✅ Complete — commit 07460ca |
| Fixed chtimes-on-deleted-path errors causing false "failed" job status | ✅ Complete — commit e9e085f |

## Critical References

- `backit/Jobs/BackupJob.swift` — `RcloneStats` struct with `modtimeErrors`, `realErrors`, `onlyRateLimitErrors`
- `backit/Jobs/RcloneStatsParser.swift` — `updateStats()` and `parseError()` with new modtime detection
- `backit/Coordination/BackupCoordinator.swift` — `cleanupStaleRuns()` call at init

## Recent Changes

All changes committed on `main`:

- **f717600** — Per-run timestamped rclone logs:
  - `backit/Jobs/DropboxJob.swift:23-24` — `latestLogFilePath` static var + instance `logFilePath` set at `start()` time with `yyyyMMdd-HHmmss` timestamp
  - `backit/Jobs/ICloudJob.swift:22-23` — same pattern
  - `backit/UI/BackitMainView.swift:556` — uses `DropboxJob.latestLogFilePath` for "Open Full Log" button
  - `backit/UI/HelpContent.swift:313-314` and `docs/user-manual.md:246-247` — updated to describe timestamped paths

- **07460ca** — Stale run cleanup:
  - `backit/Database/DatabaseManager.swift` — added `cleanupStaleRuns()` (marks runs with `completedAt IS NULL` as failed)
  - `backit/Coordination/BackupCoordinator.swift:59` — calls `try? db.cleanupStaleRuns()` before `restoreLastRun()`
  - `backitTests/BackupCoordinatorTests.swift` — renamed `testDoesNotRestoreInProgressRun` → `testCleansUpStaleRunAtStartup`, updated assertions

- **e9e085f** — Modtime false-failure fix:
  - `backit/Jobs/BackupJob.swift:31` — added `modtimeErrors: Int = 0` to `RcloneStats`
  - `backit/Jobs/BackupJob.swift:34-35` — `realErrors` now subtracts `modtimeErrors`; `onlyRateLimitErrors` now requires `rateLimitHits > 0`
  - `backit/Jobs/RcloneStatsParser.swift:22-23` — `parseError()` excludes modtime error lines
  - `backit/Jobs/RcloneStatsParser.swift:113-121` — `updateStats()` detects modtime summary and sets `modtimeErrors = errors`
  - `backit/Jobs/DropboxJob.swift:158-159` and `backit/Jobs/ICloudJob.swift:154-155` — `succeeded` check extended: `|| (currentStats.errors > 0 && currentStats.realErrors == 0)`
  - `backitTests/RcloneStatsParserTests.swift` — 3 new tests for modtime detection

## Learnings

**Why run 69 was stuck as "running":** Process was SIGKILL'd (macOS killed it, likely during PowerNap end) after the disk job result was saved but before the run finalization code executed. The `defer` in `performBackup()` only covers lock file + sleep assertion — the run completion code was NOT in a defer.

**Why chtimes errors occur:** After `rclone sync --ignore-errors` deletes files from a Photos Library, it tries to update modification times on parent directories. Those directories may also have been deleted, causing `chtimes /path: no such file or directory`. These are NOT transfer failures — all 16811 files transferred successfully. Rclone reports `Errors: 140` and exits non-zero, but the summary line says `failed to set directory modtime`.

**Detection approach:** The modtime summary line always contains `failed to set directory modtime` AND `no such file or directory`. This only appears when ALL errors are modtime errors (if there were real copy failures, the summary would report those instead). Setting `modtimeErrors = stats.errors` when this pattern is detected is safe.

**`onlyRateLimitErrors` semantics changed:** Was `errors > 0 && realErrors == 0`. Now `rateLimitHits > 0 && realErrors == 0`. This prevents the UI showing "Done — 0 rate limit hits" for modtime-only runs (falls through to "Complete" instead).

**DB query for diagnosis:**
```
sqlite3 ~/Library/Application\ Support/backit/backit.db \
  "SELECT id, datetime(startedAt,'unixepoch','localtime'), datetime(completedAt,'unixepoch','localtime'), status FROM backupRun ORDER BY id DESC LIMIT 5;"
sqlite3 ~/Library/Application\ Support/backit/backit.db \
  "SELECT runId, jobType, status, durationSeconds FROM jobResult WHERE runId IN (...) ORDER BY runId, id;"
```

## Post-Mortem

### What Worked
- **DB evidence first**: Querying `backupRun` and `jobResult` directly revealed the exact failure modes — stale run 69 and modtime errors in run 70
- **Pattern matching on summary lines**: Detecting `failed to set directory modtime` + `no such file or directory` together is reliable; rclone only emits this when ALL errors are of that type
- **Startup cleanup for SIGKILL resilience**: Can't prevent SIGKILL; can clean up the aftermath at next launch. Simple, idempotent `UPDATE ... WHERE completedAt IS NULL`.

### What Failed
- N/A — diagnosis was straightforward from DB queries; no dead ends

### Key Decisions
- **`modtimeErrors = stats.errors` (not a partial count)**: We can't easily count individual chtimes errors from log lines (rclone batches them). Setting `modtimeErrors = errors` when the modtime summary appears is safe because the summary only appears when that's the last/only error type.
- **Startup cleanup vs. defer**: `defer` doesn't protect against SIGKILL. Startup cleanup of stale runs is the reliable fix. Added no `defer` to finalization code.
- **`onlyRateLimitErrors` semantics tightened**: Changed to require `rateLimitHits > 0` to keep UI message accurate for modtime-only runs.

## Artifacts

- `backit/Jobs/BackupJob.swift:28-35` — `RcloneStats` with `modtimeErrors`, updated `realErrors`, updated `onlyRateLimitErrors`
- `backit/Jobs/RcloneStatsParser.swift:19-27` — `parseError()` with modtime guards
- `backit/Jobs/RcloneStatsParser.swift:110-126` — `updateStats()` with modtime detection
- `backit/Jobs/DropboxJob.swift:23-54` — timestamped log + `latestLogFilePath`
- `backit/Jobs/ICloudJob.swift:22-53` — same
- `backit/Database/DatabaseManager.swift:244-260` — `cleanupStaleRuns()`
- `backit/Coordination/BackupCoordinator.swift:56-60` — init with cleanup call
- `backitTests/BackupCoordinatorTests.swift:130-156` — `testCleansUpStaleRunAtStartup`
- `backitTests/RcloneStatsParserTests.swift:39-68` — 3 new modtime tests

## Action Items & Next Steps

1. **Monitor next overnight run** — verify Dropbox now reports `done` (not `failed`) when only modtime errors occur
2. **Per-run iCloud log button** — there's no "Open Full Log" button for iCloud in the UI yet. Low priority.
3. **Disk job "no status" in UI after offline run** — after a run where disk was offline, the UI shows no details for disk. This is expected (no bytes transferred, status=failed), but could show a friendly message like "Volume offline at backup time."

## Other Notes

- **Build command:** `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'`
- **DB location:** `~/Library/Application Support/backit/backit.db`
- **Lock file:** `/tmp/backit-backup.lock`
- **Rclone logs:** `/tmp/backit-rclone-YYYYMMDD-HHmmss.log` (Dropbox), `/tmp/backit-icloud-rclone-YYYYMMDD-HHmmss.log` (iCloud) — new timestamped format as of f717600
- **Test count:** 65+ tests, all passing
- backit is a **regular NSWindow app** — not menubar, not status bar
