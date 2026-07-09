# backit

A macOS app that automates daily incremental backups to a local drive (via Carbon Copy Cloner) and Dropbox (via rclone). It runs as a normal windowed app when launched interactively, and headless (no window, no Dock icon) when launchd triggers it at your scheduled backup time. Handles scheduling, reminders, progress monitoring, and history.

> **⚠️ Use at your own risk.** backit is a personal project, provided free with no warranty and no guarantee of support (see [LICENSE](LICENSE)). It is not a substitute for a tested, independent backup strategy — verify your restores, keep more than one backup method, and don't rely on this as your only copy of anything important. The author is not liable for data loss, missed backups, or any other damages arising from its use.

# DISCLAIMERS

- **`backit` is meant for experienced users. If you know how to install software and configure it, you'll probably get on all right. If you don't, backit will almost certainly be frustrating for you.**
- I will respond to questions and try to address problems via GitHub issues as I can. 
- I don't do realtime 24/7 support. It's just me, with a limited amount of time.
- You are responsible for anything that happens when you use `backit`. I've not lost data but that doesn't mean it's impossible.
- `backit` _does not_ back up iCloud files or photos for technical reasons too boring to get into. The excellent [Parachute Backup](https://parachuteapps.com/parachute) does. I use it for those backups. (I tried in `backit`. It was not pretty. The terrible results lurk in the old commits.)
- `backit` backups have only been tested on local disks, so if you try it to G Drive or OneDrive or wherever else, that unexplored (and unsupported) territory. If you have a breakthrough with one of these, you can certainly open an issue to tell me about it.
- `backit` is not a substitute for a full local + external backup solution, though it can be part of one.
- PRs are welcome, but they will absolutely be rejected without a full, passing test suite, and PRs that are "too big" (which is solely at my discretion) will be rejected, period.

## Why backit?

Maestral, a popular open-source Dropbox client, is no longer maintained — leaving people who relied on it without a reliable way to keep a local copy of their Dropbox contents in sync.

backit doesn't try to be a Dropbox sync client. Instead, it uses rclone to talk directly to the Dropbox API and mirror your Dropbox contents down to a local backup volume on a schedule — no Dropbox desktop app (official or third-party) needs to be installed or running. Paired with a scheduled Carbon Copy Cloner run of your internal drive, that gives you a periodic, dependable local backup of both your Mac and your Dropbox files with one tool.

> **⚠️ The local Dropbox copy is a backup, not your Dropbox folder.** rclone copies one-way, from Dropbox down to the local volume — it is not a live, two-way synced folder like Dropbox's own app or Maestral provide. **Don't create, edit, or delete files directly in the local backup copy.** Nothing you do there is sent back up to Dropbox, and anything you change will be silently overwritten or deleted the next time backit runs, to match whatever is currently in Dropbox. Make your real edits in Dropbox itself (web, mobile, or a sync client) — this backup volume exists purely so you have a recent offline copy if Dropbox, your account, or your original files are ever lost.

## What it does

- Runs a named CCC task to back up your internal drive
- Syncs your Dropbox remote to a local backup volume via rclone
- Sends smart notifications before backups (reminder → final check → backup)
- Skips silently if your backup drive isn't connected, then notifies you
- Tracks backup history in a local SQLite database, viewable in a Run History window
- Installs a LaunchAgent that runs the backup headless once a day at your configured time

## Requirements

- macOS 26.2 or later
- [Carbon Copy Cloner](https://bombich.com) — with a task already configured
- [rclone](https://rclone.org) — with a Dropbox remote already configured (`brew install rclone`)

Both tools must be configured before backit can run backups. backit provides the scheduling and orchestration; CCC and rclone do the actual backup work.

## Installation

1. Build and copy `backit.app` to `/Applications/`
2. Launch the app
3. Grant notification permission when prompted
4. The app installs a LaunchAgent automatically — it runs headless once a day at your configured backup time (not at login)

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
3. Delete `~/Library/LaunchAgents/backit.plist` to remove the scheduled headless run

## Development

```bash
# Run tests
xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS'

# Build
xcodebuild build -project backit.xcodeproj -scheme backit
```

Tests cover: settings persistence, job lifecycle, backup coordination, schedule timing, rclone output parsing, database operations, and LaunchAgent plist generation.
