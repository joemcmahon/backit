---
date: 2026-03-17T06:23:04Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: a2909c6bf54ca198558ab190a288b24df31f0be1
branch: rollback-verify
repository: backit
topic: "Depth-first sharding QA — rollback to pre-sharding baseline"
tags: [swift, rclone, sharding, rollback, dropboxjob, qa]
status: complete
last_updated: 2026-03-16
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Sharding rolled back — verify branch ready, main still needs reset

## Task(s)

| Task | Status |
|------|--------|
| QA run analysis (rogue rclone, post-cancel activity) | ✅ Root-caused |
| Threshold tuning (20 → 1000) | ✅ Tried — insufficient (36,000 shards remain) |
| Decision to roll back depth-first sharding | ✅ Made |
| Create `rollback-verify` branch at `a2909c6` | ✅ Done — verified correct |
| Reset `main` to `a2909c6` | ⏳ Pending user confirmation after Xcode verification |

## Critical References

- `backit/Coordination/BackupCoordinator.swift` — now back to simple sequential CCC → DropboxJob, no sharding
- `backit/Jobs/DropboxJob.swift` — back to single `rclone sync`, no `excludes`/`filesFrom` params
- Previous handoff: `thoughts/shared/handoffs/general/2026-03-16_21-08-53_rogue-rclone-investigation.md`

## Recent Changes

All sharding-related commits (from `5967875` through `820ef39`) have been rolled back on `rollback-verify`. The branch is now at `a2909c6` (pre-sharding). No source files were edited in this session beyond the `skinnyThreshold: 1000` experiment (which is also gone after the reset).

**Files that no longer exist on `rollback-verify`:**
- `backit/Backup/ShardDiscoverer.swift`
- `backit/Backup/ShardStateManager.swift`
- `backit/Backup/ThrottleHintsStore.swift`
- `backit/UI/ResumeBackupSheet.swift`
- `backitTests/ShardDiscovererTests.swift`
- `backitTests/ThrottleHintsStoreTests.swift`
- (any other files added exclusively by the sharding feature)

## Learnings

**Why sharding failed for large Dropbox:**
- `skinnyThreshold=20` produced 50,502 shards; bumping to 1000 still produced 36,000 shards
- The floor is the number of non-empty directories (~36,000), not file count — threshold only affects directories above the threshold
- Per-shard cost: 1 rclone process startup + 1 `--fast-list` round-trip to Dropbox API ≈ 5-6 sec/shard → ~50+ hours for a full pass
- The `fileChunk` approach (splitting wide dirs into batches) made it worse: each `--files-from` chunk still paid the full `--fast-list` cost for the entire parent directory. Camera Uploads (8,000 files) → 400 chunks × listing 8,000 files = 3.2M file-listings vs. a single sync listing 8,000 once

**`cancelBackup()` race condition (pre-existing, NOT fixed, still on rollback baseline):**
- `cancelBackup()` sets `isRunning = false` synchronously before `performBackup()` finishes
- This allows `runBackup()` (or `ScheduleManager`) to start a second backup while the first is still in cleanup
- Root cause of the "something restarted the rclone syncs" observation during QA
- Fix: do NOT set `isRunning = false` in `cancelBackup()`; let `performBackup()` own that transition; or add an `isCancelling` flag

**Post-cancel rclone activity (pre-existing, NOT fixed):**
- After `cancelBackup()`, `DropboxJob.start()` continues running `retryFailedPaths()` and `cleanupFailedDirectories()` — neither checks `Task.isCancelled` before spawning new rclone processes
- The per-shard `statsTask`/`progressTask` (unstructured `Task {}`) are not cancelled by `runningTask.cancel()`, so they continue forwarding rclone stats to the UI

**"Checks: N" in rclone stats ≠ verify running** — rclone sync/copy always emits Checks for files it compared. `runVerification()` is only called from `performVerification()`.

**Status bar shows "No backup yet" until `performBackup()` finishes** — `lastRunStatus` and `lastRunDate` are only set at the very end of `performBackup()`, not during. `BackupCoordinator` does not load prior run state from the DB on init.

**SourceKit false positives are endemic** — all "Cannot find type X in scope" from SourceKit are stale-index noise. `xcodebuild test` passes cleanly. Never act on SourceKit warnings without running an actual build.

## Post-Mortem

### What Worked
- The depth-first density sharding design was technically correct and all 86+ tests passed
- Subagent-driven implementation was high quality with minimal rework
- `git reset --hard` on a dedicated verification branch before touching `main` was the right safety approach — confirmed correct rollback before committing

### What Failed
- Sharding overhead was fundamentally misestimated: assumed shard count would be 500-2000, actual was 36,000+
- The `fileChunk` optimization for wide directories inadvertently multiplied `--fast-list` cost per chunk
- Tuning `skinnyThreshold` from 20 to 1000 reduced shard count by only ~28% — the floor is directory count, not threshold

### Key Decisions
- **Roll back entirely rather than patch**: The sharding approach has a fundamental overhead floor proportional to Dropbox directory count. No threshold tuning fixes this. A single `rclone sync` is better for the "mostly synced" incremental case.
- **`rollback-verify` branch first**: Verified the reset was correct before touching `main`.

## Artifacts

- `thoughts/shared/handoffs/general/2026-03-16_21-08-53_rogue-rclone-investigation.md` — prior session handoff with full QA run details
- `docs/superpowers/plans/2026-03-15-depth-first-density-sharding.md` — completed (now moot) plan for the rolled-back feature

## Action Items & Next Steps

1. **Reset `main` to `a2909c6`** (if Xcode verification passes):
   ```
   git checkout main
   git reset --hard a2909c6
   git push origin main --force
   ```
   Then delete `rollback-verify` branch.

2. **Fix `cancelBackup()` race condition** — do NOT set `isRunning = false` in `cancelBackup()`; let `performBackup()` set it when it actually finishes. Or add an `isCancelling: Bool` guard to `runBackup()`.

3. **Fix post-cancel rclone activity** — add `guard !Task.isCancelled else { return [] }` before `retryFailedPaths()` and `cleanupFailedDirectories()` calls in `DropboxJob.start()`.

4. **Remove debug `print()` calls** — noted in prior session; `DropboxJob` and `AppDelegate` have debug prints to clean up before release.

5. **Convert menubar popover to regular NSWindow** — user request logged in memory. The floating popover is more hindrance than help.

6. **Consider `retryFailedPaths` temp file naming** — currently uses `rclone-retry-1.txt` / `rclone-retry-2.txt` (fixed names). Since we're back to single-job (non-concurrent) flow this is not urgent, but UUID-prefixed names would be cleaner.

## Other Notes

- No worktrees in use — `rollback-verify` is a local branch only, `main` still has all sharding commits until step 1 above is done
- The shard state file at `~/Library/Application Support/backit/backup-state.json` may still exist on disk from the QA run — delete it before running the rolled-back version
- The rolled-back `DropboxJob` no longer has `excludes` or `filesFrom` init params — it's a clean single-sync job
- `BackupCoordinator` no longer has `currentShardIndex`, `totalShards`, `currentShardName`, `pendingResume`, `planningPhase` published properties
- All tests should pass on the rollback — the core job infrastructure (CCCJob, DropboxJob, BackupCoordinator, ScheduleManager, etc.) was all present before sharding
