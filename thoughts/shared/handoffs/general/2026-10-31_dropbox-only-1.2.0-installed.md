---
date: 2026-10-31
session_name: general
researcher: Claude Opus 5.5
git_commit: 0247427
branch: main
repository: backit
topic: "Dropbox-only 1.2.0: run-failure fixes, warning status, installed to /Applications"
tags: [dropbox-only, ccc-removal, rclone, disk-full, hang, warning-status, launchagent]
status: complete
last_updated: 2026-10-31
last_updated_by: Claude Opus 5.5
type: implementation_strategy
---

# Handoff: backit 1.2.0 (Dropbox-only) installed; awaiting first real nightly run

## What was done (all pushed to origin/main, CI green on 0247427)

- `c1358ce` **CCC removed; backit is Dropbox-only; version 1.2.0.** CCCJob, its tests,
  CCCTaskLoader, the CCC UI and CCC settings are all gone. `JobType` is `.dropbox` only.
  `DatabaseManager.purgeLegacyCCCHistory()` runs on open and deletes CCC runs/results.
- `ffbbde5`: after the purge, `partial` runs are re-derived from their Dropbox result.
- `b8a3c72`: `migrate()` checks `columnExists` before `ALTER TABLE jobResult ADD COLUMN
  completedAt`. This fixed the "duplicate column name" console error.
- `dd7d06d` **Run-failure fixes:**
  - **Hang:** retry/cleanup passes deadlocked on an unread stderr pipe, so runs lasted about
    24 hours until the next night's `killOrphanedRclones()` killed rclone. New
    `ProcessRunner.runCollectingStderr` sends stderr to a temp file.
  - **Disk full** (Oct 26–28 runs): `RcloneStats.volumeFull` is set from "no space left on
    device". backit skips retry/cleanup/verify, marks the run failed, and reports
    "Backup volume is full".
  - The retry pass now passes `--use-json-log`. Without it, files that failed again were
    never detected.
- `0247427` **Warning status:** if files that should have copied didn't, or a folder
  couldn't be fully synced, `JobStatus.warning` is set and the run is recorded as `partial`.
  The UI shows an orange ⚠️ with the reason (e.g. "3 files couldn't be copied"). A green
  check now means everything was copied.
- Docs, site and in-app help all describe the Dropbox-only tool. The site screenshot was
  retaken (480×207).

## Installed state (as of 2026-10-31)

- `/Applications/backit.app` is a Release build of 0247427 (1.2.0). It is signed with team
  6PLL9M5SE2, and the signature verifies.
- `~/Library/LaunchAgents/backit.plist` points to `/Applications/backit.app/Contents/MacOS/backit`
  and runs at 22:55.
- The old 1.1.1 app was copied to the session scratchpad. It will be lost on reboot, which
  doesn't matter.

## Gotcha discovered: test runs take over the LaunchAgent

`LaunchAgentManager` reinstalls the plist whenever `Bundle.main.executablePath` differs
from the installed one. Running tests or Xcode's Run therefore repoints the nightly backup
at a DerivedData build. This happened on Oct 30: the Variant-NoSanitizers Debug build from
18:31 ran that night instead of the latest code.
**Proposed fix (not done; offered to the user):** skip the LaunchAgent install when running
under XCTest (`XCTestConfigurationFilePath` env var) or from a DerivedData path.
**Workaround until it's fixed:** after running tests, launch `/Applications/backit.app` once.

## Next steps

1. Check tonight's (2026-10-31, 22:55) run. Logs are in `/tmp/backit-rclone-*.log`; the DB is
   `~/Library/Application Support/backit/backit.db`. Expect it to finish (no 24h hang).
   It should show a green check, or an orange ⚠️ with a count if anything was missed.
   Note that /tmp is cleared on reboot, so older logs will be gone.
2. Decide on the LaunchAgent/XCTest fix above.
3. Not yet done: tag `v1.2.0`. Pushing a `v*` tag starts the signed/notarized release, so
   ask first. The site's install section still says "No signed releases yet", which is out
   of date.
4. Known leftover (deliberately conservative): a run with rclone errors that don't name a
   file is still marked failed, even if the retries fixed everything.

## Useful commands

- Unit tests: `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS' -skip-testing:backitUITests CODE_SIGNING_ALLOWED=NO`
- Install: build `-configuration Release`, `ditto` the app into /Applications, then `open` it
  once so the LaunchAgent is repointed.
