---
date: 2026-07-07T22:40:02-07:00
session_name: general
researcher: Claude Sonnet 5
git_commit: 607af71
branch: main
repository: backit
topic: "Real app screenshot for project website — blocked on Terminal Screen Recording permission"
tags: [github-pages, site, screenshot, screencapture, appdelegate, terminal-permissions]
status: in_progress
last_updated: 2026-07-07
last_updated_by: Claude Sonnet 5
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Real app screenshot for project website — paused for Terminal restart

## Task(s)

| Task | Status |
|------|--------|
| Release backit publicly on GitHub (joemcmahon/backit), MIT license, doc fixes | ✅ Done (prior session) |
| Add explicit CCC/Dropbox enable toggles in Settings UI | ✅ Done (prior session) |
| Add CONTRIBUTING.md + project website (`site/`) deployed via GitHub Pages | ✅ Done (prior session) |
| Replace the CSS mockup on the site with a real screenshot of the app | ⏳ In progress — paused, see below |

## Why this session paused

`screencapture` failed inside the Bash tool's default sandbox (`could not create image from display`). Retried with `dangerouslyDisableSandbox: true` and it worked — produced a real 2.7MB PNG at `/private/tmp/.../scratchpad/test-capture.png`. So screen recording access exists somewhere in the permission chain, but it's inconsistent/fragile through the sandboxed tool path.

The user suspects the terminal application in use needs its Screen Recording permission (System Settings → Privacy & Security → Screen Recording) properly (re-)granted, and asked to restart Terminal before continuing. **This handoff exists so that work can resume cleanly after that restart.**

## Critical safety finding — read before resuming

The real, production backit.app is **currently running** on this machine:
```
1084  /Applications/backit.app/Contents/MacOS/backit
11882 /Applications/backit.app/Contents/MacOS/backit --headless
```

**Do not launch a naive second instance of backit to screenshot it.** `AppDelegate.applicationDidFinishLaunching` (`backit/AppDelegate.swift:17`) does two things that would be dangerous to trigger from a throwaway debug build:

1. It calls `LaunchAgentManager.install(backupTime:)` whenever `launchAgent.needsInstall` is true (`AppDelegate.swift:53`). `needsInstall` is true whenever the installed plist's `ProgramArguments` executable path doesn't match `Bundle.main.executablePath` (`LaunchAgentManager.swift:70-74`). A DerivedData debug build's path will never match `/Applications/backit.app/...`, so **launching the debug build normally would silently overwrite the user's real `~/Library/LaunchAgents/backit.plist`** to point at a throwaway build path — breaking the real nightly backup the next time Xcode's DerivedData is cleaned. This exact class of bug was previously diagnosed and fixed in `thoughts/shared/handoffs/general/2026-05-13_19-08-52_post-partition-recovery-icloud-removal.md`. Do not reintroduce it.
2. Real `UserDefaults.standard` and the real SQLite DB (`~/Library/Application Support/backit/backit.db`) hold the user's actual CCC task name, Dropbox remote/volume paths, and backup history. A screenshot must not leak any of that into a **public** website.

## Plan already worked out (not yet applied to any file)

Add a **temporary** CLI-gated code path to `AppDelegate.swift`, parallel to the existing `--headless` branch (which sits at `AppDelegate.swift:28-33`), e.g. `--screenshot-preview`:

```swift
// Screenshot preview mode: isolated fake data, no LaunchAgent install, no notification prompts.
if CommandLine.arguments.contains("--screenshot-preview") {
    NSApp.setActivationPolicy(.regular)
    settings.diskCCCTaskName = "Laptop Backup"
    settings.dropboxRemoteName = "dropbox"
    settings.dropboxVolumePath = "/Volumes/Dropbox Backup"
    coordinator.cccProgress = JobProgress(fraction: 1.0, bytesTransferred: 0, bytesTotal: 0, transferRate: "", status: .done)
    coordinator.rcloneStats = RcloneStats(listed: 18204, checked: 18204, filesTransferred: 37,
                                           bytesTransferred: 412_000_000, errors: 0, transferRate: "", status: .done)
    coordinator.lastRunStatus = .success
    coordinator.lastRunDate = Date()
    coordinator.lastRunDuration = 252
    coordinator.cccLastResult = JobResult(id: 1, runId: 1, jobType: .disk, status: .done,
                                           bytesTransferred: 0, bytesTotal: 0, durationSeconds: 252, completedAt: Date())
    coordinator.dropboxLastResult = JobResult(id: 2, runId: 1, jobType: .dropbox, status: .done,
                                               bytesTransferred: 412_000_000, bytesTotal: 412_000_000,
                                               durationSeconds: 252, completedAt: Date())
    showMainWindow()
    return
}
```

