# Contributing to backit

backit is a personal macOS backup tool, shared as-is under the [MIT license](LICENSE) and maintained in spare time by one person. Issues and PRs are welcome, but there's no SLA on review or response time.

This is fundamentally a single-user tool built around one specific workflow (Carbon Copy Cloner + Dropbox via rclone). Feature requests that fit that shape are more likely to land than ones that significantly expand scope — please open an issue before starting a large PR so we can agree on the approach first.

## Development setup

Requirements:
- macOS 26.2 or later
- Xcode (matching the deployment target)
- Carbon Copy Cloner and rclone installed, if you want to exercise real backups — unit tests mock both

```bash
# Run tests
xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64'

# Build
xcodebuild build -project backit.xcodeproj -scheme backit
```

## Before opening a PR

- Run the full test suite and make sure it passes.
- If you touch `backit/UI/HelpContent.swift`, also update `docs/user-manual.md` to match — they're hand-authored in parallel, not generated from each other, and drift easily.
- If you touch `site/index.html`, keep it consistent with the README and user manual — the "why backit" and one-way-backup warning text is duplicated across all three on purpose.
- SourceKit sometimes reports false "cannot find type in scope" errors in Xcode's editor for types defined elsewhere in the module. `xcodebuild test` is authoritative — if it passes, ignore SourceKit-only errors.
- Quit and relaunch the app after every rebuild during manual testing: timers are created at launch and don't survive a binary swap.

## Reporting bugs

Please include:
- macOS version
- CCC and rclone versions (`rclone version`)
- Relevant log output — Dropbox syncs log to `/tmp/backit-rclone.log`
- Whether the issue occurred in the interactive app or the headless, launchd-triggered run

## License

By contributing, you agree your contributions will be licensed under the project's MIT license.
