# Releasing backit

## Prerequisites

The release workflow (`release.yml`) runs on every `v*` tag. It builds a
signed, notarized `.app`, zips it, and attaches it to a GitHub Release
automatically. Before the first release you need to add six secrets to the
repository (Settings → Secrets and variables → Actions → New repository secret).

### 1. Export your Developer ID certificate

1. Open **Keychain Access** on a Mac that already has the certificate.
2. Under **My Certificates**, find **Developer ID Application: \<your name\>**.
3. Right-click → **Export** → save as `cert.p12`, set a strong password.
4. Base64-encode it:
   ```
   base64 -i cert.p12 | pbcopy
   ```
5. Add two secrets:
   - `SIGNING_CERTIFICATE_P12` — the base64 string
   - `SIGNING_CERTIFICATE_PASSWORD` — the password you chose

### 2. App Store Connect API key (for notarization)

1. Go to [App Store Connect → Users & Access → Integrations → Keys](https://appstoreconnect.apple.com/access/integrations/api).
2. Create a key with the **Developer** role (sufficient for notarization).
3. Download the `.p8` file — **you can only download it once**.
4. Note the **Key ID** and **Issuer ID** shown on that page.
5. Base64-encode the key:
   ```
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
6. Add three secrets:
   - `NOTARYTOOL_API_KEY` — the base64-encoded `.p8`
   - `NOTARYTOOL_KEY_ID` — the Key ID (e.g. `XXXXXXXXXX`)
   - `NOTARYTOOL_ISSUER_ID` — the Issuer ID UUID

### 3. Team ID

Add one more secret:
- `APPLE_TEAM_ID` — your ten-character Apple Developer team ID (visible in the top-right of the [Membership details](https://developer.apple.com/account) page)

---

## Cutting a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:
1. Import the signing certificate into a temporary keychain
2. `xcodebuild archive` + `xcodebuild -exportArchive` (Developer ID, Release config)
3. Notarize via `notarytool submit --wait`
4. Staple the notarization ticket
5. Zip the `.app` with `ditto` (preserves macOS metadata)
6. Create a GitHub Release named `backit v1.0.0` with auto-generated notes and attach `backit-v1.0.0.zip`

The temporary keychain and API key file are deleted at the end regardless of success or failure.

---

## Verifying a local build before tagging

```bash
xcodebuild archive \
  -project backit.xcodeproj \
  -scheme backit \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/backit.xcarchive

xcodebuild -exportArchive \
  -archivePath /tmp/backit.xcarchive \
  -exportPath /tmp/backit-export \
  -exportOptionsPlist scripts/ExportOptions.plist

codesign -dv --verbose=4 /tmp/backit-export/backit.app
spctl -a -t exec -vv /tmp/backit-export/backit.app
```
