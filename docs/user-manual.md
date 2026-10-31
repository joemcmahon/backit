# backit User Manual

## Overview

backit is an application that automates a daily backup of your Dropbox to a local drive. Just run it, set the backup time you prefer, have the disk connected, and it will quietly keep backing up your files until you stop it.

It runs quietly in the background, notifies you before backups, and shows live progress while they run.

backit uses **rclone** to copy your Dropbox cloud storage down to a folder on a local backup volume. That's the only thing it does.

> **Backing up your Mac's internal drive?** Earlier versions of backit could also run a Carbon Copy Cloner task. CCC has its own scheduler, so that job has been removed — schedule your CCC task in CCC itself.

---

## Getting Started

### Before you launch backit

1. **Install rclone** via Homebrew:
   ```
   brew install rclone
   ```

   **Dropbox remote** — run `rclone config` and follow the wizard to add a Dropbox remote. The remote name you give it (e.g., `my-dropbox`) is what you'll select in backit.

2. **Connect your backup drive** — backit needs the destination volume to be mounted at backup time. It will alert you if the disk is missing.

### First launch

- Launch `backit.app` from your Applications folder.
- When prompted, grant notification permission. backit uses notifications to remind you before backups and alert you if something goes wrong.
- The app installs a LaunchAgent at `~/Library/LaunchAgents/backit.plist` — this runs backit headless (no window) once a day at your configured backup time. It does not start backit at login.
- backit will launch and show you its main window; you can now configure your backup.

---

## The Main Window

Click on backit in the dock to bring its window to the front; if you've closed it, just click on the Dock icon to bring it back.

### Dropbox (rclone) section

Shows the status of your rclone Dropbox sync:

- **Source dropdown** — select the rclone remote that you created (e.g., `my-dropbox`)
- **Destination button** — select the local folder where Dropbox will be cloned; it's not required that this be a separate volume, but it should be big enough to handle all your Dropbox files.
- **Live stats during sync:**
  - Listed · Checked · Copied · Errors (sync mode)
  - Same · Missing↓ · Missing↑ · Differs · Errors (verify mode)
- **Transfer line** — bytes transferred and current transfer rate
- **Elapsed time**

After the sync completes, the status line shows:
- `Complete` — all files synced with no issues
- `Done with warnings — some files weren't copied` (orange) — files that should have been copied still failed after retries, or a folder couldn't be fully re-synced. The bottom bar says how many.
- `Done — N rate limit hit(s)` — Dropbox API rate limits were hit; files were retried
- `Verified ✓` — verification passed after sync
- `⚠ N difference(s) found` — verification found mismatches (see Details)

### Bottom bar

| Element | Description |
|---------|-------------|
| Last backup status | ✓ everything copied · ⚠ finished, but some files weren't copied (count shown) · ✗ failed · − skipped |
| Last backup date | When the last backup ran |
| Next backup | Scheduled time for the next automatic backup |
| Details button | Shows the last 12 lines of rclone output + link to full log (appears after rclone runs) |
| ⚙️ | Opens the Schedule sheet |
| Run Backup | Starts a backup immediately |
| Verify Backup | Runs rclone check only (no sync). Hold Option to switch button label. |
| Stop | Cancels the running backup (only shown while a backup is in progress) |

There are also settings to skip the verification, skip tonight's backup (handy if you'll be working past the standard backup start tine; just click the "Start Backup" button to run a backup as soon as you're finished for the day)

---

## Backup Schedule

backit uses a three-notification system to keep you informed before a backup runs.

### How it works

With default settings (11:00 PM backup, 30-min preflight, 120-min reminder):

| Time | What happens |
|------|-------------|
| 8:00 PM | **Reminder** notification — "Backup Tonight at 11:00 PM" |
| 10:30 PM | **Final check** notification — alerts if your backup drive is still not connected |
| 11:00 PM | **Backup runs** — Dropbox sync |

The reminder and final check times adjust automatically when you change the backup time or interval settings.

### Adjusting the schedule

Click ⚙️ to open the Schedule sheet.

**Backup time** — the time the backup fires each day. Use the time picker to change it.

**Final pre-backup check** — how many minutes before the backup to send the "drive not connected" warning. Options: 5, 10, 30, 60, 120 minutes, or a custom value (1–480 min in 5-min steps).

**Backup reminder** — how many minutes before the final check to send the early reminder. Same options as above.

The computed notification times are shown at the bottom of the Schedule section so you can see exactly when things will fire.

### Notifications

**Reminder notification** (default ~2 hours before backup)
- Fires if you're actively using your Mac (another app with a regular window is open)
- Shows the scheduled backup time
- If your backup drive is connected: "you might want to wrap up"
- If your backup drive is not connected: "your backup drive isn't connected yet"

**Final check notification** (default 30 min before backup)
- Only fires if your backup drive is still not connected
- Shows a "Skip Tonight" action button

**If you click "Skip Tonight"** in the final check notification, the backup will be skipped for the day. This resets automatically afterward so tomorrow's backup will run on schedule.

**Backup skipped notification**
- Fires at backup time if the drive is missing or skip is set
- Lets you know the backup didn't run so you can take action

