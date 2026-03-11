# Sharded Restartable Backup Design

## Problem

The current backup runs a single rclone sync/check against the entire Dropbox tree (~1.5M files). A sleep, crash, or manual stop requires a full restart from scratch — typically 2-3+ hours of re-scanning. There is no checkpointing, no restart capability, and no recovery from sleep/wake cycles.

## Solution

Break the backup into sequential per-shard jobs (one per top-level Dropbox directory, ~70+), with a persistent state file tracking completion. On interrupt, only the in-progress shard needs to restart. On wake from sleep or app relaunch, offer to resume if the state is recent enough.

## State Model

JSON file at `~/Library/Application Support/backit/backup-state.json`:

```json
{
  "startedAt": "2026-03-12T10:00:00Z",
  "remoteName": "dropbox",
  "destinationPath": "/Volumes/Backblaze_MacEx4TB57422399/Dropbox backup",
  "shards": [
    { "path": "Code", "syncStatus": "done", "verifyStatus": "pending" },
    { "path": "Documents", "syncStatus": "running", "verifyStatus": "pending" },
    { "path": "Music", "syncStatus": "pending", "verifyStatus": "pending" }
  ]
}
```

**TTL:** 18 hours from `startedAt`. Expired state is silently discarded.

**Shard statuses:** `pending | running | done | failed`

## Shard Discovery

Run `rclone lsd remoteName:` once at the start of each new backup to get top-level directories. Results are saved into the state file immediately. On resume, the saved shard list is used directly (no re-discovery needed).

## Sync Flow

1. Check for existing state file — if present and not expired, check if resume is needed
2. If new run: discover shards via `rclone lsd`, create state file, all shards `pending`
3. Run shards sequentially: `rclone sync remote:Shard /dest/Shard ...`
4. Mark each shard `done` or `failed` immediately on completion
5. On full completion: delete state file

## Resume Flow

On **sleep**: cancel current job, mark in-progress shard back to `pending`, write state
On **wake** or **app launch** with unexpired state: show resume sheet:
> "Backup was interrupted (23 of 71 shards complete). Resume, start over, or skip tonight?"

- **Resume**: continue from first non-`done` shard
- **Start Over**: delete state file, begin fresh
- **Skip Tonight**: dismiss (backup won't run until next scheduled time)

## Verify Flow

**Phase 1:** Run `rclone check` on shards where `verifyStatus != done`, sequentially
**Phase 2:** Optional prompt after Phase 1 — "All shards verified. Run full re-check?"

The `--combined` file approach is used per-shard, with results merged for the final report.

## DropboxJob Changes

Add optional `remoteSubPath: String?` parameter. When set:
- Remote becomes `remoteName:remoteSubPath` (e.g., `dropbox:Code`)
- Local path becomes `volumePath/remoteSubPath` (e.g., `/dest/Code`)

Backward compatible — existing callers without subPath continue to work as before.

## UI Changes

- **Shard progress**: show "Shard 23/71: Code" in the rclone stats panel during sync
- **Resume sheet**: modal sheet presented on wake/launch with resume/start-over/skip
- **Clear Backup State**: button in schedule gear sheet — deletes state file

## Sleep/Wake Handling

`AppDelegate` observes:
- `NSWorkspace.willSleepNotification` → `coordinator.handleSleep()`
- `NSWorkspace.didWakeNotification` → `coordinator.handleWake()`

`handleSleep()` cancels any running job and marks the current shard back to `pending`.
`handleWake()` checks for unexpired state and sets `coordinator.pendingResume = true`, which the UI observes to show the resume sheet.

## Settings

New "Backup State" section in schedule gear sheet:
- "Clear Backup State" button — deletes state file and resets to fresh

## Out of Scope

- Parallel shard execution (rate limit multiplication makes this a net loss)
- Overlap of sync and verify phases
- Per-shard TTLs (TTL applies to the whole backup attempt)
- CCC sharding (CCC manages its own task; only rclone is sharded)
