---
date: 2026-03-13T00:43:56+0000
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 1ad24a5
branch: worktree-main-window
repository: backit
topic: "Main window UI + rclone stats — current working state"
tags: [swift, macos, swiftui, rclone, ccc, ui, worktree]
status: in_progress
last_updated: 2026-03-12
last_updated_by: Claude Sonnet 4.6
type: implementation
root_span_id:
turn_span_id:
---

# Handoff: Main window UI current state — uncommitted last-run-date tracking

## Task(s)

| Task | Status |
|------|--------|
| Replace menubar popover with floating main window | ✅ Complete — commit `652046a` |
| Switch CCCJob to `ccc` CLI | ✅ Complete — commit `d32be1e` on `main` |
| Fix rclone path, blocking, port, menu | ✅ Complete — commit `e7bcadb` |
| Add targeted retry + run summary | ✅ Complete — commit `c59a468` |
| Fix Swift concurrency warnings | ✅ Complete — commit `55b7502` |
| Improve rclone reliability + rate-limit handling | ✅ Complete — commit `29b9c36` |
| Stats dashboard, Option-click verify, UI polish | ✅ Complete — commit `1ad24a5` |
| Last-run-date tracking via rclone log timestamps | 🔄 In progress — uncommitted in 3 files |
| Update DropboxJob tests (rcPort removed from init) | ⬜ Planned |
| Clean up debug `print()` statements | ⬜ Planned |

**Working worktree:** `/Users/joemcmahon/Code/backit/.claude/worktrees/main-window`
**Branch:** `worktree-main-window`

## Critical References

- `docs/plans/2026-03-06-backit-tasks-7-16.md` — master plan (Task 10 e2e checklist ~line 1612)
- `docs/plans/2026-03-06-backit-design.md` — approved architecture

## Recent Changes

**Committed (latest: `1ad24a5`):**
- `backit/UI/BackitMainView.swift` — Live stats panel (Listed/Checked/Copied/Errors), Option-click toggles Run↔Verify, verify results sheet, CCC "Scanning…" label, elapsed timers, Enter/Return shortcut only for Run/Verify
- `backit/Jobs/BackupJob.swift` — `RcloneStats` struct with rate-limit-aware error counting; `verifyMode`, `verifySame`, `verifyMissingFromDest`, `verifyMissingFromSource`, `verifyDifferent`, `verifyCheckErrors`, `verificationMismatches` fields
- `backit/Jobs/RcloneStatsParser.swift` — `updateStats(_:from:)` for live RcloneStats population, `parseDirectoryError()`, directory-error regex
- `backit/Coordination/BackupCoordinator.swift` — `statsTask` subscription, `verifyOnly()` entry point, `lastRcloneSummary`/`lastRunDate` properties

**Uncommitted (staged diff in 3 files):**
- `backit/Jobs/RcloneStatsParser.swift:73-84` — Added `parseTimestamp(_ line:) -> Date?`; parses `yyyy/MM/dd HH:mm:ss` prefix from rclone log lines
- `backit/Jobs/DropboxJob.swift:18,85-87` — Added `nonisolated(unsafe) private(set) var lastLogTimestamp: Date?`; set from `parseTimestamp` in readability handler
- `backit/Coordination/BackupCoordinator.swift:148-150` — After job completes, captures `dropboxJob.lastLogTimestamp` → `lastRunDate` (replaces always-setting `Date()`)

## Learnings

**pkill race condition (critical):**
`killOrphanedRclones()` must call `waitUntilExit()` — fire-and-forget pkill kills the new rclone it just launched. The fix is in `DropboxJob.swift:348-353`.

**`statusItem.menu` vs button action:**
Never set `statusItem.menu` persistently — AppKit intercepts all clicks and bypasses the custom action handler. Build and set menu only on right-click, clear immediately after `performClick`. See `MenubarController.swift`.

**rclone symlink resolution:**
`/opt/homebrew/bin/rclone` is a symlink; `Process.executableURL` with a symlink path fails ENOENT on some macOS configs. Use `URL(fileURLWithPath:).resolvingSymlinksInPath().path` — see `DropboxJob.swift:356-365`.

**App Sandbox blocks Homebrew binaries:**
`com.apple.security.app-sandbox = true` makes Homebrew paths invisible to `Process`. Remove App Sandbox entitlement (Signing & Capabilities in Xcode). Not an App Store app.

**`waitUntilExit()` on cooperative thread pool causes UI freeze:**
All `waitUntilExit()` calls on long-running processes must use `DispatchQueue.global(qos: .utility).async` + `withCheckedContinuation`.

**Leading space in settings path:**
A leading space in `dropboxVolumePath` is stored silently; rclone treats it as relative path from `/`. Trim whitespace before passing to `Process` arguments — already handled in `DropboxJob.swift:57`.

