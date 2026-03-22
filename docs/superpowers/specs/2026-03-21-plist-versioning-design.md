# Design: LaunchAgent Plist Versioning

**Date:** 2026-03-21
**Status:** Approved

---

## Problem

`LaunchAgentManager.install()` writes a plist to `~/Library/LaunchAgents/backit.plist`. `AppDelegate` only calls `install()` when `!launchAgent.isInstalled` (i.e., the file is absent). Users who had a plist installed before the `StartCalendarInterval` feature shipped will keep the old plist until they manually change their backup time in Settings. There is no mechanism to detect or replace a stale plist.

---

## Design

### Version constant

```swift
static let currentPlistVersion = 2
```

Added to `LaunchAgentManager`. Version semantics:

| Version | Meaning |
|---------|---------|
| absent (nil) | Pre-versioning plist — missing `StartCalendarInterval` |
| 2 | First explicitly versioned plist — includes `StartCalendarInterval` |

Version 1 is intentionally skipped; the absence of the key is the implicit signal for any plist written before this feature.

---

### Plist key

`"BackitPlistVersion"` is added to the dictionary written by `install()`:

```swift
"BackitPlistVersion": Self.currentPlistVersion
```

The key is prefixed with `Backit` to avoid collision with launchd's reserved key namespace.

---

### `installedVersion` private helper

```swift
private var installedVersion: Int? {
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any] else { return nil }
    return plist["BackitPlistVersion"] as? Int
}
```

Returns `nil` if the file is missing or the key is absent (covering all pre-versioning plists).

---

### `needsInstall` computed property

```swift
var needsInstall: Bool {
    !isInstalled || installedVersion != Self.currentPlistVersion
}
```

Returns `true` when:
- The plist file does not exist, OR
- The plist exists but has no `BackitPlistVersion` key (old install), OR
- The plist exists but its version doesn't match `currentPlistVersion` (upgrade or downgrade)

---

### `install()` change

One new entry added to the plist dictionary:

```swift
"BackitPlistVersion": Self.currentPlistVersion
```

No other changes to `install()`.

---

### AppDelegate change

Line 46 changes from:

```swift
if !launchAgent.isInstalled { try? launchAgent.install(backupTime: settings.backupTime) }
```

to:

```swift
if launchAgent.needsInstall { try? launchAgent.install(backupTime: settings.backupTime) }
```

The Combine observer that reinstalls on backup time change remains unconditional — it already handles the "update existing plist" case correctly.

---

## Files Changed

| File | Change |
|------|--------|
| `backit/LaunchAgent/LaunchAgentManager.swift` | Add `currentPlistVersion`, `installedVersion`, `needsInstall`; add `BackitPlistVersion` to plist dict |
| `backit/AppDelegate.swift` | Change `!launchAgent.isInstalled` to `launchAgent.needsInstall` |
| `backitTests/LaunchAgentManagerTests.swift` | Add 3 tests for `needsInstall` |

---

## What Is NOT Changed

- `isInstalled` — unchanged, still used by `uninstall()`'s guard
- `install()` signature — unchanged
- `uninstall()` — unchanged
- Database schema — unchanged
- `ScheduleManager` — unchanged

---

## Testing

Three new tests in `LaunchAgentManagerTests`:

```swift
func testNeedsInstallWhenNotInstalled() throws {
    XCTAssertTrue(sut.needsInstall)
}

func testNeedsInstallWhenVersionMismatch() throws {
    // Write a plist without BackitPlistVersion (simulates old install)
    let oldPlist: [String: Any] = ["Label": "com.backit.test"]
    let data = try PropertyListSerialization.data(fromPropertyList: oldPlist,
                                                  format: .xml, options: 0)
    try data.write(to: plistURL)
    XCTAssertTrue(sut.needsInstall)
}

func testNeedsInstallFalseWhenCurrentVersion() throws {
    try sut.install()
    XCTAssertFalse(sut.needsInstall)
}
```

Existing tests are unaffected — they call `install()` with no args and check other keys.
