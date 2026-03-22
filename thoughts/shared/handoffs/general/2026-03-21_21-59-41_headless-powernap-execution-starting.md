---
date: 2026-03-22T04:59:41Z
session_name: general
researcher: Claude Sonnet 4.6
git_commit: 7d66375bab3baffa2f20aee2ee9f784c4ef0acb7
branch: main
repository: backit
topic: "Headless PowerNap-Compatible Backup — Spec, Plan, Ready to Execute"
tags: [swift, headless, powernap, launchagent, notifications, background]
status: complete
last_updated: 2026-03-21
last_updated_by: Claude Sonnet 4.6
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Headless PowerNap backup — fully planned, ready to execute

## Task(s)

| Task | Status |
|------|--------|
| Plist versioning (version 2→3 was version 2, now already done) | ✅ Complete — commit e895138 |
| Brainstorm headless/PowerNap compatibility | ✅ Complete |
| Design spec written, reviewed (3 passes), committed | ✅ Complete |
| Implementation plan written, reviewed (2 passes), committed | ✅ Complete |
| **Execute headless PowerNap plan** | ⏳ Not started — **ready to execute via subagents** |

**Issue addressed:** When macOS sleeps at backup time, launchd wakes the machine and launches
backit, but `applicationDidFinishLaunching` always calls `showMainWindow()` which wakes the
screen. The fix adds `--headless` to the plist, lets `AppDelegate` detect it and hand off to a
new `HeadlessRunner` class that runs silently, posts a notification, and quits.

## Critical References

- **Plan:** `docs/superpowers/plans/2026-03-21-headless-powernap.md`
- **Spec:** `docs/superpowers/specs/2026-03-21-headless-powernap-design.md`

## Recent Changes

All changes since session start are committed on `main`:

- `e895138` — Add plist versioning (version 2): `needsInstall`, `BackitPlistVersion` key
- `600b344` — Add handoff documents (4 files)
- `8e48a2c` — Add headless PowerNap design spec
- `7d66375` — Add headless PowerNap implementation plan

No production code changed for the headless feature yet.

## Learnings

**`Optional.flatMap` with `[T]?` return:** `flatMap` requires closure return type `T?`, not
`[T]?`. When calling `try? db.fetchJobResults(forRun:)` inside `flatMap`, must use explicit
closure return type: `recentRun.flatMap { run -> [JobResult]? in try? db.fetchJobResults(forRun: run.id!) } ?? []`

**`RunAtLoad: true` + `--headless` = backup on every login.** Version 3 plist sets
`RunAtLoad: false` to prevent this. `StartCalendarInterval` alone is sufficient.

**"No jobs configured" is indistinguishable from `.success` with zero JobResults** in the DB —
`performBackup()` records `.success` for an empty job list. HeadlessRunner detects this as
`jobResults.isEmpty && lastRunStatus == .success`.

**`LaunchAgentManagerTests` must stay synchronous** — that class is not `@MainActor`.
`HeadlessRunnerTests` must be `async` — `HeadlessRunner` is `@MainActor` and lives in the
`backit` module.

**SourceKit false positives are endemic** — ignore all SourceKit errors. `xcodebuild build` is
the only authoritative check.

**All 53+ tests currently passing** as of commit `7d66375`.

## Post-Mortem

### What Worked
- Three-pass spec review caught real issues: wrong `flatMap` usage, `RunAtLoad` bug, missing
  `fetchJobResults` argument label (`forRun:` not `runId:`), and "no jobs configured" detection
- Two-pass plan review caught the `flatMap` compile error and clarified build expectations

### What Failed
- Nothing significant. Brainstorming and spec/plan authoring went smoothly.

### Key Decisions
- **`HeadlessRunner` as separate class** (not inline in AppDelegate) — clean separation,
  independently testable, `terminateHandler` injectable for tests
- **`notificationBody` as static func** — pure function, testable without full HeadlessRunner
- **30-second flat settle delay** (not per-job polling) — CCC handles its own failure if disk
  absent; simpler design
- **`RunAtLoad: false` in version 3** — prevents headless backup on every login
- **Silent notification, no action buttons** — informational only, delivered on next wake

## Artifacts

- `docs/superpowers/specs/2026-03-21-headless-powernap-design.md` — approved spec
- `docs/superpowers/plans/2026-03-21-headless-powernap.md` — approved plan (3 tasks, TDD, ready)

## Action Items & Next Steps

1. **Execute `docs/superpowers/plans/2026-03-21-headless-powernap.md`** using
   `superpowers:subagent-driven-development`:
   - **Task 1:** Bump `LaunchAgentManager.currentPlistVersion` to 3, add `--headless` to
     `ProgramArguments`, set `RunAtLoad: false`; add 2 tests
   - **Task 2:** Restructure `AppDelegate` — headless check after core objects, early return,
     move all UI to non-headless path; add `var headlessRunner: HeadlessRunner?`
   - **Task 3:** Create `backit/Headless/HeadlessRunner.swift` + `backitTests/HeadlessRunnerTests.swift`
2. Run full test suite after all tasks — expect all 53+ tests to pass (7 new ones added)
3. Smoke-test: put machine to sleep at backup time, confirm screen stays off, notification
   appears on next wake

## Other Notes

- Build command: `xcodebuild test -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(Test Suite|FAILED|PASSED|error:)'`
- Build-only: `xcodebuild build -project backit.xcodeproj -scheme backit -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E '(error:|BUILD SUCCEEDED|BUILD FAILED)'`
- Plist smoke-test: `/usr/libexec/PlistBuddy -c "Print :BackitPlistVersion" ~/Library/LaunchAgents/backit.plist` (expect: 3)
- backit is a **regular NSWindow app**, NOT a menubar app
- `@testable import backit` — module is lowercase
- `DatabaseManager.fetchJobResults(forRun:)` — confirmed argument label is `forRun:`
- `BackupCoordinator` factory injection for tests: `BackupCoordinator(db: db, settings: settings) { _ in [mockJob] }`
- `BackupSettings` isolation for tests: `BackupSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)`
- Task 2 build is expected to produce exactly ONE error: `cannot find type 'HeadlessRunner' in scope` — that is correct and expected before Task 3