Key properties: `settings` here is a **normal `BackupSettings()`** (reads real `UserDefaults.standard`) in the existing `applicationDidFinishLaunching` — for the screenshot build it should instead be constructed with an isolated suite, e.g.:
```swift
let settings = BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
```
and `db` as `try! DatabaseManager(inMemory: true)`, so nothing touches the user's real prefs or DB. This means the `--screenshot-preview` branch needs to be checked **before** the real `let settings = BackupSettings()` / `let db = ...` lines at `AppDelegate.swift:19-20`, substituting isolated instances for that mode instead of the real ones.

This path deliberately never calls `LaunchAgentManager.install` or `UNUserNotificationCenter.requestAuthorization` — it goes straight to `showMainWindow()`, which only needs `self.coordinator/settings/db` set (see `AppDelegate.swift:84-106`).

The `JobProgress`, `RcloneStats`, `JobResult`, `JobType`, `JobStatus` shapes referenced above are already confirmed correct against `backit/Jobs/BackupJob.swift` and `backit/Database/Models.swift`.

**This code is scaffolding, not a feature** — apply it, build, screenshot, then `git checkout -- backit/AppDelegate.swift` (or equivalent) to remove it before committing anything. Don't ship `--screenshot-preview` as a permanent flag.

## Next steps after Terminal restart

1. Re-grant Terminal (or whichever terminal app is in use) Screen Recording permission in System Settings if prompted; confirm `screencapture -x <path>` works **without** needing `dangerouslyDisableSandbox` if possible (cleaner going forward), otherwise continue using that override for this one capture.
2. Apply the `--screenshot-preview` patch above to `backit/AppDelegate.swift`.
3. Build: `xcodebuild build -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64'`.
4. Launch the **debug build directly by path** (not `open`, not `/Applications/backit.app`) with the flag, e.g.:
   ```
   /Users/joemcmahon/Library/Developer/Xcode/DerivedData/backit-egxbunbbbudgfvdfxluascvlbajk/Build/Products/Debug/backit.app/Contents/MacOS/backit --screenshot-preview &
   ```
   (DerivedData hash may have changed if Xcode reindexed — re-resolve via `find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname 'backit-*'` if the path above 404s.)
5. Find the new window's ID (avoid the two already-running production processes above) — e.g. via `python3 -c 'import Quartz; ...'` reading `CGWindowListCopyWindowInfo`, filtering by owner PID of the process just launched, or via `osascript` querying System Events for the specific PID.
6. `screencapture -x -o -l <windowID> site/assets/app-screenshot.png` (`-o` omits the window shadow decoration; `-x` suppresses the capture sound).
7. Quit the temp process (`kill <pid>`), revert `AppDelegate.swift`.
8. Update `site/index.html` / `site/assets/style.css` to show the real screenshot (e.g. replace the `.mockup` div's hand-built markup with an `<img>`, or keep the `.mockup` chrome/titlebar wrapper and swap only the inner content for the screenshot — designer's call at that point). Resize/optimize the PNG if it's large (`sips -Z 1200 ...` or similar) before committing.
9. Commit + push; no GitHub Pages redeploy step needed beyond the normal push since `.github/workflows/pages.yml` already triggers on `site/**` changes.

## Artifacts

- Nothing committed this session — working tree was clean at handoff time (`607af71`).
- Scratch file `/private/tmp/claude-501/-Users-joemcmahon-Code-backit/fe3fd47b-b39a-4d26-93d2-b9f902cb239f/scratchpad/test-capture.png` exists from the sandbox test capture (full-screen, not the app window — just a permission smoke test, not useful for the site).
- Built debug app at `/Users/joemcmahon/Library/Developer/Xcode/DerivedData/backit-egxbunbbbudgfvdfxluascvlbajk/Build/Products/Debug/backit.app` (from this session's `xcodebuild build`) — safe to reuse or rebuild.

## Other Notes

- Live site: https://joemcmahon.github.io/backit/ — currently shows the CSS-drawn mockup, not a real screenshot.
- Repo: https://github.com/joemcmahon/backit (public, MIT license).
- See also memory files (outside repo, in Claude's memory store): `project_github_release.md`, `project_icloud_removal.md`, `project_future_backup_targets.md` for broader context on the public release.
- Test command: `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|error:|passed|failed)'` — all tests passing as of `46f2e4f`.
