# backit User Manual

## Overview

backit is an application that automates daily backups of your system and your Dropbox. Just run it, set the backup time you prefer, have the disk connected, and it will quietly keep backing up your files until you stop it.

It runs quietly in the background, notifies you before backups, and shows live progress while they run.

backit runs two backup tools that you configure separately:

- **Carbon Copy Cloner (CCC)** — handles the backup of your internal Mac drive to an external volume
- **rclone** — syncs your Dropbox and iCloud Drive cloud storage to local folders on a backup volume

---

## Getting Started

### Before you launch backit

1. **Install Carbon Copy Cloner** from [bombich.com](https://bombich.com) and create at least one backup task.
   - Open CCC, click the `+` button, name your task (e.g., "My Backup"), choose a source and destination, and save.
   - You'll enter this task name in backit's settings to configure the hard disk backup.

2. **Install rclone** via Homebrew:
   ```
   brew install rclone
   ```

   **Dropbox remote** — run `rclone config` and follow the wizard to add a Dropbox remote. The remote name you give it (e.g., `my-dropbox`) is what you'll select in backit.

   **iCloud Drive remote** — iCloud authentication requires capturing a session cookie from a browser login. The easiest way is the [rclone-icloud-authenticator](https://github.com/EvansMatthew97/rclone-icloud-authenticator) tool:
   ```
   npm install -g rclone-icloud-authenticator
   rclone-icloud-authenticator
   ```
   It opens a browser window, walks you through Apple ID login and 2FA, then writes the resulting session cookie into your `~/.config/rclone/rclone.conf` automatically. Give the remote a name (e.g., `my-icloud`) — that's what you'll select in backit.

   > **Cookie expiry:** iCloud session cookies do not auto-refresh. When the cookie expires (typically weeks to months), rclone will start failing with authentication errors. Re-run `rclone-icloud-authenticator` to capture a fresh cookie and update `rclone.conf`.

3. **Connect your backup drive** — backit needs the destination volume or volumes to be mounted at backup time. It will alert you if the disk or disks are missing.

### First launch

- Launch `backit.app` from your Applications folder.
- When prompted, grant notification permission. backit uses notifications to remind you before backups and alert you if something goes wrong.
- The app installs a LaunchAgent at `~/Library/LaunchAgents/com.backit.<username>.plist` — this allows it to start automatically at every login.
- backit will launch and show you its main window; you can now configure your backup.

---

## The Main Window

Click on backit in the dock to bring its window to the front; if you've closed it, just clikc on the Dock icon to bring it back.

### Internal Disk (CCC) section

Shows the status of your Carbon Copy Cloner backup:

- **Source dropdown** — select the CCC task to run (this is automatically populated from CCC's saved tasks - just pick the one you set up earlier)
- **Destination button** — opens CCC so you can view or edit the task
- **Progress bar** — fills as the backup progresses (0–100%)
- **Elapsed time** — how long the backup has been running

During the scan phase at the start of a CCC backup, the progress bar shows "Scanning…" until CCC determines what needs to be copied. There's usually some time while CCC figures out how long the backup will take before the progress bar starts updating -- don't worry! You can always switch over to CCC and check the backup progress in its window.

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
- `Done — N file(s) skipped` — some files were skipped (usually permission errors)
- `Done — N rate limit hit(s)` — Dropbox API rate limits were hit; files were retried
- `Verified ✓` — verification passed after sync
- `⚠ N difference(s) found` — verification found mismatches (see Details)

### iCloud Drive (rclone) section

Shows the status of your rclone iCloud Drive sync. Works the same as the Dropbox section:

- **Source dropdown** — select the rclone remote for iCloud (e.g., `my-icloud`)
- **Destination button** — select the local folder where iCloud Drive will be cloned
- **Live stats, transfer line, and elapsed time** — same as Dropbox section above

After sync completes, the status messages are the same as Dropbox. iCloud Drive uses `--ignore-size` on all rclone operations because the iCloud web API reports uncompressed sizes for bundle files (`.pages`, `.numbers`, `.key`, HEIC, etc.) but delivers compressed payloads — rclone would otherwise flag these as mismatches.

> **If iCloud sync starts failing with auth errors**, your session cookie has expired. Re-run `rclone-icloud-authenticator` to refresh it, then restart backit.

### Bottom bar

| Element | Description |
|---------|-------------|
| Last backup status | ✓ success · ⚠ partial failure · − skipped |
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
| 11:00 PM | **Backup runs** — CCC first, then Dropbox |

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

Click **Run Backup** at any time to start a backup immediately. The backup runs the same sequence as a scheduled backup: CCC first, then Dropbox.

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

backit identifies your backup drive by the volume path configured in your CCC task. Make sure the external drive is connected before backup time each day.

---

## Login Item

backit installs itself as a LaunchAgent the first time it runs. This means it starts automatically at every login, without requiring any action from you.

The LaunchAgent plist is located at:
```
~/Library/LaunchAgents/com.backit.<username>.plist
```

To remove the login item without uninstalling the app, delete this file and the app will not restart at login. You can re-enable it by launching the app again manually.

---

## Machine Change Detection

backit records your hardware UUID on first run. If it detects a different UUID (meaning you're running on a different Mac), it will warn you. This prevents accidentally backing up to the wrong machine's destination.

---

## Rclone Log

Full rclone output logs are written during each sync:

- **Dropbox:** `/tmp/backit-rclone-YYYYMMDD-HHmmss.log`
- **iCloud Drive:** `/tmp/backit-icloud-rclone-YYYYMMDD-HHmmss.log`

Each run writes a new timestamped log file in `/tmp/`. After a sync completes, click the **Details** button to see the last 12 lines of the Dropbox log, or open the log file directly for the complete output.

---

## Backing up Photos

backit doesn't back up your Photos library directly, but if you use Dropbox you can get your photos covered with no extra tooling.

Enable **Camera Uploads** in the Dropbox app (Preferences → Imports → Enable Camera Uploads). Dropbox will upload your photos and videos to a `Camera Uploads` folder in your Dropbox. Since backit already backs up your Dropbox, those images are included in every rclone sync automatically.

Camera Uploads doesn't need to be on all the time. Turning it on periodically — say, once a month — lets Dropbox catch up with any new photos, then you can turn it off again. The next backit run will sync the updated folder to your backup volume.

Note that this saves the raw image files only — albums, faces, memories, and other Photos.app metadata are not preserved. For a full Photos library restore, a separate strategy (such as a secondary iCloud Photos library on an external drive) would be needed.

---

## Troubleshooting

**Notifications aren't appearing**
- Open System Settings > Notifications > backit and confirm notifications are allowed
- Notifications only fire when another app with a regular window is active — they won't appear when your screen is locked

**CCC task dropdown is empty**
- Make sure Carbon Copy Cloner is installed at `/Applications/Carbon Copy Cloner.app`
- Create at least one task in CCC before launching backit

**Dropbox or iCloud remote dropdown shows "Install rclone…"**
- Install rclone: `brew install rclone`
- Relaunch backit after installing

**Dropbox or iCloud remote dropdown shows "Set up rclone remote…"**
- rclone is installed but has no remotes configured yet
- For Dropbox: run `rclone config` and follow the wizard
- For iCloud: install and run `rclone-icloud-authenticator` (see Getting Started)
- After adding remotes, click the button — it will open Terminal with `rclone config` automatically

**iCloud sync failing with auth/permission errors**
- Your iCloud session cookie has expired
- Re-run `rclone-icloud-authenticator` to capture a fresh cookie, then restart backit

**Backup says "skipped" even though drive is connected**
- Check that the volume path matches what CCC has configured as the destination
- The path shown in backit's Dropbox section must be an exact match to the mounted volume

**Progress bar stuck at 0% / "Scanning…"**
- CCC scans the source and destination before it starts copying. This can take a few minutes for large volumes. This is normal.

**App doesn't start at login**
- Check `~/Library/LaunchAgents/com.backit.<username>.plist` exists
- Run `launchctl list | grep backit` in Terminal — if it's not listed, launch the app manually once to reinstall the LaunchAgent

**After rebuilding the app from Xcode, the backup timer doesn't fire**
- The timers are created when the app launches. If you replace the binary while the app is running, the old process no longer has valid timers. Quit and relaunch backit after every rebuild.

---

## Uninstalling

1. Quit backit (right-click the menubar icon if available, or use Activity Monitor)
2. Delete `/Applications/backit.app`
3. Delete `~/Library/LaunchAgents/com.backit.<username>.plist`

UserDefaults (settings) will remain until you delete the app's container or run:
```
defaults delete com.backit
```