backit only shows notifications when you're actively using your Mac (another app with a regular-policy window is frontmost). It won't interrupt you while your screen is locked or the machine is asleep. (It also can't back up if the machine is asleep! It's recommended that you run Caffeine or a similar program to allow the screen to lock but your Mac to stay awake.)

---

## Skipping a Backup

To skip tonight's scheduled backup:

1. Click ⚙️ and toggle "Skip tonight's backup" to on, or
2. Click the "Skip Tonight" button in the preflight notification

The backup will not run at its scheduled time. The toggle resets automatically after the backup window passes.

You can still run a backup manually at any time by clicking "Run Backup" — this is unaffected by the skip setting.

---

## Running a Manual Backup

Click **Run Backup** at any time to start a backup immediately. The backup runs the same Dropbox sync as a scheduled backup.

To run only the verification step (rclone check, no sync), hold the **Option** key — the button label changes to "Verify Backup." Click it to run verification.

---

## Stopping a backup

If for some reason you decide that there's something wrong or you just want to stop the current backup, click the "Stop Backup" button on the lower right to end the current backup.

## Backup History

backit keeps a record of recent backup runs in a local SQLite database. The **Keep N run(s)** setting (1–10) controls how many runs are retained. Older runs are pruned automatically.

The bottom bar shows the most recent run's status and date.

---

## Verification

After each Dropbox sync, backit can run `rclone check` to verify the local copy matches the remote. This is enabled by default. If you trust `rclone`, you can simply turn this off in the settings (click the gearwheel to access them).

**Verify backup after sync** — toggle in the Schedule sheet. When enabled, verification runs automatically after every sync.

**Manual verification** — hold Option and click the button (shows "Verify Backup") to run a check without syncing.

Verification results appear in the Dropbox section status line:
- `Verified ✓` — everything matches
- `⚠ N difference(s) found` — click Details to see what's different

---

## Backup Drive Detection

backit monitors whether your backup drive is connected. If the drive is missing at backup time:

- The backup is skipped
- A "Backup Skipped" notification is sent
- The preflight notification (30 min before) includes a "Skip Tonight" option so you can decide in advance

backit identifies your backup drive by the destination folder shown in the Dropbox section. Make sure the external drive is connected before backup time each day.

---

## Scheduled Headless Backup

backit installs itself as a LaunchAgent the first time it runs. This does not start backit at login — instead, launchd launches backit headless (no window, no Dock icon) once a day at your configured backup time, runs the backup, and exits.

The LaunchAgent plist is located at:
```
~/Library/LaunchAgents/backit.plist
```

To remove the scheduled run without uninstalling the app, delete this file. It will be reinstalled the next time you launch the app interactively.

---

## Machine Change Detection

backit records your hardware UUID on first run. If it detects a different UUID (meaning you're running on a different Mac), it will warn you. This prevents accidentally backing up to the wrong machine's destination.

---

## Rclone Log

Full rclone output logs are written during each sync:

- **Dropbox:** `/tmp/backit-rclone-YYYYMMDD-HHmmss.log`

Each run writes a new timestamped log file in `/tmp/`. After a sync completes, click the **Details** button to see the last 12 lines of the Dropbox log, or open the log file directly for the complete output.

---

## Backing up iCloud Drive and Photos

backit doesn't back up iCloud Drive or your Photos library directly. For full-resolution backups of both, we recommend **Parachute Backup** by Leitmotif GmbH.

Parachute Backup downloads your iCloud Drive files and iCloud Photos at full resolution to a local folder, preserving the original quality. It runs independently of backit — just point it at a folder on your backup drive and let it sync on its own schedule.

Learn more at [parachutebackup.com](https://parachutebackup.com).

---

## Troubleshooting

**Notifications aren't appearing**
- Open System Settings > Notifications > backit and confirm notifications are allowed
- Notifications only fire when another app with a regular window is active — they won't appear when your screen is locked

**Dropbox remote dropdown shows "Install rclone…"**
- Install rclone: `brew install rclone`
- Relaunch backit after installing

**Dropbox remote dropdown shows "Set up rclone remote…"**
- rclone is installed but has no remotes configured yet
- Run `rclone config` and follow the wizard
- After adding remotes, click the button — it will open Terminal with `rclone config` automatically

**Backup says "skipped" even though drive is connected**
- The path shown in backit's Dropbox section must be an exact match to the mounted volume

**Backup failed with "Backup volume is full"**
- rclone ran out of space on the backup volume. backit stops instead of retrying, since every retry would fail the same way.
- Free up space on the volume (or move to a bigger one) and run the backup again. The next run picks up where this one left off.
- The full rclone log for each run is in `/tmp/backit-rclone-<date>-<time>.log`.

**Scheduled headless backup didn't run**
- Check `~/Library/LaunchAgents/backit.plist` exists
- Run `launchctl list | grep backit` in Terminal — if it's not listed, launch the app manually once to reinstall the LaunchAgent

**After rebuilding the app from Xcode, the backup timer doesn't fire**
- The timers are created when the app launches. If you replace the binary while the app is running, the old process no longer has valid timers. Quit and relaunch backit after every rebuild.

---

## Uninstalling

1. Quit backit (use Activity Monitor if needed)
2. Delete `/Applications/backit.app`
3. Delete `~/Library/LaunchAgents/backit.plist`

UserDefaults (settings) will remain until you delete the app's container or run:
```
defaults delete com.backit
```
