# backit

A macOS menubar app that automates daily incremental backups to a local drive (via Carbon Copy Cloner) and Dropbox (via rclone). Runs as a login item and handles scheduling, reminders, progress monitoring, and history.

## What it does

- Runs a named CCC task to back up your internal drive
- Syncs your Dropbox remote to a local backup volume via rclone
- Sends smart notifications before backups (reminder → final check → backup)
- Skips silently if your backup drive isn't connected, then notifies you
- Tracks backup history in a local SQLite database
- Installs a LaunchAgent so it starts automatically at login

## Requirements

- macOS 13 or later
- [Carbon Copy Cloner](https://bombich.com) — with a task already configured
- [rclone](https://rclone.org) — with a Dropbox remote already configured (`brew install rclone`)

Both tools must be configured before backit can run backups. backit provides the scheduling and orchestration; CCC and rclone do the actual backup work.

## Installation

1. Build and copy `backit.app` to `/Applications/`
2. Launch the app
3. Grant notification permission when prompted
4. The app installs a LaunchAgent automatically — it will start at every login

## Configuration

Click the gear icon (⚙️) at the bottom right of the main window to open the Schedule sheet.

| Setting | Default | Description |
|---------|---------|-------------|
| Backup time | 11:00 PM | When the backup runs |
| Final pre-backup check | 30 min before | Notification warning if drive is still missing |
| Backup reminder | 120 min before final check | Early heads-up notification |
| Keep N run(s) | 3 | Backup history retention |
| Skip tonight's backup | Off | Defer tonight's scheduled backup |
| Verify backup after sync | On | Run rclone check after Dropbox sync |

The computed notification times are shown live at the bottom of the Schedule section as you adjust intervals.

Select your CCC task and rclone remote from the dropdown menus in the main window.

## Backup schedule

With default settings and an 11 PM backup time:

| Time | Event |
|------|-------|
| 8:00 PM | Reminder notification ("Backup Tonight") |
| 10:30 PM | Final check — alerts if drive still not connected |
| 11:00 PM | Backup runs (CCC first, then Dropbox) |

All three times adjust automatically when you change the backup time or interval settings.

## Skipping a backup

- Toggle "Skip tonight's backup" in the Schedule sheet, or
- Click "Skip Tonight" in the preflight notification

The skip flag resets automatically after the backup window passes. You can still run a manual backup at any time by clicking "Run Backup."

## Uninstalling

1. Quit backit
2. Delete `/Applications/backit.app`
3. Delete `~/Library/LaunchAgents/com.backit.<username>.plist` to remove the login item

## Development

```bash
# Run tests
xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS'

# Build
xcodebuild build -project backit.xcodeproj -scheme backit
```

Tests cover: settings persistence, job lifecycle, backup coordination, schedule timing, rclone output parsing, database operations, and LaunchAgent plist generation.
