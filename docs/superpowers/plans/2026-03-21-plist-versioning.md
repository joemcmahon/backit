# Plist Versioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LaunchAgentManager` detect and replace stale plists so that users who installed before `StartCalendarInterval` was added get an updated plist automatically on next launch.

**Architecture:** One self-contained task. Add a `currentPlistVersion` constant, a private `installedVersion` reader, and a public `needsInstall` property to `LaunchAgentManager`. Add `"BackitPlistVersion"` to the plist written by `install()`. Change the one `AppDelegate` call site from `!isInstalled` to `needsInstall`.

**Tech Stack:** Swift, Foundation (PropertyListSerialization, Data), XCTest

**Spec:** `docs/superpowers/specs/2026-03-21-plist-versioning-design.md`

---

## File Map

| File | Change |
|------|--------|
| `backit/LaunchAgent/LaunchAgentManager.swift` | Add `currentPlistVersion`, `installedVersion`, `needsInstall`; add `BackitPlistVersion` key to plist dict in `install()` |
| `backit/AppDelegate.swift` | Change `!launchAgent.isInstalled` → `launchAgent.needsInstall` on one line |
| `backitTests/LaunchAgentManagerTests.swift` | Add 3 tests for `needsInstall` |

---

## Task 1: Plist versioning

**Files:**
- Modify: `backit/LaunchAgent/LaunchAgentManager.swift`
- Modify: `backit/AppDelegate.swift`
- Test: `backitTests/LaunchAgentManagerTests.swift`

### Step 1: Write failing tests

- [ ] Add these three tests to `LaunchAgentManagerTests.swift`, inside `final class LaunchAgentManagerTests`:

```swift
func testNeedsInstallWhenNotInstalled() throws {
    // No plist file exists yet — setUp starts with an empty temp directory
    XCTAssertTrue(sut.needsInstall)
}

func testNeedsInstallWhenVersionMismatch() throws {
    // Simulate a pre-versioning plist (no BackitPlistVersion key)
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

Note: `testNeedsInstallFalseWhenCurrentVersion` will PASS before implementation (because `needsInstall` doesn't exist yet, so this won't compile). Run the test build first to confirm the compile error, which is the "red" phase here.

### Step 2: Run to confirm compile failure (red)

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests \
  2>&1 | grep -E '(error:|FAILED|PASSED)'
```

Expected: `error: value of type 'LaunchAgentManager' has no member 'needsInstall'`

### Step 3: Add versioning to `LaunchAgentManager`

- [ ] In `LaunchAgentManager.swift`, add the version constant immediately after the opening brace of the class:

```swift
final class LaunchAgentManager {
    static let currentPlistVersion = 2
    // ... existing code
```

- [ ] Add `installedVersion` and `needsInstall` after the existing `isInstalled` property:

```swift
var isInstalled: Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
}

private var installedVersion: Int? {
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any] else { return nil }
    return plist["BackitPlistVersion"] as? Int
}

var needsInstall: Bool {
    !isInstalled || installedVersion != Self.currentPlistVersion
}
```

- [ ] In `install()`, add `"BackitPlistVersion": Self.currentPlistVersion` to the plist dictionary:

```swift
let plist: [String: Any] = [
    "Label": label,
    "ProgramArguments": [execPath],
    "RunAtLoad": true,
    "KeepAlive": false,
    "ProcessType": "Background",
    "StartCalendarInterval": [
        "Hour": comps.hour ?? 23,
        "Minute": comps.minute ?? 0
    ],
    "BackitPlistVersion": Self.currentPlistVersion
]
```

### Step 4: Update AppDelegate

- [ ] In `AppDelegate.swift`, find this line (around line 46):

```swift
if !launchAgent.isInstalled { try? launchAgent.install(backupTime: settings.backupTime) }
```

Replace with:

```swift
if launchAgent.needsInstall { try? launchAgent.install(backupTime: settings.backupTime) }
```

That is the only change to `AppDelegate.swift`.

### Step 5: Run LaunchAgentManager tests (green)

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:backitTests/LaunchAgentManagerTests \
  2>&1 | grep -E '(Test case|FAILED|PASSED|error:)'
```

Expected: all 7 LaunchAgentManagerTests PASSED (4 existing + 3 new).

### Step 6: Run full test suite

- [ ] Run:

```bash
xcodebuild test -project backit.xcodeproj -scheme backit \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'
```

Expected: all suites PASSED, no regressions.

### Step 7: Commit

- [ ] Run:

```bash
git add backit/LaunchAgent/LaunchAgentManager.swift \
        backit/AppDelegate.swift \
        backitTests/LaunchAgentManagerTests.swift
git commit -m "Add plist versioning: replace stale plists on launch"
```

---

## Verification

After the commit, smoke-test manually:

1. Delete `~/Library/LaunchAgents/backit.plist` (or open it in a text editor and confirm it does NOT yet have `BackitPlistVersion`).
2. Launch backit — check that `~/Library/LaunchAgents/backit.plist` now contains `BackitPlistVersion` = 2 and `StartCalendarInterval`.
3. Relaunch backit — confirm the plist is NOT rewritten (version already matches, `needsInstall` returns false).

```bash
# Check plist after first launch:
/usr/libexec/PlistBuddy -c "Print :BackitPlistVersion" ~/Library/LaunchAgents/backit.plist
# Expected output: 2

/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval" ~/Library/LaunchAgents/backit.plist
# Expected output: Dict { Hour = <N>; Minute = <N>; }
```
