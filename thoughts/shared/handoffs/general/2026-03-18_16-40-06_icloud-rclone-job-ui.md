---
date: 2026-03-18T23:40:06Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: ade53cf0d83f12904555e30eea37270dd053668d
branch: main
repository: backit
topic: "iCloud Drive rclone backup — ICloudJob + UI wiring"
tags: [swift, rclone, icloud, ui, appkit]
status: complete
last_updated: 2026-03-18
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: iCloud Drive rclone backup job + UI

## Task(s)

| Task | Status |
|------|--------|
| Delete unused `HelpView.swift` | ✅ Done |
| Diagnose `.partial` file errors in rclone iCloud transfer | ✅ Done — root cause identified |
| Add `ICloudJob.swift` (new BackupJob for iCloud Drive via rclone) | ✅ Done |
| Wire `ICloudJob` into `BackupCoordinator` and UI | ✅ Done |
| iCloud section uses `icloud` SF Symbol | ✅ Done |
| Dropbox custom icon asset | ⏳ Pending — user will create asset |

## Critical References

- `backit/Jobs/ICloudJob.swift` — new job, mirrors DropboxJob + `--ignore-size`
- `backit/Jobs/DropboxJob.swift` — reference implementation for rclone jobs
- `backit/UI/BackitMainView.swift` — UI; `RcloneStatusView` now takes `title` + `systemImage` params

## Recent Changes

- `backit/UI/HelpView.swift` — **deleted** (unused NSViewRepresentable stub)
- `backit/Database/Models.swift:8` — added `case icloud` to `JobType` enum
- `backit/Jobs/ICloudJob.swift` — new file; full rclone job with `--ignore-size` on sync, check, cleanup, and retry
- `backitTests/ICloudJobTests.swift` — new file; 3 async tests (idle status, jobType, cancel)
- `backit/Settings/BackupSettings.swift:14-15,31-32` — added `icloudRemoteName` (default `""`) + `icloudVolumePath` (default `""`)
- `backit/Coordination/BackupCoordinator.swift:11,17` — added `@Published var icloudProgress` + `icloudStats`
- `backit/Coordination/BackupCoordinator.swift:38-44` — `defaultFactory` adds `ICloudJob` when rclone installed and `icloudRemoteName` non-empty
- `backit/Coordination/BackupCoordinator.swift:149-170` — stats task and post-job processing handle both `DropboxJob` and `ICloudJob`
- `backit/Coordination/BackupCoordinator.swift:120,137,214,217` — `.icloud` routes to `icloudProgress`/`icloudStats`; both reset on completion
- `backit/UI/BackitMainView.swift:31-50` — separate iCloud `RcloneStatusView` section with own pickers
- `backit/UI/BackitMainView.swift:157-175` — `icloudRemotePicker` + `icloudFolderPicker`
- `backit/UI/BackitMainView.swift:356-358` — `RcloneStatusView` gains `title: String` + `systemImage: String = "arrow.triangle.2.circlepath"` params

## Learnings

**`.partial` file errors in rclone iCloud = false positive, not real corruption.**
iWork files (`.pages`, `.numbers`, `.key`) and HEIC files are package bundles that Apple compresses on-the-fly when served via the iCloud web API. iCloud reports the uncompressed size in metadata but delivers a smaller compressed payload. rclone detects "sizes differ" and refuses to copy. Fix: `--ignore-size`. This flag must be on ALL rclone commands for an iCloud remote: sync, check, cleanup retry, and `--files-from` copy.

**iCloud rclone auth requires cookie capture.**
rclone's iCloud Drive backend authenticates via a session cookie (`X-APPLE-WEBAUTH-HSA-TRUST`). The user must log in to iCloud in a browser with "Trust this device", complete 2FA, and capture the resulting cookie. The cookie goes into `~/.config/rclone/rclone.conf` for the iCloud remote. See https://github.com/EvansMatthew97/rclone-icloud-authenticator for a Puppeteer-based helper that automates this. No auto-refresh — when cookie expires, user must redo the dance.

**`PBXFileSystemSynchronizedRootGroup` means no xcodeproj edits needed.**
New `.swift` files added to existing directories under `backit/` and `backitTests/` are auto-included in the build target. No need to touch `backit.xcodeproj/project.pbxproj` for new source files.

