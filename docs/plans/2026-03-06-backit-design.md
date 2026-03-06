# Backit macOS Menubar App — Design Document

**Date:** 2026-03-06
**Scope:** Single machine, single backup disk, single Dropbox per user
**Status:** Approved

## Overview

Backit is a macOS menubar agent that orchestrates three backup jobs on a daily schedule:
1. **DiskJob** — CCC task for incremental file backup to a local drive volume
2. **DropboxJob** — rclone sync from Dropbox cloud to a local drive volume
3. **BootableJob** — CCC task for bootable clone of the startup disk

The app runs as a login item (LSUIElement), shows a status icon in the menubar, and sends user notifications for reminders and scheduling decisions.

---

## Scope Constraint

This design targets a **one-machine / one-backup-disk** setup per user. Multi-volume filestore and multi-machine configurations are future work.

---

## Architecture: Three Layers

### Jobs Layer

**CCCJob** (`backit/Jobs/CCCJob.swift`)
- Single class conforming to `BackupJob`, parameterized by `jobType: JobType` and `taskName: String`
- Invokes the named CCC task via AppleScript (`tell application "Carbon Copy Cloner"`)
- Polls CCC task progress via AppleScript every 2 seconds
- Publishes `JobProgress` via `CurrentValueSubject<JobProgress, Never>`
- CCC handles initial copy vs. incremental automatically — no rsync fallback needed
- Detects CCC presence at startup by checking `/Applications/Carbon Copy Cloner.app`

**DropboxJob** (`backit/Jobs/DropboxJob.swift`)
- Conforms to `BackupJob` with `jobType = .dropbox`
- Launches rclone as a child `Process`:
  ```
  rclone sync {remoteName}: {volumePath} \
    --metadata --tpslimit 12 --tpslimit-burst 0 -L \
    --transfers 8 --checkers 8 \
    --rc --rc-addr localhost:{port}
  ```
- Polls `http://localhost:{port}/core/stats` via URLSession every 2 seconds
- Parses JSON with existing `RcloneStatsParser`
- Detects rclone presence at startup by checking common paths (`/usr/local/bin/rclone`, `/opt/homebrew/bin/rclone`)
- Remote name: `{NSUserName()}-dropbox`
- Volume path: `/Volumes/{NSUserName()} Dropbox Clone`

**MacOSVersionDetector** (`backit/Jobs/MacOSVersionDetector.swift`)
- Returns current macOS build string (`ProcessInfo.processInfo.operatingSystemVersionString`)
- Returns hardware UUID from IOKit (`IOPlatformExpertDevice` / `IOPlatformUUID`)
- Used by `BackupCoordinator` to detect machine changes between runs

**Deleted (dead code):**
- `backit/Jobs/DiskJob.swift` — rsync-based, replaced by CCCJob
- `backit/Jobs/RsyncOutputParser.swift` — no longer needed
- `backitTests/DiskJobTests.swift` — placeholder, no value
- `backitTests/RsyncOutputParserTests.swift` — tests deleted code

### Coordination Layer

**BackupCoordinator** (`backit/Coordination/BackupCoordinator.swift`)
- `@MainActor` class; owns the full run lifecycle
- At run start:
  1. Detect hardware UUID — if different from `BackupSettings.storedMachineUUID`, show warning alert before proceeding
  2. Create `BackupRun` in DB (status = `.running`, current macOS build + machine UUID stored)
  3. Run jobs sequentially: `CCCJob(.disk)` → `DropboxJob` → `CCCJob(.bootable)`
  4. Skip any job whose tool was not detected at startup (record as `.skipped`)
  5. On completion: update `BackupRun.status`, save one `JobResult` per job, call `DatabaseManager.pruneRuns(keepLast: settings.historyLimit)`
- Publishes `@Published var currentProgress: RunProgress?` for UI (aggregate across all jobs)
- Publishes `@Published var lastRun: BackupRun?` for menubar status line

**ScheduleManager** (`backit/Coordination/ScheduleManager.swift`)
- Owns four `Timer` instances and one `NSWorkspace` volume observer
- **earlyReminderTimer**: fires at `BackupSettings.earlyReminderTime` (default 5 PM)
  - If disk not present: "Backup drive not connected. Please plug it in before tonight's backup."
  - If disk present: "Backup scheduled at HH:MM — you might want to wrap up."
- **lateReminderTimer**: fires at `BackupSettings.lateReminderTime` (default 9 PM)
  - If disk still not present: "Backup drive still not connected."
  - If disk present: no notification (already reminded)
- **backupTimer**: fires at `BackupSettings.backupTime` (default 11 PM)
  - If disk not present: post notification, do not run
  - If user appears active (via `NSWorkspace.shared.runningApplications` heuristic): post late-check notification with "I've Stopped" / "Skip for Now" actions
  - If user appears idle: trigger `BackupCoordinator.runBackup()`
