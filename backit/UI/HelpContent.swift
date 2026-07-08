// HTML source for the in-app help window.
// Regenerate from docs/user-manual.md when the manual changes.
enum HelpContent {
    static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root {
        --bg: #ffffff;
        --fg: #1d1d1f;
        --heading: #1d1d1f;
        --muted: #6e6e73;
        --code-bg: #f2f2f7;
        --code-fg: #1d1d1f;
        --border: #d1d1d6;
        --link: #0066cc;
        --table-header: #f2f2f7;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1c1c1e;
          --fg: #f5f5f7;
          --heading: #f5f5f7;
          --muted: #98989d;
          --code-bg: #2c2c2e;
          --code-fg: #f5f5f7;
          --border: #3a3a3c;
          --link: #2997ff;
          --table-header: #2c2c2e;
        }
      }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        background: var(--bg);
        color: var(--fg);
        font: -apple-system-body, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 14px;
        line-height: 1.6;
        padding: 28px 32px 48px;
        max-width: 720px;
      }
      h1 { font-size: 22px; font-weight: 700; color: var(--heading); margin: 0 0 6px; }
      h2 { font-size: 17px; font-weight: 600; color: var(--heading); margin: 32px 0 10px; border-bottom: 1px solid var(--border); padding-bottom: 5px; }
      h3 { font-size: 14px; font-weight: 600; color: var(--heading); margin: 20px 0 8px; }
      p  { margin: 0 0 10px; }
      ul, ol { margin: 0 0 10px 22px; }
      li { margin-bottom: 4px; }
      li p { margin: 0; }
      code {
        background: var(--code-bg);
        color: var(--code-fg);
        font-family: "SF Mono", Menlo, monospace;
        font-size: 12px;
        padding: 1px 5px;
        border-radius: 4px;
      }
      pre {
        background: var(--code-bg);
        color: var(--code-fg);
        font-family: "SF Mono", Menlo, monospace;
        font-size: 12px;
        padding: 12px 14px;
        border-radius: 8px;
        overflow-x: auto;
        margin: 0 0 12px;
        line-height: 1.5;
      }
      pre code { background: none; padding: 0; }
      a { color: var(--link); text-decoration: none; }
      a:hover { text-decoration: underline; }
      hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
      table {
        width: 100%;
        border-collapse: collapse;
        margin: 0 0 12px;
        font-size: 13px;
      }
      th {
        background: var(--table-header);
        text-align: left;
        padding: 7px 10px;
        border-bottom: 1px solid var(--border);
        font-weight: 600;
      }
      td {
        padding: 6px 10px;
        border-bottom: 1px solid var(--border);
        vertical-align: top;
      }
      .subtitle { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
    </style>
    </head>
    <body>

    <h1>backit User Manual</h1>
    <p class="subtitle">Automated daily backups for macOS</p>

    <h2>Overview</h2>
    <p>backit is an application that automates daily backups of your system and your Dropbox. Just run it, set the backup time you prefer, have the disk connected, and it will quietly keep backing up your files until you stop it.</p>
    <p>It runs quietly in the background, notifies you before backups, and shows live progress while they run.</p>
    <p>backit runs two backup tools that you configure separately:</p>
    <ul>
      <li><strong>Carbon Copy Cloner (CCC)</strong> — handles the backup of your internal Mac drive to an external volume</li>
      <li><strong>rclone</strong> — syncs your Dropbox cloud storage to a local folder on a backup volume</li>
    </ul>

    <hr>

    <h2>Getting Started</h2>
    <h3>Before you launch backit</h3>
    <ol>
      <li>
        <p><strong>Install Carbon Copy Cloner</strong> from <a href="https://bombich.com">bombich.com</a> and create at least one backup task.</p>
        <ul>
          <li>Open CCC, click the <code>+</code> button, name your task (e.g., "My Backup"), choose a source and destination, and save.</li>
          <li>You'll enter this task name in backit's settings to configure the hard disk backup.</li>
        </ul>
      </li>
      <li>
        <p><strong>Install rclone</strong> via Homebrew:</p>
        <pre>brew install rclone</pre>
        <p><strong>Dropbox remote</strong> — run <code>rclone config</code> and follow the wizard to add a Dropbox remote. The remote name you give it (e.g., <code>my-dropbox</code>) is what you'll select in backit.</p>
      </li>
      <li><strong>Connect your backup drive</strong> — backit needs the destination volume or volumes to be mounted at backup time. It will alert you if the disk or disks are missing.</li>
    </ol>

    <h3>First launch</h3>
    <ul>
      <li>Launch <code>backit.app</code> from your Applications folder.</li>
      <li>When prompted, grant notification permission. backit uses notifications to remind you before backups and alert you if something goes wrong.</li>
      <li>The app installs a LaunchAgent at <code>~/Library/LaunchAgents/backit.plist</code> — this runs backit headless (no window) once a day at your configured backup time. It does not start backit at login.</li>
      <li>backit will launch and show you its main window; you can now configure your backup.</li>
    </ul>

    <hr>

    <h2>The Main Window</h2>
    <p>Click on backit in the Dock to bring its window to the front; if you've closed it, just click on the Dock icon to bring it back.</p>

    <h3>Internal Disk (CCC) section</h3>
    <p>Shows the status of your Carbon Copy Cloner backup:</p>
    <ul>
      <li><strong>Source dropdown</strong> — select the CCC task to run (automatically populated from CCC's saved tasks)</li>
      <li><strong>Destination button</strong> — opens CCC so you can view or edit the task</li>
      <li><strong>Progress bar</strong> — fills as the backup progresses (0–100%)</li>
      <li><strong>Elapsed time</strong> — how long the backup has been running</li>
    </ul>
    <p>During the scan phase at the start of a CCC backup, the progress bar shows "Scanning…" until CCC determines what needs to be copied. There's usually some time while CCC figures out how long the backup will take before the progress bar starts updating — you can always switch over to CCC and check progress in its window.</p>

    <h3>Dropbox (rclone) section</h3>
    <p>Shows the status of your rclone Dropbox sync:</p>
    <ul>
      <li><strong>Source dropdown</strong> — select the rclone remote that you created (e.g., <code>my-dropbox</code>)</li>
      <li><strong>Destination button</strong> — select the local folder where Dropbox will be cloned; it's not required that this be a separate volume, but it should be big enough to handle all your Dropbox files</li>
      <li><strong>Live stats during sync:</strong>
        <ul>
          <li>Listed · Checked · Copied · Errors (sync mode)</li>
          <li>Same · Missing↓ · Missing↑ · Differs · Errors (verify mode)</li>
        </ul>
      </li>
      <li><strong>Transfer line</strong> — bytes transferred and current transfer rate</li>
      <li><strong>Elapsed time</strong></li>
    </ul>
    <p>After the sync completes, the status line shows:</p>
    <ul>
      <li><code>Complete</code> — all files synced with no issues</li>
      <li><code>Done — N file(s) skipped</code> — some files were skipped (usually permission errors)</li>
      <li><code>Done — N rate limit hit(s)</code> — Dropbox API rate limits were hit; files were retried</li>
      <li><code>Verified ✓</code> — verification passed after sync</li>
      <li><code>⚠ N difference(s) found</code> — verification found mismatches (see Details)</li>
    </ul>

    <h3>Bottom bar</h3>
    <table>
      <tr><th>Element</th><th>Description</th></tr>
      <tr><td>Last backup status</td><td>✓ success · ⚠ partial failure · − skipped</td></tr>
      <tr><td>Last backup date</td><td>When the last backup ran</td></tr>
      <tr><td>Next backup</td><td>Scheduled time for the next automatic backup</td></tr>
      <tr><td>Details button</td><td>Shows the last 12 lines of rclone output + link to full log (appears after rclone runs)</td></tr>
      <tr><td>⚙</td><td>Opens the Schedule sheet</td></tr>
      <tr><td>Run Backup</td><td>Starts a backup immediately</td></tr>
      <tr><td>Verify Backup</td><td>Runs rclone check only (no sync). Hold Option to switch the button label.</td></tr>
      <tr><td>Stop</td><td>Cancels the running backup (only shown while a backup is in progress)</td></tr>
    </table>
    <p>The Schedule sheet also lets you skip verification, skip tonight's backup (handy if you'll be working past the standard backup start time), and configure the backup reminder intervals.</p>

    <hr>

    <h2>Backup Schedule</h2>
    <p>backit uses a three-notification system to keep you informed before a backup runs.</p>

    <h3>How it works</h3>
    <p>With default settings (11:00 PM backup, 30-min preflight, 120-min reminder):</p>
    <table>
      <tr><th>Time</th><th>What happens</th></tr>
      <tr><td>8:00 PM</td><td><strong>Reminder</strong> notification — "Backup Tonight at 11:00 PM"</td></tr>
      <tr><td>10:30 PM</td><td><strong>Final check</strong> notification — alerts if your backup drive is still not connected</td></tr>
      <tr><td>11:00 PM</td><td><strong>Backup runs</strong> — CCC first, then Dropbox</td></tr>
    </table>
    <p>The reminder and final check times adjust automatically when you change the backup time or interval settings.</p>

    <h3>Adjusting the schedule</h3>
    <p>Click ⚙ to open the Schedule sheet.</p>
    <p><strong>Backup time</strong> — the time the backup fires each day. Use the time picker to change it.</p>
    <p><strong>Final pre-backup check</strong> — how many minutes before the backup to send the "drive not connected" warning. Options: 5, 10, 30, 60, 120 minutes, or a custom value (1–480 min in 5-min steps).</p>
    <p><strong>Backup reminder</strong> — how many minutes before the final check to send the early reminder. Same options as above.</p>
    <p>The computed notification times are shown at the bottom of the Schedule section so you can see exactly when things will fire.</p>

    <h3>Notifications</h3>
    <p><strong>Reminder notification</strong> (default ~2 hours before backup)</p>
    <ul>
      <li>Fires if you're actively using your Mac (another app with a regular window is open)</li>
      <li>Shows the scheduled backup time</li>
      <li>If your backup drive is connected: "you might want to wrap up"</li>
      <li>If your backup drive is not connected: "your backup drive isn't connected yet"</li>
    </ul>
    <p><strong>Final check notification</strong> (default 30 min before backup)</p>
    <ul>
      <li>Only fires if your backup drive is still not connected</li>
      <li>Shows a "Skip Tonight" action button</li>
    </ul>
    <p>If you click <strong>Skip Tonight</strong> in the final check notification, the backup will be skipped for the day. This resets automatically afterward so tomorrow's backup will run on schedule.</p>
    <p><strong>Backup skipped notification</strong> — fires at backup time if the drive is missing or skip is set, so you know the backup didn't run.</p>
    <p>backit only shows notifications when you're actively using your Mac. It won't interrupt you while your screen is locked or the machine is asleep. (It also can't back up if the machine is asleep — it's recommended that you run Caffeine or a similar utility to allow the screen to lock while keeping your Mac awake.)</p>

    <hr>

    <h2>Skipping a Backup</h2>
    <p>To skip tonight's scheduled backup:</p>
    <ol>
      <li>Click ⚙ and toggle "Skip tonight's backup" to on, or</li>
      <li>Click the "Skip Tonight" button in the preflight notification</li>
    </ol>
    <p>The backup will not run at its scheduled time. The toggle resets automatically after the backup window passes.</p>
    <p>You can still run a backup manually at any time by clicking "Run Backup" — this is unaffected by the skip setting.</p>

    <hr>

    <h2>Running a Manual Backup</h2>
    <p>Click <strong>Run Backup</strong> at any time to start a backup immediately. The backup runs the same sequence as a scheduled backup: CCC first, then Dropbox.</p>
    <p>To run only the verification step (rclone check, no sync), hold the <strong>Option</strong> key — the button label changes to "Verify Backup." Click it to run verification.</p>

    <hr>

    <h2>Stopping a Backup</h2>
    <p>If you want to stop the current backup, click the <strong>Stop</strong> button on the lower right to end it immediately.</p>

    <hr>

    <h2>Backup History</h2>
    <p>backit keeps a record of recent backup runs in a local SQLite database. The <strong>Keep N run(s)</strong> setting (1–10) controls how many runs are retained. Older runs are pruned automatically.</p>
    <p>The bottom bar shows the most recent run's status and date.</p>

    <hr>

    <h2>Verification</h2>
    <p>After each Dropbox sync, backit can run <code>rclone check</code> to verify the local copy matches the remote. This is enabled by default. If you trust rclone, you can turn it off in the Schedule sheet.</p>
    <p><strong>Verify backup after sync</strong> — toggle in the Schedule sheet. When enabled, verification runs automatically after every sync.</p>
    <p><strong>Manual verification</strong> — hold Option and click the button (shows "Verify Backup") to run a check without syncing.</p>
    <p>Verification results appear in the Dropbox section status line:</p>
    <ul>
      <li><code>Verified ✓</code> — everything matches</li>
      <li><code>⚠ N difference(s) found</code> — click Details to see what's different</li>
    </ul>

    <hr>

    <h2>Backup Drive Detection</h2>
    <p>backit monitors whether your backup drive is connected. If the drive is missing at backup time:</p>
    <ul>
      <li>The backup is skipped</li>
      <li>A "Backup Skipped" notification is sent</li>
      <li>The preflight notification (30 min before) includes a "Skip Tonight" option so you can decide in advance</li>
    </ul>
    <p>backit identifies your backup drive by the volume path configured in your CCC task. Make sure the external drive is connected before backup time each day.</p>

    <hr>

    <h2>Scheduled Headless Backup</h2>
    <p>backit installs itself as a LaunchAgent the first time it runs. This does not start backit at login — instead, launchd launches backit headless (no window, no Dock icon) once a day at your configured backup time, runs the backup, and exits.</p>
    <p>The LaunchAgent plist is located at:</p>
    <pre>~/Library/LaunchAgents/backit.plist</pre>
    <p>To remove the scheduled run without uninstalling the app, delete this file. It will be reinstalled the next time you launch the app interactively.</p>

    <hr>

    <h2>Machine Change Detection</h2>
    <p>backit records your hardware UUID on first run. If it detects a different UUID (meaning you're running on a different Mac), it will warn you. This prevents accidentally backing up to the wrong destination.</p>

    <hr>

    <h2>rclone Log</h2>
    <p>Full rclone output logs are written during each sync:</p>
    <ul>
      <li><strong>Dropbox:</strong> <code>/tmp/backit-rclone-YYYYMMDD-HHmmss.log</code></li>
    </ul>
    <p>Each run writes a new timestamped log file in <code>/tmp/</code>. After a sync completes, click the <strong>Details</strong> button to see the last 12 lines of the Dropbox log, or open the log file directly for the complete output.</p>

    <hr>

    <h2>Backing up iCloud Drive and Photos</h2>
    <p>backit doesn't back up iCloud Drive or your Photos library directly. For full-resolution backups of both, we recommend <strong>Parachute Backup</strong> by Leitmotif GmbH.</p>
    <p>Parachute Backup downloads your iCloud Drive files and iCloud Photos at full resolution to a local folder, preserving the original quality. It runs independently of backit — just point it at a folder on your backup drive and let it sync on its own schedule.</p>
    <p>Learn more at <a href="https://parachutebackup.com">parachutebackup.com</a>.</p>

    <hr>

    <h2>Troubleshooting</h2>
    <h3>Notifications aren't appearing</h3>
    <ul>
      <li>Open System Settings &gt; Notifications &gt; backit and confirm notifications are allowed</li>
      <li>Notifications only fire when another app with a regular window is active — they won't appear when your screen is locked</li>
    </ul>
    <h3>CCC task dropdown is empty</h3>
    <ul>
      <li>Make sure Carbon Copy Cloner is installed at <code>/Applications/Carbon Copy Cloner.app</code></li>
      <li>Create at least one task in CCC before launching backit</li>
    </ul>
    <h3>Remote dropdown shows "Install rclone…"</h3>
    <ul>
      <li>Install rclone: <code>brew install rclone</code></li>
      <li>Relaunch backit after installing</li>
    </ul>
    <h3>Remote dropdown shows "Set up rclone remote…"</h3>
    <ul>
      <li>rclone is installed but has no remotes configured yet</li>
      <li>For Dropbox: run <code>rclone config</code> and follow the wizard</li>
      <li>Clicking the button will open Terminal with <code>rclone config</code> automatically</li>
    </ul>
    <h3>Backup says "skipped" even though drive is connected</h3>
    <ul>
      <li>Check that the volume path matches what CCC has configured as the destination</li>
      <li>The path shown in backit's Dropbox section must be an exact match to the mounted volume</li>
    </ul>
    <h3>Progress bar stuck at 0% / "Scanning…"</h3>
    <ul>
      <li>CCC scans source and destination before copying. This can take a few minutes for large volumes. This is normal.</li>
    </ul>
    <h3>Scheduled headless backup didn't run</h3>
    <ul>
      <li>Check that <code>~/Library/LaunchAgents/backit.plist</code> exists</li>
      <li>Run <code>launchctl list | grep backit</code> in Terminal — if it's not listed, launch the app once to reinstall the LaunchAgent</li>
    </ul>
    <h3>After rebuilding from Xcode, the backup timer doesn't fire</h3>
    <ul>
      <li>Timers are created at launch. If you replace the binary while the app is running, the old timers are gone. Quit and relaunch backit after every rebuild.</li>
    </ul>

    <hr>

    <h2>Uninstalling</h2>
    <ol>
      <li>Quit backit (use Activity Monitor if needed)</li>
      <li>Delete <code>/Applications/backit.app</code></li>
      <li>Delete <code>~/Library/LaunchAgents/backit.plist</code></li>
    </ol>
    <p>To remove saved settings:</p>
    <pre>defaults delete com.backit</pre>

    </body>
    </html>
    """
}
