---
date: 2026-03-19T00:51:50Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 784b69047d7251f32e71be5722d81f7011093193
branch: main
repository: backit
topic: "iCloud Drive job, rclone setup guidance, docs, future backup targets research"
tags: [swift, icloud, rclone, ui, docs, research]
status: complete
last_updated: 2026-03-18
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: iCloud job shipped; rclone setup guidance + docs; future targets researched

## Task(s)

| Task | Status |
|------|--------|
| Resume from previous handoff (iCloud job complete, uncommitted) | ✅ Done |
| Wire Dropbox icon asset into UI (action item from prior session) | ⏳ Deferred — asset staged but UI not updated (user did not request this session) |
| Add rclone remote setup guidance to main window pickers | ✅ Done |
| Update user manual + HelpContent.swift for iCloud Drive | ✅ Done |
| Add "Backing up Photos" section to docs | ✅ Done |
| Research icloudpd for Photos backup | ✅ Done — decided against |
| Research Got Your Back (GYB) for Gmail backup | ✅ Done — decided against (too finicky) |
| Create handoff | ✅ Done |

## Critical References

- `backit/Jobs/ICloudJob.swift` — iCloud Drive rclone job (new this cycle)
- `backit/UI/BackitMainView.swift` — main UI; rclone pickers now have 3-state logic
- `docs/user-manual.md` + `backit/UI/HelpContent.swift` — kept in sync manually (no generation step)

## Recent Changes

- `backit/Jobs/ICloudJob.swift` — new file; full rclone job with `--ignore-size` on all operations
- `backitTests/ICloudJobTests.swift` — new file; 3 async tests
- `backit/Database/Models.swift:8` — `case icloud` added to `JobType`
- `backit/Settings/BackupSettings.swift:14-15,31-32` — `icloudRemoteName` + `icloudVolumePath` fields
- `backit/Coordination/BackupCoordinator.swift:11,17,38-44,120,137,149-170,214,217` — iCloud integration throughout
- `backit/UI/BackitMainView.swift` — iCloud section, 3-state remote pickers, `openTerminal()` helper
- `backit/UI/HelpView.swift` — **deleted** (unused stub)
- `backit/Assets.xcassets/dropbox-icon.imageset/` — Dropbox icon asset added (PDF)
- `docs/user-manual.md` — iCloud Drive section, rclone setup, Photos/GYB notes
- `backit/UI/HelpContent.swift` — same content as user-manual updates, in HTML

## Learnings

**3-state rclone remote pickers:** `rcloneRemotes.isEmpty` can mean either rclone not installed OR installed but no remotes. Distinguish with a separate `rcloneInstalled` state var (set via `DropboxJob.isInstalled()` in `loadRemoteData()`). Three states: not installed → "Install rclone…" button; installed/no remotes → "Set up rclone remote…" button; has remotes → Menu picker + "Add remote…". Both buttons use `openTerminal(command:)` which runs NSAppleScript → Terminal.app (works without entitlements since app is not sandboxed).

**HelpContent.swift is hand-authored HTML** — there is no generation step from `docs/user-manual.md`. Changes to the manual must be manually mirrored into `HelpContent.swift`. Easy to forget.

**icloudpd (iCloud Photos Downloader):** Available via `brew install icloudpd`. Uses cookie-based auth that expires every ~2 months, requiring interactive 2FA re-auth. Decided against for backit — too much friction.

**Got Your Back (GYB) for Gmail:** Requires creating a Google Cloud project. User found setup too finicky. Decided against.

**Photos backup decision:** Best low-friction approach is enabling Dropbox Camera Uploads periodically — raw images land in Dropbox, which backit already backs up. No new job type needed. Full Photos library backup (with metadata) requires a secondary iCloud Photos library on external drive — manual, not automatable.

**`--ignore-size` is mandatory for all rclone iCloud operations** — not just sync. Check, cleanup retry, and `--files-from` copy all need it, otherwise iWork/.heic bundle size mismatches re-appear.

## Post-Mortem

### What Worked
- 3-state picker logic with `@ViewBuilder` on computed properties — clean, no duplication
- NSAppleScript → Terminal for `rclone config` / `brew install rclone` — zero entitlements friction
- Mirroring `DropboxJob` exactly for `ICloudJob` (just add `--ignore-size`, drop `--metadata`)
- `RcloneStatusView` title/systemImage parameterisation — Dropbox and iCloud render independently

### What Failed
- GYB setup — user hit errors during `create-project` step; too finicky overall
- icloudpd — 2-month cookie re-auth cycle is a non-starter for an automated backup tool

### Key Decisions
- **No in-app rclone remote setup:** backit detects unconfigured remotes and opens Terminal with `rclone config` rather than reimplementing rclone's auth flows. YAGNI — each backend (Dropbox OAuth, iCloud cookie) is too different to unify.
- **Option A for iCloud job (new `ICloudJob.swift` vs. generic `RcloneJob`):** Only two rclone targets; refactor if/when a third appears.
- **Photos backup via Dropbox Camera Uploads (periodic):** No new job type; documents the approach in the manual instead.

## Artifacts

- `backit/Jobs/ICloudJob.swift`
- `backitTests/ICloudJobTests.swift`
- `backit/UI/BackitMainView.swift`
- `backit/UI/HelpContent.swift`
- `docs/user-manual.md`
- `thoughts/shared/handoffs/general/2026-03-18_16-40-06_icloud-rclone-job-ui.md` — prior session handoff

## Action Items & Next Steps

1. **Dropbox icon wiring** — `backit/Assets.xcassets/dropbox-icon.imageset/dropbox-icon.pdf` is committed but the Dropbox `RcloneStatusView` call in `BackitMainView.swift:31` still uses the default `systemImage: "arrow.triangle.2.circlepath"`. When ready, add `customImage: String? = nil` parameter to `RcloneStatusView` and pass `"dropbox-icon"` for the Dropbox section. Note: `Contents.json` is missing `"template-rendering-intent": "template"` — add that too for tint color support.
2. **Soak test** — user is running the app for a few days to verify iCloud backup and rclone setup guidance UX before further work.
3. **Future backup targets** — Gmail (GYB rejected), Photos (Dropbox Camera Uploads recommended), others (Contacts, Calendar, Notes, 1Password, Authenticator.app) still open. See memory file `project_future_backup_targets.md`.

## Other Notes

- All 39 tests pass as of last build
- `xcodebuild build` is authoritative — SourceKit false positives are endemic in this project, ignore them
- Log files: Dropbox → `/tmp/backit-rclone.log`, iCloud → `/tmp/backit-icloud-rclone.log`
- `performVerification()` in `BackupCoordinator` still hardcodes `DropboxJob` only — iCloud verify-only not wired (low priority)
- `RcloneSummarySheet` "Open Full Log" button still hardcodes `DropboxJob.logFilePath` — would need updating if an iCloud summary sheet is added