- **manualTriggerTimer**: one-shot, used when user selects "Run Backup Now" from menu
- **Volume observer**: subscribes to `NSWorkspace.didMountNotification` / `NSWorkspace.didUnmountNotification`; updates `@Published var diskPresent: Bool`
- All timers re-scheduled when settings change

**BackupSettings** (`backit/Settings/BackupSettings.swift`)
- `@Observable` class backed by `UserDefaults`
- Schema:

| Key | Type | Default |
|-----|------|---------|
| `backupTime` | `Date` | 11:00 PM |
| `earlyReminderTime` | `Date` | 5:00 PM |
| `lateReminderTime` | `Date` | 9:00 PM |
| `diskCCCTaskName` | `String` | `"{username} Backup"` |
| `bootableCCCTaskName` | `String` | `"{username} Bootable"` |
| `dropboxRemoteName` | `String` | `"{username}-dropbox"` |
| `dropboxVolumePath` | `String` | `"/Volumes/{username} Dropbox Clone"` |
| `historyLimit` | `Int` | `3` |
| `storedMachineUUID` | `String` | `""` (set on first run) |
| `skipTonight` | `Bool` | `false` (reset daily) |

### UI Layer

**MenubarController** (`backit/UI/MenubarController.swift`)
- Takes ownership of `AppDelegate.statusItem`
- Icon states: idle / running (animated) / warning (disk missing or skipped jobs) / error (backup failed)
- Left-click: opens NSPopover containing `MainPanelView`
- Menu (right-click / always-visible for some users):
  - Status line: "Last backup: Today 2:03 AM ✓" (or "Never")
  - **Run Backup Now**
  - **Skip Tonight's Backup…** → NSAlert confirmation: "Skip tonight's backup? You can still run it manually." [Skip] [Cancel]
  - Separator
  - **Settings…** → opens `SettingsView` in a new window
  - Separator
  - **Quit Backit**

**MainPanelView** (`backit/UI/MainPanelView.swift`)
- SwiftUI view shown in NSPopover
- Live progress section (visible during a run):
  - One row per job: job name, `ProgressView(value:)`, transfer rate, bytes
  - Cancel button
- History section: embeds `RunHistoryView`

**RunHistoryView** (`backit/UI/RunHistoryView.swift`)
- SwiftUI list of last N `BackupRun` records
- Each row: date, overall status badge, expandable job results

**SettingsView** (`backit/UI/SettingsView.swift`)
- SwiftUI `Form` with sections:
  - **Schedule**: backup time, early reminder time, late reminder time
  - **CCC Tasks**: disk task name, bootable task name
  - **Dropbox**: remote name, volume path
  - **History**: runs to keep (stepper, min 1 max 10)
- Changes write through to `BackupSettings` immediately

**LaunchAgentManager** (`backit/LaunchAgent/LaunchAgentManager.swift`)
- Writes `~/Library/LaunchAgents/com.{username}.backit.plist` to launch at login
- `install()` / `uninstall()` methods
- Plist sets `RunAtLoad = true`, `KeepAlive = false`, `ProcessType = Background`

---

## Machine-Change Detection

On each backup run, `BackupCoordinator`:
1. Reads current hardware UUID via `MacOSVersionDetector`
2. Compares against `BackupSettings.storedMachineUUID`
3. If empty (first run): stores UUID, proceeds silently
4. If different: shows NSAlert — "This backup was created on a different machine. The bootable clone may not be safe to overwrite. Continue anyway?" [Continue] [Cancel]
5. If user continues: updates stored UUID, proceeds

---

## Disk Volume Naming

| Volume | Default Name | Configurable? |
|--------|-------------|---------------|
| DiskJob destination | (path from CCC task config) | Via CCC task settings |
| DropboxJob destination | `/Volumes/{username} Dropbox Clone` | Yes, in BackupSettings |
| BootableJob destination | (path from CCC task config) | Via CCC task settings |

---

## Testing Approach

| File | Strategy |
|------|----------|
| `CCCJobTests.swift` | Mock AppleScript executor via injected protocol; test idle→running→done transitions |
| `DropboxJobTests.swift` | Test initial status is idle; full run via manual test (Task 16) |
| `BackupCoordinatorTests.swift` | Mock jobs; verify sequential execution, DB writes, skip behavior, machine UUID detection |
| `ScheduleManagerTests.swift` | Inject mock clock + mock NSWorkspace; verify timer logic and disk-present state |
| `BackupSettingsTests.swift` | Round-trip UserDefaults read/write for all keys |
| `LaunchAgentManagerTests.swift` | Verify plist written and removed at correct path |
| Manual end-to-end (Task 16) | Full run against real CCC tasks and rclone remote |

---

## Open Questions (Future Work)

- Multi-machine / multi-volume filestore support (multiple users' Dropboxes, multiple machine clones on one large drive)
- Notification actions for "I've Stopped" / "Skip for Now" require `UNUserNotificationCenter` with category actions — needs notification permission at first launch
- rclone RC port conflict handling (if port is in use, pick next available)
