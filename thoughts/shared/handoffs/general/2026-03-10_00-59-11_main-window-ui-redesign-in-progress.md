---
date: 2026-03-10T07:59:11+0000
session_name: general
researcher: Claude Sonnet 4.6
git_commit: e7bcadb
branch: worktree-main-window
repository: backit
topic: "Main window UI redesign — floating app window replacing menubar popover"
tags: [swift, macos, swiftui, rclone, ccc, ui-redesign, worktree]
status: in_progress
last_updated: 2026-03-10
last_updated_by: Claude Sonnet 4.6
type: implementation
root_span_id:
turn_span_id:
---

# Handoff: Main window UI redesign + e2e debugging in progress

## Task(s)

| Task | Status |
|------|--------|
| Switch CCCJob from AppleScript to `ccc` CLI | ✅ Complete — committed `d32be1e` on `main` |
| Fix rclone path, port, blocking, menu | ✅ Complete — committed `e7bcadb` on `main` |
| Redesign UI: floating main window replacing menubar popover | 🔄 In progress — `worktree-main-window` branch |
| End-to-end test: CCC + rclone both running successfully | 🔄 In progress — CCC run ongoing, rclone fixes applied but not yet tested |

**Working worktree:** `/Users/joemcmahon/Code/backit/.claude/worktrees/main-window`
**Branch:** `worktree-main-window`

## Critical References

- `docs/plans/2026-03-06-backit-tasks-7-16.md` — master plan (Task 10 e2e checklist at line ~1612)
- `docs/plans/2026-03-06-backit-design.md` — approved architecture

## Recent Changes

All changes below are in the worktree (`worktree-main-window` branch):

- `backit/AppDelegate.swift` — Changed activation policy to `.regular` (dock icon), added `showMainWindow()`, `applicationShouldHandleReopen`, floating `NSWindow` creation at launch
- `backit/UI/BackitMainView.swift` — New main window SwiftUI view: two job sections (CCC + rclone), task/remote dropdowns populated dynamically, folder pickers, RUN/CANCEL button, schedule gear sheet, status line, per-job progress bars with status text
- `backit/UI/RemoteLoaders.swift` — New: `CCCTaskLoader` (runs `ccc --uuids`) and `RcloneRemoteLoader` (runs `rclone listremotes`) to populate dropdowns
- `backit/Coordination/BackupCoordinator.swift` — Added `cccProgress` and `dropboxProgress` `@Published` properties; per-job progress forwarding in `performBackup()`
- `backit/Settings/BackupSettings.swift` — Added `diskBackupVolumePath` field (for future pre-flight volume check)
- `backit/Jobs/DropboxJob.swift` — Removed RC server entirely; now uses `--stats 2s` piped from stderr; `killOrphanedRclones()` restored with `waitUntilExit()` to prevent race condition killing new rclone; removed `freePort()` and port management
- `backit/Jobs/RcloneStatsParser.swift` — Rewritten to parse `--stats` text output instead of JSON; parses `Checks:` lines for scan phase ("Checking X / Y files") and `Transferred:` lines for copy phase (bytes + rate)
- `backit/UI/MenubarController.swift` — Simplified: left-click opens main window (idle) or progress popover (running); right-click builds menu on demand; `buildMenu()` returns `NSMenu` instead of setting `statusItem.menu`

## Learnings

