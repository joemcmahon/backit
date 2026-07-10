---
date: 2026-07-09
session_name: general
researcher: Claude Sonnet 4-6
git_commit: 29b0755
branch: main
repository: backit
topic: "Signed Developer ID release workflow — notarization debugging in progress"
tags: [release, codesign, notarization, github-actions, history-squash]
status: in_progress
last_updated: 2026-07-09
last_updated_by: Claude Sonnet 4-6
type: implementation_strategy
---

# Handoff: Signed release workflow — paused for reboot

## What was accomplished this session

1. **Real app screenshot on project site** — completed and pushed. CSS mockup replaced with
   a real screenshot captured via a temporary `--screenshot-preview` code path (isolated
   UserDefaults/in-memory DB, reverted before commit). Live at
   https://joemcmahon.github.io/backit/

2. **GitHub Pages workflow fixed** — bumped all actions to Node 24-compatible versions
   (checkout@v7, configure-pages@v6, upload-pages-artifact@v5, deploy-pages@v5), added
   `enablement: true`.

3. **Signed Developer ID release workflow added** — `.github/workflows/release.yml` triggers
   on `v*` tags. Builds, signs, notarizes, staples, zips, and publishes to GitHub Releases.
   See `docs/releasing.md` for secrets setup.

4. **History squashed** — 90 commits → 15 clean feature-level commits. Force-pushed to main.
   `v0.0.1` tag re-pointed to new HEAD (`29b0755`).

## Current blocker: notarization not yet confirmed working

The release workflow has been iteratively fixed through several failures. Current state of
the workflow (`.github/workflows/release.yml`):

- Certificate import: ✅ working (temp keychain, correct password)
- Archive: ✅ working (switched to `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`, `--keychain` flag)
- Export: ✅ working (ExportOptions.plist generated at runtime from secrets, `signingStyle=manual`)
- Notarize: fixed (was submitting raw `.app`; now zips first with `ditto`, submits zip)
- Staple + final zip: not yet confirmed

**The session ended (reboot) before re-tagging to test the notarization fix.**

## Secrets status

All 6 secrets are configured in GitHub repo settings:
- `SIGNING_CERTIFICATE_P12` ✅
- `SIGNING_CERTIFICATE_PASSWORD` ✅
- `NOTARYTOOL_KEY_ID` ✅
- `NOTARYTOOL_ISSUER_ID` ✅
- `NOTARYTOOL_API_KEY` ✅
- `APPLE_TEAM_ID` ✅ (had a leading-space bug, was fixed — no longer used in build commands anyway)

## Next step after reboot

Re-tag to trigger the release workflow:

```bash
git push origin :v0.0.1
git tag -d v0.0.1
git tag v0.0.1
git push origin v0.0.1
```

Watch at https://github.com/joemcmahon/backit/actions — if the Notarize step fails again,
read the full error carefully. Common next failure modes:

- **"Invalid credentials"** → NOTARYTOOL_KEY_ID, NOTARYTOOL_ISSUER_ID, or NOTARYTOOL_API_KEY
  secret is wrong/malformed. Re-check base64 encoding of the .p8.
- **"The software asset has already been uploaded"** → harmless, notarytool deduplicates;
  check if the submission status is "Accepted".
- **"No signing certificate found"** → cert import failed silently; check the Import step logs.
- **Stapler fails** → notarization didn't complete successfully; check notarytool output for
  the submission UUID and query status manually:
  ```bash
  xcrun notarytool log <UUID> --key AuthKey_XXX.p8 --key-id XXX --issuer YYY
  ```

## Workflow file summary

Key design decisions in `.github/workflows/release.yml`:
- Manual signing (not Automatic) — Automatic signing requires Apple portal connectivity
  unavailable on hosted runners
- ExportOptions.plist generated at runtime in `$RUNNER_TEMP` from `APPLE_TEAM_ID` secret —
  team ID never committed to repo
- Keychain path exported via `$GITHUB_ENV` so it's available to Archive and Export steps
- Keychain unlocked before each xcodebuild call (keychains can re-lock between steps)
- Notarize submits a zip (ditto), not raw .app — notarytool requires .zip/.pkg/.dmg
- Staple goes to the .app directly, then re-zip for the release artifact
- Cleanup runs `if: always()` — deletes temp keychain and .p8 file even on failure

## Repo state

- Branch: main
- HEAD: 29b0755
- Working tree: clean (only `default.profraw` untracked, ignore it)
- Remote: https://github.com/joemcmahon/backit (public, MIT)
- Live site: https://joemcmahon.github.io/backit/
- Tag v0.0.1 points to 29b0755 on both local and remote
</content>