**iCloud rclone backend is new (merged Oct 2024) and has known size-mismatch issue.**
GitHub issue #8404. No fix on the rclone side; `--ignore-size` is the documented workaround.

## Post-Mortem

### What Worked
- `--ignore-size` flag: immediately resolved all `.partial`/`.heic`/`.pages` transfer errors; transfers ran cleanly
- Mirroring `DropboxJob` exactly for `ICloudJob` — minimal diff, just add `--ignore-size` everywhere and drop `--metadata`
- `RcloneStatusView` title/systemImage parameterisation — clean extensibility without touching existing Dropbox call sites much
- TDD: wrote `ICloudJobTests` before `ICloudJob.swift`; exhaustive switch errors from adding `case icloud` caught the `BackupCoordinator` gaps immediately

### What Failed
- Initial hypothesis that `.partial` files were locally-available files not yet uploaded: **wrong**. The files aren't local-only; the issue is the iCloud web API's on-the-fly compression of bundle types.

### Key Decisions
- **`--ignore-size` on all rclone commands for iCloud (not just sync)**: verification (`rclone check`) and retry passes also need it, otherwise they re-flag the same bundle files as mismatches.
- **Separate `icloudProgress`/`icloudStats` in coordinator (not shared with Dropbox)**: user wants each backup target to show independently in the UI.
- **Enable condition = non-empty `icloudRemoteName`** (no explicit toggle): consistent with how `dropboxRemoteName` works.
- **Option A (new `ICloudJob.swift`) over refactoring `DropboxJob` into a generic `RcloneJob`**: YAGNI — only two rclone targets, no third on the horizon. Refactor when/if a third appears.

## Artifacts

- `backit/Jobs/ICloudJob.swift` — full implementation
- `backitTests/ICloudJobTests.swift` — 3 async unit tests
- `backit/Database/Models.swift` — `JobType.icloud` added
- `backit/Settings/BackupSettings.swift` — iCloud settings fields
- `backit/Coordination/BackupCoordinator.swift` — full iCloud integration
- `backit/UI/BackitMainView.swift` — iCloud UI section + parameterised `RcloneStatusView`

## Action Items & Next Steps

1. **Dropbox custom icon** — user is creating a PDF or 64×64px PNG template image. When ready:
   - Add to `Assets.xcassets` as a new Image Set, "Render As: Template Image"
   - In `BackitMainView`, change the Dropbox `RcloneStatusView` call to use a custom `Label` initializer:
     ```swift
     // Replace systemImage: "arrow.triangle.2.circlepath" with:
     Label { Text(title) } icon: { Image("DropboxIcon") }
     ```
     This requires either passing the label as a closure or adding a separate `customImage: String?` parameter to `RcloneStatusView`.
2. **`performVerification` (Verify-only mode) only runs Dropbox** — `BackupCoordinator.performVerification()` hardcodes a `DropboxJob`. If verify-only for iCloud is needed, extend it. Low priority.
3. **rclone cookie expiry UX** — when the iCloud cookie expires, rclone will fail silently or with auth errors. Consider surfacing a clear error message in the UI. Currently no special handling.
4. **Test on the Sequoia machine** — deployment target was lowered to Sequoia this session; confirm the app launches and the iCloud backup section appears correctly on that machine.
5. **Commit current changes** — `backit.xcodeproj/project.pbxproj` has uncommitted modifications plus all the new/changed Swift files from this session.

## Other Notes

- All tests pass (39 total after adding 3 new iCloud tests): `** TEST SUCCEEDED **`
- `xcodebuild build` is authoritative for this project — SourceKit false positives are endemic; ignore them
- `DropboxJob.logFilePath = "/tmp/backit-rclone.log"`, `ICloudJob.logFilePath = "/tmp/backit-icloud-rclone.log"` — separate log files
- The `RcloneSummarySheet` "Open Full Log" button still hardcodes `DropboxJob.logFilePath`; would need updating if an iCloud summary sheet is added
- rclone iCloud backend docs: https://rclone.org/iclouddrive/ (sparse; most useful info is in GitHub issues)
- rclone issue #8404 (bundle size mismatch): https://github.com/rclone/rclone/issues/8404
