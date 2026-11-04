# Research Report: icloudpd (iCloud Photos Downloader)
Generated: 2026-03-18

## Executive Summary

icloudpd is a mature, actively maintained CLI tool (11.7k GitHub stars, v1.32.2 as of Sept 2025) for downloading iCloud Photos. It is available in Homebrew core (`brew install icloudpd`), supports incremental sync, dry-run mode, and all media types. Authentication uses Apple ID credentials + 2FA with a session cookie that expires approximately every two months. It requires "Access iCloud Data on the Web" enabled and Advanced Data Protection disabled on the iCloud account.

## Research Question

Full evaluation of icloudpd for integration into a macOS backup app as a new job type, covering installation, authentication, capabilities, CLI usage, and limitations.

## Key Findings

### Finding 1: Repository and Project Status

- **GitHub URL:** https://github.com/icloud-photos-downloader/icloud_photos_downloader
- **Stars:** 11.7k
- **Current version:** 1.32.2 (released September 2, 2025)
- **Release cadence:** Weekly (Fridays), if there is something to deliver
- **Status:** Actively maintained by volunteers
- **License:** MIT
- Source: [GitHub repo](https://github.com/icloud-photos-downloader/icloud_photos_downloader)

### Finding 2: Installation Methods

**Homebrew (core formula -- no tap needed):**
```bash
brew install icloudpd
```
- Runtime deps: `python@3.14`, `certifi`
- Build dep: `gnu-sed`
- Available on macOS (ARM + Intel) and Linux

**Other methods:**
- `pip install icloudpd` / `pipx install icloudpd` (PyPI package)
- Docker: official and community images
- npm: `npx icloudpd`
- AUR (Arch Linux)
- Direct binary download from GitHub Releases

- Source: [Homebrew formula](https://formulae.brew.sh/formula/icloudpd), [PyPI](https://pypi.org/project/icloudpd/)

### Finding 3: Authentication

**Mechanism:** Web-based iCloud session simulation (same as logging into icloud.com).

**Flow:**
1. Provide Apple ID via `--username`
2. Provide password via one of four providers (checked in order):
   - `--password` flag (not recommended for scripts)
   - System keyring (managed via `icloud` CLI, not `icloudpd`)
   - Console prompt
   - Web UI prompt
3. 2FA code requested on first run / when session expires
   - MFA code delivery: console (default) or web UI (`--mfa-provider`)
4. Session cookie stored in `--cookie-directory` (default: `~/.pyicloud`)

**Cookie/session lifetime:** Approximately **two months** (set by Apple, not configurable). Some reports say 30 days to 3 months depending on Apple's server-side policies.

**Email notifications:** Can be configured to alert when cookie is within N days of expiry via SMTP flags.

**Auth-only mode:** `icloudpd --username X --password Y --auth-only` -- authenticates, stores cookie, exits. Useful for scripted re-auth.

**NOT supported:**
- FIDO/hardware security keys
- Advanced Data Protection (ADP) -- must be disabled
- Account must have "Access iCloud Data on the Web" enabled

**Comparison to rclone iCloud backend:** Similar in that both simulate web access. rclone's iCloud backend also requires cookies/2FA. icloudpd is purpose-built for Photos specifically and handles the Photos API directly.

- Source: [Authentication docs](https://icloud-photos-downloader.github.io/icloud_photos_downloader/authentication.html)

### Finding 4: What It Downloads

- **Photos:** All standard formats (JPEG, HEIC, PNG, etc.)
- **Videos:** Yes (can skip with `--skip-videos`)
- **Live Photos:** Yes, as separate image + video files (can skip with `--skip-live-photos`)
- **RAW images:** Yes, including RAW+JPEG pairs (`--align-raw` controls treatment)
- **Size options:** `--size` flag to choose asset size; `--force-size` to only download requested size (otherwise falls back to original)
- **EXIF:** `--set-exif-datetime` updates EXIF with iCloud creation date
- **XMP sidecars:** `--xmp-sidecar` exports additional metadata

- Source: [GitHub README](https://github.com/icloud-photos-downloader/icloud_photos_downloader), [Reference docs](https://icloud-photos-downloader.github.io/icloud_photos_downloader/reference.html)

### Finding 5: Basic CLI Invocation

**One-time sync:**
```bash
icloudpd --directory /path/to/photos --username user@icloud.com
```

**Continuous monitoring (daemon-like):**
```bash
icloudpd --directory /path/to/photos \
  --username user@icloud.com \
  --watch-with-interval 3600
```

**Incremental sync (stop after finding N existing):**
```bash
icloudpd --directory /path/to/photos \
  --username user@icloud.com \
  --until-found 10
```

**Dry run:**
```bash
icloudpd --directory /path/to/photos \
  --username user@icloud.com \
  --dry-run
```

**Download specific album:**
```bash
icloudpd --directory /path/to/photos \
  --username user@icloud.com \
  --album "My Favorites"
```

**List available albums:**
```bash
icloudpd --username user@icloud.com --list-albums
```

**Auth-only (for scripted pre-auth):**
```bash
icloudpd --username user@icloud.com --auth-only
```

### Finding 6: Incremental Sync

Yes, icloudpd supports incremental sync through multiple mechanisms:

- **`--until-found N`**: Scans from newest to oldest; stops after N consecutive matches with local files. Best for regular incremental runs. Caveat: will not "fill gaps" if files were deleted locally.
- **`--recent N`**: Only checks the N most recently added assets. Good for testing or quick checks.
- **`--auto-delete`**: Deletes local files that were removed from iCloud (true two-way sync behavior for deletions).
- **`--watch-with-interval N`**: Runs forever, re-checking every N seconds. Suitable for daemon/background use.

Without these flags, a full scan of all iCloud assets is performed each run (comparing against local files, only downloading missing ones).

### Finding 7: Dry-Run Mode

**Yes.** `--dry-run` flag: "No changes to local or remote storage are made. Authentication and remote/local checks occur; differences are reported."

Also available: `--only-print-filenames` which prints file paths without downloading.

### Finding 8: Folder Structure

Controlled by `--folder-structure` flag using Python datetime formatting:

- **Default:** `{:%Y/%m/%d}` -- creates `2026/03/18/` hierarchy
- **Year/month only:** `{:%Y/%m}`
- **Flat:** `none` -- all files in root directory
- **Custom:** Any Python strftime codes, e.g. `{:%Y/%B}` for `2026/March/`
- **Locale:** `--use-os-locale` affects locale-dependent format codes like `%B`

**Known issue:** Shared Library downloads may not honor folder-structure settings.

### Finding 9: Limitations and Gotchas

1. **iCloud account requirements:**
   - Must enable "Access iCloud Data on the Web" (iOS Settings > Apple ID > iCloud)
   - Must disable Advanced Data Protection (ADP)
   - Without these: ACCESS_DENIED errors

2. **2FA re-authentication:** Required approximately every 2 months. No way around this -- Apple enforces it server-side. For automated/unattended setups, this is the biggest friction point.

3. **FIDO keys:** Not supported for authentication.

4. **Rate limiting:** Short `--watch-with-interval` values may trigger Apple throttling, though no confirmed reports. Recommended: 3600+ seconds.

5. **Unicode filenames:** Unicode characters stripped by default; use `--keep-unicode-in-filenames` to preserve.

6. **Live Photos:** Downloaded as two separate files (image + MOV), not as a combined asset.

7. **Shared Libraries:** Folder structure may not be honored; files may land in a single directory.

8. **China mainland:** `--domain cn` for China iCloud, but support is inconsistent.

9. **`--until-found` gaps:** Does not backfill gaps in local storage. If you manually deleted some local files, they won't be re-downloaded unless you do a full scan.

10. **Troubleshooting auth:** Sometimes requires clearing `~/.pyicloud` directory to resolve authentication errors.

## Integration Recommendations for backit

### Architecture Approach

Model `ICloudPhotosJob` similar to the existing rclone-based jobs:

1. **Binary check:** Verify `icloudpd` is installed (check `which icloudpd` or Homebrew)
2. **Pre-auth phase:** Use `--auth-only` to validate credentials before starting a backup run
3. **Sync invocation:** Run with `--until-found 10 --dry-run` first for status, then without `--dry-run` for actual sync
4. **Cookie management:** Store cookies in app-specific directory (e.g., `~/Library/Application Support/backit/icloudpd-cookies/`)
5. **Re-auth handling:** Monitor cookie age; prompt user when approaching 2-month expiry. Use SMTP notification flags or check cookie file timestamps.

### Key Differences from rclone Jobs

| Aspect | rclone (Dropbox/iCloud Drive) | icloudpd (iCloud Photos) |
|--------|-------------------------------|--------------------------|
| Auth | OAuth token, auto-refresh | 2FA cookie, manual re-auth every ~2 months |
| Scope | Files/folders | Photos/videos only |
| Sync direction | Bidirectional possible | Download only (with optional iCloud deletion) |
| Daemon mode | No built-in | `--watch-with-interval` |
| Rate limits | Provider-specific | Apple may throttle short intervals |

### Suggested Settings for BackupSettings

- `icloudPhotosUsername`: Apple ID email
- `icloudPhotosDirectory`: Local download path
- `icloudPhotosEnabled`: Boolean toggle
- `icloudPhotosFolderStructure`: Default `{:%Y/%m/%d}`
- `icloudPhotosSkipVideos`: Boolean (default false)
- `icloudPhotosUntilFound`: Int (default 10 for incremental)

### Re-authentication UX

The 2-month cookie expiry is the main UX challenge. Options:
1. Show a notification/alert in backit UI when cookie is near expiry
2. Provide a "Re-authenticate iCloud Photos" button that runs `--auth-only` in a terminal window
3. Check cookie directory modification timestamps before each backup run

## Sources

- [GitHub: icloud-photos-downloader/icloud_photos_downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader)
- [Official Documentation (v1.32.2)](https://icloud-photos-downloader.github.io/icloud_photos_downloader/)
- [Authentication Documentation](https://icloud-photos-downloader.github.io/icloud_photos_downloader/authentication.html)
- [CLI Reference](https://icloud-photos-downloader.github.io/icloud_photos_downloader/reference.html)
- [Homebrew Formula](https://formulae.brew.sh/formula/icloudpd)
- [PyPI Package](https://pypi.org/project/icloudpd/)
- [File Naming Documentation](https://icloud-photos-downloader.github.io/icloud_photos_downloader/naming.html)
- [Docker wrapper (boredazfcuk)](https://github.com/boredazfcuk/docker-icloudpd)

## Open Questions

1. **Exact cookie lifetime:** Reports vary between 30 days and 3 months. The official docs say "currently two months" but Apple may change this. Need to validate empirically.
2. **Keyring integration on macOS:** The `icloud` CLI stores passwords in macOS Keychain. Can backit leverage this directly, or does it need its own credential management?
3. **Concurrent access:** Can icloudpd run while the user is actively using iCloud Photos in the Photos app? (Likely yes, since it's read-only web access, but unconfirmed.)
4. **Large libraries:** Performance characteristics for libraries with 100k+ photos. The `--until-found` optimization helps, but initial full sync time is unknown.
5. **Exit codes:** Need to verify icloudpd's exit code behavior for scripting (success=0, auth failure=specific code, etc.) -- not documented in the reference.
