# Per-Job Completion Summary Design

**Date:** 2026-04-02
**Status:** Approved

## Goal

Each job section in the main window shows a summary line after it completes:
`"completed 10:15:32 Jan 1, 2027 · 2:13:34"` (or `"failed …"`).
The bottom bar shows total run wall-clock duration alongside the existing last-run date.

## Scope

Job level only (disk/dropbox/icloud). No intra-job phase breakdown. The goal is "what state did everything end up in?" at a glance — enough to know which job needs a rerun.

---

## Section 1: Data Model

### `JobResult` — new field

```swift
var completedAt: Date? = nil
```

`durationSeconds` is unchanged (wall-clock seconds from job start to save time, already correct).
`completedAt` is `nil` for stale runs cleaned up at startup (actual end time unknown).

### DB migration

Add nullable column to `jobResult`:

```sql
ALTER TABLE jobResult ADD COLUMN completedAt REAL;
```

Safe additive migration — existing rows get `NULL`, no data loss. Applied in `migrate()` by attempting the `ALTER TABLE` and ignoring the error if the column already exists (SQLite returns `SQLITE_ERROR` with message "duplicate column name" on repeat runs).

---

## Section 2: BackupCoordinator

### New published properties

```swift
@Published var cccLastResult: JobResult? = nil
@Published var dropboxLastResult: JobResult? = nil
@Published var icloudLastResult: JobResult? = nil
@Published var lastRunDuration: TimeInterval? = nil
```

Placed alongside existing `cccProgress`, `dropboxProgress`, `icloudProgress`.

### `performBackup` and `performSingleJob`

After saving each `JobResult` to the DB, set `completedAt = Date()` before saving and assign the result to the matching published property:

```swift
result.completedAt = Date()
try? db.save(&result)
switch job.jobType {
case .disk, .bootable: cccLastResult = result
case .dropbox:         dropboxLastResult = result
case .icloud:          icloudLastResult = result
}
```

After the run completes, set `lastRunDuration`:

```swift
lastRunDuration = run.completedAt.map { $0.timeIntervalSince(run.startedAt) }
```

Total runtime is wall-clock (`run.completedAt - run.startedAt`), not a sum of job durations — jobs can overlap (e.g. CCC retried after disk comes online while rclone is running).

### `restoreLastRun`

Extended to also populate per-job and duration state from the most recent completed run:

```swift
let results = (try? db.fetchJobResults(forRun: run.id!)) ?? []
for r in results {
    switch r.jobType {
    case .disk, .bootable: cccLastResult = r
    case .dropbox:         dropboxLastResult = r
    case .icloud:          icloudLastResult = r
    }
}
if let end = run.completedAt {
    lastRunDuration = end.timeIntervalSince(run.startedAt)
}
```

This makes summary lines persist across app restarts.

---

## Section 3: UI

### `JobSectionView` and `RcloneStatusView` — new parameter

```swift
var lastResult: JobResult? = nil
```

The bottom-right of each section (currently `--:--` when not running) becomes:

| State | Display |
|-------|---------|
| Running | Live elapsed timer (unchanged) |
| `lastResult` present, status `.done` | `"completed HH:MM:SS MMM D, YYYY · H:MM:SS"` in `.green` |
| `lastResult` present, status `.failed` | `"failed HH:MM:SS MMM D, YYYY · H:MM:SS"` in `.red` |
| No `lastResult` | `--:--` (unchanged) |

Duration formatted with the existing `elapsed()` helper, called with `durationSeconds` converted to a `TimeInterval`.

### Bottom bar

The existing last-run label gains a duration suffix when `lastRunDuration` is set:

```
Jan 1, 2027 at 10:15 AM · 2:45:12 total
```

No new visual elements; the duration is appended to the existing formatted date string.

### `BackitMainView` wiring

Pass results to each section:

```swift
JobSectionView(
    ...
    lastResult: coordinator.cccLastResult
)
RcloneStatusView(   // Dropbox
    ...
    lastResult: coordinator.dropboxLastResult
)
RcloneStatusView(   // iCloud
    ...
    lastResult: coordinator.icloudLastResult
)
```

Pass duration to bottom bar formatter via `coordinator.lastRunDuration`.

---

## Files Changed

| File | Change |
|------|--------|
| `backit/Database/Models.swift` | Add `completedAt: Date?` to `JobResult` |
| `backit/Database/DatabaseManager.swift` | Migration: add column; update save/fetch for `completedAt` |
| `backit/Coordination/BackupCoordinator.swift` | 4 new `@Published` properties; set in `performBackup`, `performSingleJob`, `restoreLastRun` |
| `backit/UI/BackitMainView.swift` | Add `lastResult` param to `JobSectionView` + `RcloneStatusView`; wire from coordinator; update bottom bar |

## Out of Scope

- Per-phase breakdown within a job (sync / retry / cleanup / verify)
- iCloud "Open Full Log" button (separate backlog item)
- Disk job "volume offline" friendly message (separate backlog item)
