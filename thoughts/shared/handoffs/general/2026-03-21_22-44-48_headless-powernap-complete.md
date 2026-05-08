---
date: 2026-03-22T05:44:48Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 9ea896a3a4949f681b475cd363f8c823e93b2ba4
branch: main
repository: backit
topic: "Headless PowerNap-Compatible Backup — Complete Implementation"
tags: [swift, headless, powernap, launchagent, headlessrunner, concurrency, unowned]
status: complete
last_updated: 2026-03-21
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Headless PowerNap implementation — fully complete, all tests passing

## Task(s)

| Task | Status |
|------|--------|
| Task 1: Bump plist to version 3 (`--headless`, `RunAtLoad: false`) | ✅ Complete — commit `05cf80c` |
| Task 2: Restructure AppDelegate (headless guard, early return) | ✅ Complete — commit `f77e881` |
| Task 3: Create `HeadlessRunner.swift` + `HeadlessRunnerTests.swift` | ✅ Complete — commit `9ea896a` |
| Full test suite (60+ tests) | ✅ All passing — `** TEST SUCCEEDED **` |

**Plan:** `docs/superpowers/plans/2026-03-21-headless-powernap.md`
**Spec:** `docs/superpowers/specs/2026-03-21-headless-powernap-design.md`

The entire headless PowerNap feature is implemented and committed. The only remaining step is a manual smoke test (user needs hardware in place first).

## Critical References

- `docs/superpowers/specs/2026-03-21-headless-powernap-design.md` — approved design spec
- `docs/superpowers/plans/2026-03-21-headless-powernap.md` — implementation plan (all 3 tasks done)
- `backit/Headless/HeadlessRunner.swift` — new class, key fix: `unowned coordinator`

## Recent Changes

All changes committed on `main`:

- `05cf80c` — `backit/LaunchAgent/LaunchAgentManager.swift`: bumped `currentPlistVersion` to 3, `ProgramArguments: [execPath, "--headless"]`, `RunAtLoad: false`. `backitTests/LaunchAgentManagerTests.swift`: added 2 new tests (`testPlistVersion3HasRunAtLoadFalse`, `testPlistVersion3HasHeadlessArgument`)
- `f77e881` — `backit/AppDelegate.swift:1-77`: restructured `applicationDidFinishLaunching` — core objects first, `--headless` guard with early return, `var headlessRunner: HeadlessRunner?` stored property, all UI/catch-up only in non-headless path
- `9ea896a` — `backit/Headless/HeadlessRunner.swift` (new), `backitTests/HeadlessRunnerTests.swift` (new): 7 tests, all passing

## Learnings

**Critical: `@MainActor` nested dealloc crash — use `unowned` for cross-actor references held by `@MainActor` classes**

When `HeadlessRunner` (`@MainActor`) held `coordinator: BackupCoordinator` (`@MainActor`) as a `strong let`, the deinit chain crashed:
- `HeadlessRunner.__isolated_deallocating_deinit` runs as a job on main actor
- Inside it, releasing `coordinator` drops its refcount to 0
- `coordinator.__isolated_deallocating_deinit` tries to enqueue ANOTHER job on main actor, but we're already inside a bare `Job` (not a `Task`)
- `TaskLocal::StopLookupScope::~StopLookupScope()` in `swift_task_deinitOnExecutorImpl` crashes: no active Task context

**Fix:** `private unowned let coordinator: BackupCoordinator` at `backit/Headless/HeadlessRunner.swift:15`. `unowned` means `HeadlessRunner` doesn't contribute to coordinator's refcount. Both objects dealloc independently. Safe because:
- In production: `AppDelegate` holds both `self.coordinator` and `self.headlessRunner` strongly
- In tests: test function holds `coordinator` as a local variable for the full test duration

**Crash signature (for future reference):**
```
HeadlessRunner.__isolated_deallocating_deinit
→ swift::runJobInEstablishedExecutorContext
→ BackupCoordinator.__deallocating_deinit
→ swift_task_deinitOnExecutorImpl
→ TaskLocal::StopLookupScope::~StopLookupScope()
→ SIGABRT (malloc: pointer being freed was not allocated)
```

**`HeadlessRunnerTests` must be `async` — but that alone is not sufficient** for tests that construct `@MainActor` objects. The `unowned` fix is also required.

**`PBXFileSystemSynchronizedRootGroup`:** This project uses Xcode's filesystem-sync group feature. Any file placed in `backit/` or `backitTests/` is automatically included — no manual `project.pbxproj` edits needed.