**The pkill race condition (critical bug):**
`killOrphanedRclones()` was changed to fire-and-forget (no `waitUntilExit()`) to avoid blocking. But pkill kept running after we launched the new rclone, and killed it. This caused the rclone run to silently die immediately — the bug manifested as "rclone completes instantly with no output". Fix: restore `waitUntilExit()` on pkill only (it's milliseconds). The new rclone (`waitUntilExit`) stays on `DispatchQueue.global()`.

**CCC CLI requires the helper to be running:**
`ccc --start "TaskName" --watch` communicates with `com.bombich.ccc.helper` via IPC. The helper runs even when the CCC window is closed. However, there can be a brief not-ready period after CCC transitions states (e.g., after a cancelled run). If CCC fails immediately with Zero KB, wait a moment and retry.

**CCC `--watch` output progress format:**
During the initial scan phase: `[Data copied: 554.4 MB, Progress: -1.000000%]` — the `-1` means CCC doesn't know total size yet. Our regex only matches positive numbers so the progress bar stays at 0 until CCC has real percentages. This is acceptable behavior.

**`waitUntilExit()` on cooperative thread pool causes UI freeze:**
All `waitUntilExit()` calls for long-running processes must use `DispatchQueue.global(qos: .utility).async` + `withCheckedContinuation`. Blocking cooperative pool threads starves the main actor's event processing, making the UI unresponsive.

**`statusItem.menu` conflicts with button action handler:**
When `statusItem.menu` is set, AppKit intercepts ALL clicks and shows the menu, bypassing the custom `statusButtonClicked` action. Solution: never set `statusItem.menu` persistently — build and set it only during right-click, then clear it immediately after `performClick`.

**rclone symlink resolution:**
`/opt/homebrew/bin/rclone` is a symlink. `FileManager.fileExists` follows symlinks (returns true) but `Process.executableURL` with a symlink path fails with ENOENT on some macOS configurations. Fix: resolve with `URL(fileURLWithPath:).resolvingSymlinksInPath().path` before using as executable.

**Leading space in settings path:**
A leading space in `dropboxVolumePath` (e.g. `" /Volumes/..."`) is stored silently. rclone treats it as a relative path, resolves against CWD (`/`), and tries `mkdir /` which fails with "read-only file system". Fix: trim whitespace in `BackupSettings` didSet handlers and before passing to Process arguments.

**App Sandbox blocks Homebrew binaries:**
The app had `com.apple.security.app-sandbox = true` which made `/opt/homebrew/...` appear non-existent to `Process`. Fix: remove App Sandbox entitlement in Xcode (Signing & Capabilities tab). Not an App Store app.

## Post-Mortem

### What Worked
- Using `ccc --uuids` and `rclone listremotes` to populate dropdowns eliminates free-text entry bugs entirely
- Parsing `--stats 2s` stderr output directly is much simpler than the RC server polling approach (no HTTP, no port management, works during scan phase too)
- `withCheckedContinuation` + `DispatchQueue.global()` cleanly moves blocking `waitUntilExit()` off cooperative pool
- `withTaskCancellationHandler` correctly terminates rclone when Swift task is cancelled
- FloatingWindow approach (CCC-style) is significantly simpler for UX than menubar popover for a tool with real configuration

### What Failed
- AppleScript approach for CCC: CCC's AppleScript suite has no `run` verb — the correct approach is the bundled `ccc` CLI at `/Applications/Carbon Copy Cloner.app/Contents/MacOS/ccc`
- RC server polling for rclone progress: port conflicts, no data during scan phase, extra complexity. Replaced with `--stats 2s` stderr parsing
- Fire-and-forget `pkill`: caused new rclone to be killed by its own orphan-cleanup code. Must `waitUntilExit()` on pkill

### Key Decisions
- **No folder picker for CCC destination**: CCC owns its destination config; showing "Configure in CCC…" button that opens CCC is correct — we just trigger the task
- **`diskBackupVolumePath` kept in BackupSettings**: Not shown in UI yet, but reserved for pre-flight "is the volume mounted?" check (planned post-Task-10 refinement)
- **Bootable clone job commented out**: Only one CCC task configured (`Laptop Backup`). Bootable disabled until user sets up a real CCC bootable task
- **Dock icon (`.regular` activation policy)**: App runs like CCC — dock icon + floating window, not a pure menubar accessory

## Artifacts

- `backit/AppDelegate.swift` — main window creation, activation policy
- `backit/UI/BackitMainView.swift` — new main window view
- `backit/UI/RemoteLoaders.swift` — CCC task + rclone remote loaders
- `backit/Jobs/DropboxJob.swift` — rclone stats parsing, orphan cleanup fix
- `backit/Jobs/RcloneStatsParser.swift` — text stats parser
- `backit/Coordination/BackupCoordinator.swift` — per-job progress
- `backit/Settings/BackupSettings.swift` — `diskBackupVolumePath` added
- `backit/UI/MenubarController.swift` — simplified, on-demand menu

## Action Items & Next Steps

1. **Verify end-to-end run succeeds**: CCC run still ongoing as of handoff. Once complete, trigger a backit Run Backup and confirm:
   - CCC task starts (not "Zero KB / Failed")
   - rclone runs and doesn't die instantly (pkill race fixed)
   - Progress bars update live (Checks: X/Y during scan, bytes + rate during transfer)
   - Both jobs show ✓ in status line

2. **Test with real rclone transfer**: Add/modify a file in Dropbox to force a non-trivial sync. Verify progress bar shows scan count then transfer progress.

3. **Update DropboxJob tests**: `DropboxJob.init` signature changed — `rcPort` parameter removed. Tests need updating.

4. **Commit worktree changes**: Once e2e verified, commit all worktree changes and merge/PR to main.

5. **Clean up debug prints**: Remove `print("[DropboxJob] launching: ...")` and `print("[AppDelegate] showMainWindow...")` before final commit.

6. **Consider**: Add CCC progress text (parse "Data copied: X MB" from `--watch` output) to CCC section similar to rclone's "Checking X/Y" display.

## Other Notes

- The worktree is at `.claude/worktrees/main-window` (managed by `EnterWorktree` tool). Use `EnterWorktree` or open `/Users/joemcmahon/Code/backit/.claude/worktrees/main-window` in Xcode.
- CCC task name in Settings must exactly match `ccc --uuids` output — currently `Laptop Backup`
- rclone remote name in Settings must match `rclone listremotes` without the trailing colon — currently `dropbox`
- rclone destination: `/Volumes/Backblaze_MacEx4TB57422399/Dropbox backup` (on 4TB external drive, must be mounted)
- `com.bombich.ccc.helper` must be running (it is, even when CCC window is closed)
- 15,758 files in Dropbox, ~41 GB was not yet synced in the manual rclone run
- `BackupCoordinator.performBackup()` is `@MainActor` — all job progress forwarding tasks inherit this context but `start()` on non-`@MainActor` jobs runs on cooperative pool