**CCC CLI requires helper running:**
`ccc --start "TaskName" --watch` communicates with `com.bombich.ccc.helper` via IPC. Helper runs even when CCC window is closed; may need brief wait after a cancelled run.

**CCC `--watch` scan phase:**
During initial scan: `[Data copied: X MB, Progress: -1.000000%]` — `-1` means CCC doesn't know total yet. Our regex only matches positive numbers, so progress bar stays at 0 until CCC has real percentages. Acceptable behavior.

**`nonisolated(unsafe)` for DropboxJob mutating state:**
Properties mutated only from the serial readability handler + `start()` are safe to mark `nonisolated(unsafe)` — avoids `@MainActor` spread while keeping Swift concurrency happy.

## Post-Mortem

### What Worked
- Parsing `--stats 2s` stderr directly: much simpler than RC server polling; no HTTP, no port management, works during scan phase
- `withCheckedContinuation` + `DispatchQueue.global()`: clean way to move blocking `waitUntilExit()` off cooperative pool
- `withTaskCancellationHandler`: correctly terminates rclone when Swift task is cancelled
- `ccc --uuids` / `rclone listremotes` for dropdown population: eliminates free-text entry bugs entirely
- FloatingWindow (CCC-style) UX: significantly simpler than menubar popover for a tool with real config
- `rclone check --combined` with file polling: gives live per-file verify results without needing stderr

### What Failed
- AppleScript for CCC: CCC's suite has no `run` verb — correct approach is bundled `ccc` CLI
- RC server polling for rclone progress: port conflicts, no data during scan, extra complexity
- Fire-and-forget pkill: caused new rclone to be killed by its own orphan-cleanup code

### Key Decisions
- **Dock icon (`.regular` policy):** App runs like CCC — dock + floating window, not pure menubar accessory
- **No folder picker for CCC destination:** CCC owns destination config; show "Configure in CCC…" that opens CCC
- **`diskBackupVolumePath` in BackupSettings:** Reserved for pre-flight volume-mounted check (not yet wired to UI)
- **Bootable clone job commented out:** Only `Laptop Backup` CCC task configured; bootable disabled until real task set up

## Artifacts

- `backit/AppDelegate.swift` — activation policy, `showMainWindow()`, floating NSWindow
- `backit/UI/BackitMainView.swift` — main window view (stats panel, verify mode, elapsed timer)
- `backit/UI/RemoteLoaders.swift` — `CCCTaskLoader` + `RcloneRemoteLoader`
- `backit/Jobs/DropboxJob.swift` — rclone stats parsing, orphan cleanup, `lastLogTimestamp`
- `backit/Jobs/RcloneStatsParser.swift` — text stats parser, `parseTimestamp`, `updateStats`
- `backit/Jobs/BackupJob.swift` — `RcloneStats` struct
- `backit/Coordination/BackupCoordinator.swift` — per-job progress, `lastRunDate`, `verifyOnly()`
- `backit/Settings/BackupSettings.swift` — `diskBackupVolumePath`
- `backit/UI/MenubarController.swift` — simplified, on-demand menu

## Action Items & Next Steps

1. **Commit uncommitted changes** (last-run-date tracking): `DropboxJob.swift`, `RcloneStatsParser.swift`, `BackupCoordinator.swift`
2. **Update DropboxJob tests**: `DropboxJob.init` no longer takes `rcPort` — tests need updating to match new `init(remoteName:volumePath:verify:)` signature
3. **Remove debug prints**: Check for `print("[DropboxJob]...")` and `print("[AppDelegate]...")` before final commit
4. **Wire `lastRunDate` to UI**: `BackupCoordinator.lastRunDate` is set but not yet displayed anywhere in `BackitMainView`
5. **Consider**: CCC progress text — parse "Data copied: X MB" from `--watch` output for CCC section (similar to rclone's "Checking X/Y")
6. **Merge / PR**: Once all above done, merge `worktree-main-window` → `main`

## Other Notes

- Worktree path: `/Users/joemcmahon/Code/backit/.claude/worktrees/main-window` — open this in Xcode, not the repo root
- CCC task name in Settings must exactly match `ccc --uuids` output — currently `Laptop Backup`
- rclone remote name must match `rclone listremotes` without trailing colon — currently `dropbox`
- rclone destination: `/Volumes/Backblaze_MacEx4TB57422399/Dropbox backup` (4TB external, must be mounted)
- `BackupCoordinator.performBackup()` is `@MainActor` — all job progress forwarding tasks inherit this; `start()` on non-`@MainActor` jobs runs on cooperative pool
- `backitTests/DropboxJobTests.swift` — tests exist but have stale `rcPort` init parameter; will not compile until updated