**`BackupCoordinator` factory injection for tests:** `BackupCoordinator(db: db, settings: settings) { _ in [mockJob] }` — trailing closure provides mock job list.

**SourceKit false positives:** SourceKit reports "cannot find type" errors for types in `HeadlessRunner.swift`. These are endemic to this project and always wrong. `xcodebuild build` is the only authoritative check.

## Post-Mortem

### What Worked
- **`unowned` coordinator reference**: Clean, semantically correct fix for nested `@MainActor` dealloc crash. No test restructuring needed beyond making methods `async`.
- **All tests async in HeadlessRunnerTests**: Required for `@MainActor` XCTest pattern — all 7 methods are `async`, preventing the primary crash documented in project memory.
- **`PBXFileSystemSynchronizedRootGroup` auto-inclusion**: Simply placing files on disk in the right directories was sufficient; no Xcode project file editing required.
- **`notificationPoster` injection**: Injecting the `UNNotificationCenter.add` call as a closure made notification tests fast and hermetic.

### What Failed
- **Strong `let coordinator`**: Caused nested `@MainActor` dealloc crash (SIGABRT). Failed because Swift enqueues a new job for each `@MainActor` deinit, and nested job-within-job has no `Task` context.
- **Making test methods `async` alone**: Necessary but not sufficient — the `unowned` fix was also required. The documented project memory entry "make tests async" is correct but incomplete for this specific scenario.

### Key Decisions
- **`unowned` (not `weak`) for coordinator**: `weak` would require `coordinator?` optional throughout, adding noise. `unowned` is safe because coordinator's lifetime is guaranteed to exceed runner's in all valid use cases (AppDelegate owns both; tests keep coordinator alive for test duration).
- **`notificationPoster` closure injection**: Avoids `UNUserNotificationCenter` in unit tests (async permission system). Alternative of mocking UNUserNotificationCenter was rejected as too complex.
- **`settleDelay: .zero` in tests**: Makes integration tests instant. Production default is 30 seconds.
- **`terminateHandler` injection**: Avoids real `NSApp.terminate(nil)` in tests. Tests pass a closure that sets a flag.

## Artifacts

- `backit/Headless/HeadlessRunner.swift` — complete implementation, `unowned coordinator` at line 15
- `backitTests/HeadlessRunnerTests.swift` — 7 tests (5 pure logic, 2 integration), all async
- `backit/LaunchAgent/LaunchAgentManager.swift` — plist version 3, `--headless` arg
- `backitTests/LaunchAgentManagerTests.swift` — 9 tests (includes 2 new v3 tests)
- `backit/AppDelegate.swift:17-77` — restructured `applicationDidFinishLaunching`
- `docs/superpowers/specs/2026-03-21-headless-powernap-design.md` — approved spec
- `docs/superpowers/plans/2026-03-21-headless-powernap.md` — completed plan

## Action Items & Next Steps

1. **Smoke test** (user doing hardware prep first):
   - Install backit normally (interactive launch) so notification permission is granted
   - Set backup time to 2 minutes from now
   - Put machine to sleep
   - Wait for backup time — machine wakes, screen stays off, backit runs silently
   - Wake machine manually — notification appears with job summary
   - Verify plist: `/usr/libexec/PlistBuddy -c "Print :BackitPlistVersion" ~/Library/LaunchAgents/backit.plist` (expect: 3)
   - Verify DB: backup run recorded in `~/Library/Application Support/backit/backit.db`

2. **After smoke test passes**: Feature is done. Consider what's next from `docs/plans/2026-03-06-backit-tasks-7-16.md` or `thoughts/shared/handoffs/general/2026-03-18_17-51-50_icloud-job-docs-future-targets.md`.

## Other Notes

- **Build command:** `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'`
- **Build-only:** `xcodebuild build -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(error:|BUILD SUCCEEDED|BUILD FAILED)'`
- **backit is a regular NSWindow app** — NOT a menubar app. Do not assume otherwise.
- `@testable import backit` — module is lowercase
- `DatabaseManager.fetchJobResults(forRun:)` — correct argument label is `forRun:` (not `runId:`)
- `BackupSettings` test isolation: `BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)`
- `HeadlessRunner` notification identifier: `"backit.headless.result"` — repeated runs replace the previous notification (no stacking)
- The `--headless` argument detection in AppDelegate: `backit/AppDelegate.swift:28`
- `HeadlessRunner.run()` flow: 30s settle → `performBackup()` → `postNotification()` → `terminateHandler()`
- `HeadlessRunner.notificationBody(jobResults:lastRunStatus:startedAt:)` is a `nonisolated static func` — testable without constructing a full runner
