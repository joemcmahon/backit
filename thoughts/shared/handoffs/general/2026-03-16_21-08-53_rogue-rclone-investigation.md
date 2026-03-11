---
date: 2026-03-17T04:08:53Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 820ef39950aee07c6f7db028bf8a54cdfe0e1965
branch: main
repository: backit
topic: "QA run — rogue rclone investigation"
tags: [swift, rclone, debugging, dropboxjob, sharding, qa]
status: in_progress
last_updated: 2026-03-16
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: QA run observations — rogue rclone + apparent verify with verify off

## Task(s)

The depth-first density sharding feature (Tasks 1–6) is **fully complete and committed**.
All 86+ tests pass. The feature is on `main`.

During a QA live-run, two anomalies were observed:

| Observation | Status |
|-------------|--------|
| Task 6 dead code removal | ✅ Committed `65ff290` |
| Beachball at shard switch (main-thread file I/O) | ✅ Fixed + committed `820ef39` |
| Rclone running while "Run Backup" button shown, no shards | 🔍 Under investigation |
| "Verify is off, but we seem to be verifying" | 🔍 Likely misread — see Learnings |

## Critical References

- `backit/Coordination/BackupCoordinator.swift` — coordinator logic, `performBackup`, `runShardedDropboxSync`, `runShardedVerify`
- `backit/Jobs/DropboxJob.swift` — rclone invocation, `retryFailedPaths`, `runVerification`
- `docs/superpowers/plans/2026-03-15-depth-first-density-sharding.md` — completed feature plan

## Recent Changes

- `backit/Backup/ShardDiscoverer.swift:1-70` — removed `measureSizes`, `packShards`, `targetShardCount`, `expandOversizedDirs`, `countFiles`, `maxTransfersForFileCount` and private helpers
- `backit/Coordination/BackupCoordinator.swift:23` — removed `@Published var scanningFileCount: Int = 0`
- `backit/UI/BackitMainView.swift:32-40` — simplified `scanLabel` to not reference `scanningFileCount`
- `backit/Jobs/DropboxJob.swift:69-85` — moved `--files-from`/`--filter-from` temp file writes into `Task.detached` to avoid main-thread stall at each shard switch
- `backitTests/ShardDiscovererTests.swift` — removed tests for deleted functions

## Learnings

**SourceKit false positives are endemic.** All "Cannot find type X in scope" diagnostics are stale-index false positives. `xcodebuild test` succeeds cleanly. Never act on SourceKit warnings without running an actual build.

**"Checks: N" in rclone stats ≠ verification.** `rclone sync/copy` always emits "Checks: N" for files it compared but didn't transfer. The user seeing "Checks" going up during sync does NOT mean `rclone check` (verify) is running. `runShardedVerify` is only called from `performVerification()`, never from `performBackup()`.

**Two-instances problem is real.** The memory already documents: "Stale process from previous Xcode run can hide new menubar icon — kill via Activity Monitor". The "rclone running while button says Run Backup" symptom is consistent with two app instances: old instance running its backup, new instance showing idle state. User confirmed this was likely the cause; they stopped the Xcode-spawned instance and plan to re-run.

**`retryFailedPaths` still uses fixed temp file names** (`rclone-retry-1.txt`, `rclone-retry-2.txt`). Pre-existing minor issue; concurrent retries across shards could collide. Not urgent since shards are sequential.

**50,502 shards is normal** with `skinnyThreshold=20` on a large Dropbox. Each shard is fast (most files already synced). No need to tune threshold down.

**`ThrottleHintsStore.shared` warning:** `nonisolated(unsafe)` is unnecessary since `ThrottleHintsStore` is already `Sendable`. The original `ShardDiscoverer.swift:64` error about `shared` is a SourceKit false positive — xcodebuild passes cleanly.

## Post-Mortem

### What Worked
- Subagent-driven development for Tasks 1–5: high quality, minimal rework
- Resuming stalled subagents with "Yes, proceed" immediately unblocked them
- The `Task.detached` fix for main-thread temp file writes was minimal and clean
- `nonisolated(unsafe)` attempted then correctly reverted when compiler explained it was redundant

### What Failed
- Context grew to 87% before QA observations could be fully resolved — required handoff
- First grep for test results used a filter that truncated the output (missed unit test pass/fail lines)

### Key Decisions
- Moved temp file writes to `Task.detached` (not `DispatchQueue.global`) to match Swift concurrency model used elsewhere in the file
- Did NOT instrument rclone logging yet — user wants to re-run first with a clean single instance before adding tracing

## Artifacts

- `backit/Backup/ShardDiscoverer.swift` — dead code removed
- `backit/Backup/ThrottleHintsStore.swift` — unchanged (nonisolated(unsafe) added then reverted)
- `backit/Coordination/BackupCoordinator.swift` — `scanningFileCount` removed
- `backit/UI/BackitMainView.swift` — `scanLabel` simplified
- `backit/Jobs/DropboxJob.swift` — temp file writes off main thread
- `backitTests/ShardDiscovererTests.swift` — dead tests removed
- `docs/superpowers/plans/2026-03-15-depth-first-density-sharding.md` — completed plan (reference)

## Action Items & Next Steps

1. **Re-run QA with a single app instance** — user is doing this now. If the anomalies disappear, the two-instances explanation is confirmed and no code changes are needed.

2. **If anomalies persist, instrument `BackupCoordinator`** — add `print("[BackupCoordinator] isRunning=\(isRunning) entering \(#function)")` at key entry points to trace what's triggering rclone outside the normal flow. Key places to instrument:
   - `performBackup()` entry/exit
   - `performVerification()` entry/exit
   - `runShardedDropboxSync` per-shard loop start
   - `runShardedVerify` per-shard loop start
   - `ScheduleManager.fireBackupTimer()`

3. **If two-instance issue confirmed** — consider adding `NSRunningApplication` check at startup to detect and warn about duplicate instances. Low priority.

4. **`retryFailedPaths` temp file collision** — change `rclone-retry-\(attempt).txt` to `rclone-retry-\(UUID().uuidString)-\(attempt).txt`. Pre-existing minor issue, safe to fix opportunistically.

5. **Debug `print()` cleanup** — handoff from previous session noted debug prints in `DropboxJob` and `AppDelegate`. Remove before release.

## Other Notes

- No worktrees — all work on `main`, clean working tree
- Backup is running live during QA with ~50,502 shards; running "fairly rapidly"
- `runShardedVerify` is NOT called from `performBackup` — only from `performVerification()` (triggered by "Run Verify" button or `runVerifyOnly()`)
- The QA run showed the backup correctly retrying CCC when disk offline and resuming rclone — that behavior is correct/expected
- `ScheduleManager.fireBackupTimer` calls `onBackupTriggered?()` only when `!isUserActive()` — so it won't auto-start while user is actively QA-ing
- `AppDelegate` notification handler has a bug: `case "STOP_WORK": coordinator?.runBackup()` — this fires when user taps "I've Stopped — Back Up Now" notification action. This is intentional per the feature design, not a bug.
