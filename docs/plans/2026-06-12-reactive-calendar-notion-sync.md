# Reactive Calendar → Notion Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Watch the Apple Calendar stream and push only genuinely-changed events into the Notion *Calendar Events* DB in near-real-time, so a Notion automation can fire a Co-Work webhook to generate pre-call briefs.

**Architecture:** A new `CalendarChangeWatcher` subscribes to `.EKEventStoreChanged`, applies a 30s debounce + 2-min floor (decision logic isolated in a pure, testable `ReactiveSyncScheduler`), and triggers a narrow-window (`now → +30d`) variant of the existing sync. The reactive run reuses the entire existing upsert pipeline — including the `PropertyDiff` no-op short-circuit that already guarantees only changed events get written — but forces orphan-archival off and skips the rolling-week patch. No new Notion columns, no local cache (see design doc revision note).

**Tech Stack:** Swift 5, EventKit, Foundation, XCTest. macOS 13+. No external dependencies.

**Design doc:** `docs/plans/2026-06-12-reactive-calendar-notion-sync-design.md`

---

## Conventions

- Build: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project MeetingReminder.xcodeproj -scheme MeetingReminder -configuration Debug build`
- Test: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project MeetingReminder.xcodeproj -scheme MeetingReminder -destination 'platform=macOS' test`
- All new source files must be registered in `MeetingReminder.xcodeproj/project.pbxproj` (Task 6). Until then, builds won't see them — so we write tests against the pure scheduler first (Task 1) and register early.
- Commit after each task. Use the repo's co-author trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Push only when the user asks. We're already on branch `reactive-calsync`.

---

## Task 1: `ReactiveSyncScheduler` — debounce + floor decision logic

The only genuinely unit-testable unit. Pure function, no Timer/NotificationCenter.

**Files:**
- Create: `MeetingReminder/Services/CalendarChangeWatcher.swift` (scheduler struct only for now)
- Create: `MeetingReminderTests/ReactiveSyncSchedulerTests.swift`

**Step 1: Write the failing tests**

```swift
// MeetingReminderTests/ReactiveSyncSchedulerTests.swift
import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

final class ReactiveSyncSchedulerTests: XCTestCase {
    let sched = ReactiveSyncScheduler(debounce: 30, floor: 120)

    func testFirstEverChangeFiresAfterDebounceOnly() {
        let change = iso("2026-06-12T10:00:00Z")
        // No prior run → fire at change + 30s debounce.
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: nil),
                       change.addingTimeInterval(30))
    }

    func testChangeLongAfterLastRunFiresAfterDebounce() {
        let change = iso("2026-06-12T10:00:00Z")
        let lastRun = iso("2026-06-12T09:50:00Z") // 10 min ago, well past floor
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       change.addingTimeInterval(30))
    }

    func testChangeInsideFloorIsDeferredToFloorBoundary() {
        let lastRun = iso("2026-06-12T10:00:00Z")
        let change = iso("2026-06-12T10:00:30Z") // 30s after last run
        // debounce → 10:01:00, but floor boundary is lastRun+120 = 10:02:00.
        // Floor wins.
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       lastRun.addingTimeInterval(120))
    }

    func testDebounceWinsWhenItExceedsFloorBoundary() {
        let lastRun = iso("2026-06-12T10:00:00Z")
        let change = iso("2026-06-12T10:01:45Z") // 105s after last run
        // floor boundary = 10:02:00; debounce = change+30 = 10:02:15. Debounce wins.
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       change.addingTimeInterval(30))
    }
}
```

**Step 2: Run tests — verify they fail to compile (type not defined)**

Run the Test command. Expected: build failure, `cannot find 'ReactiveSyncScheduler' in scope`. (After Task 6 registers files. For now, expect "no such module" only if the test file isn't yet in the target — that's fine; we register in Task 6 and re-run. To get a green signal sooner, do Task 6's test-file registration as part of this task's commit if convenient.)

**Step 3: Write minimal implementation**

```swift
// MeetingReminder/Services/CalendarChangeWatcher.swift
import EventKit
import Foundation

/// Pure decision logic for the reactive watcher's debounce + floor. Isolated
/// from NotificationCenter/Timer so the timing policy is unit-testable.
///
/// - `debounce`: settle a burst of edits into one run (default 30s).
/// - `floor`: minimum gap between two reactive runs (default 120s) so a stream
///   of edits can't hammer Notion.
struct ReactiveSyncScheduler {
    let debounce: TimeInterval
    let floor: TimeInterval

    init(debounce: TimeInterval = 30, floor: TimeInterval = 120) {
        self.debounce = debounce
        self.floor = floor
    }

    /// Absolute time a run triggered by a change at `changeAt` should fire,
    /// given the last run happened at `lastRunAt` (nil if never).
    func fireTime(changeAt: Date, lastRunAt: Date?) -> Date {
        let afterDebounce = changeAt.addingTimeInterval(debounce)
        guard let last = lastRunAt else { return afterDebounce }
        let floorBoundary = last.addingTimeInterval(floor)
        return max(afterDebounce, floorBoundary)
    }
}
```

**Step 4: Run tests — verify they pass** (after Task 6 registration; see note in Step 2).

**Step 5: Commit**

```bash
git add MeetingReminder/Services/CalendarChangeWatcher.swift MeetingReminderTests/ReactiveSyncSchedulerTests.swift
git commit -m "feat: ReactiveSyncScheduler debounce+floor decision logic"
```

---

## Task 2: Parameterized-window fetch on `CalendarSyncReader`

Reactive needs `now → +30d`; the existing `fetchEvents(in:)` hardcodes 90/30.

**Files:**
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` (the `CalendarSyncReader.fetchEvents(in:)` method near line 668)

**Step 1: Add a constant for the reactive look-ahead**

In `CalendarSyncConstants` (`CalendarSyncTypes.swift`, after `lookaheadDays`):

```swift
    /// Reactive runs only care about upcoming meetings (pre-call briefs), so
    /// they use a narrow forward-only window instead of the full 90/30.
    static let reactiveLookaheadDays = 30
```

**Step 2: Add the parameterized overload and make the old method delegate**

Replace the existing `fetchEvents(in:)`:

```swift
    func fetchEvents(in calendar: EKCalendar) -> [EKEvent] {
        let now = Date()
        let from = Calendar.current.date(byAdding: .day,
                                         value: -CalendarSyncConstants.lookbackDays,
                                         to: now)!
        let to   = Calendar.current.date(byAdding: .day,
                                         value:  CalendarSyncConstants.lookaheadDays,
                                         to: now)!
        return fetchEvents(in: calendar, from: from, to: to)
    }

    /// Window-parameterized fetch. The reactive path passes a narrow
    /// `now → +reactiveLookaheadDays` window.
    func fetchEvents(in calendar: EKCalendar, from: Date, to: Date) -> [EKEvent] {
        store.refreshSourcesIfNecessary()
        let p = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: p)
    }
```

**Step 3: Build to verify it compiles**

Run the Build command. Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add MeetingReminder/Services/CalendarNotionSyncService.swift MeetingReminder/Services/CalendarSyncTypes.swift
git commit -m "feat: parameterized-window fetchEvents on CalendarSyncReader"
```

---

## Task 3: `run(mode:dryRun:)` refactor + `runReactive()`

Refactor the existing monolithic `runNow` into a shared core parameterized by mode, then add the reactive entry point. **Behaviour of `runNow` must not change** — it stays full-window, orphan-aware, rolling-week-patching.

**Files:**
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` (`runNow` at line ~773)

**Step 1: Introduce a mode enum**

Above `CalendarNotionSyncService` (or as a nested type):

```swift
enum CalendarSyncMode {
    case full      // 06:00 + manual: 90/30 window, orphan sweep, rolling-week patch
    case reactive  // change-driven: now→+30d, no orphan sweep, no rolling-week patch
}
```

**Step 2: Rename the body of `runNow` to a private `run(mode:dryRun:)`**

Keep `runNow` as a thin wrapper so all existing callers (app menu, settings, daily timer, URL scheme) are untouched:

```swift
    func runNow(dryRun: Bool = false) async {
        await run(mode: .full, dryRun: dryRun)
    }

    /// Change-driven run. Narrow forward window, orphan archival forced off,
    /// rolling-week patch skipped. Shares the upsert pipeline with the full run.
    func runReactive() async {
        await run(mode: .reactive, dryRun: false)
    }

    private func run(mode: CalendarSyncMode, dryRun: Bool) async {
        // ... existing runNow body, with the three changes below ...
    }
```

**Step 3: Apply the three mode-conditional changes inside `run`**

1. **Window** — where it builds rows per calendar, replace `reader.fetchEvents(in: cal)` with:

```swift
                let events: [EKEvent]
                switch mode {
                case .full:
                    events = reader.fetchEvents(in: cal)
                case .reactive:
                    let now = Date()
                    let to = Calendar.current.date(byAdding: .day,
                        value: CalendarSyncConstants.reactiveLookaheadDays, to: now)!
                    events = reader.fetchEvents(in: cal, from: now, to: to)
                }
```

2. **Orphan archival forced off in reactive** — where the upserter is constructed:

```swift
            let upserter = CalendarSyncUpserter(client: client,
                                                logger: logger,
                                                dryRun: dryRun,
                                                archiveOrphans: mode == .full && archiveOrphansEnabled)
```

3. **Skip rolling-week patch in reactive** — the trailing block:

```swift
            if !dryRun && mode == .full {
                await patchRollingWeekViewIfConfigured(client: client)
            }
```

Also update the opening log line for clarity:

```swift
        logger.info("=== sync start (mode=\(mode == .full ? "full" : "reactive") dryRun=\(dryRun)) ===")
```

**Step 4: Build to verify**

Run the Build command. Expected: BUILD SUCCEEDED.

**Step 5: Manual smoke (no Notion writes)** — confirm `runNow` still behaves: trigger a Dry Run from Settings (existing button) and check the log shows `mode=full` and a `DRY:` summary.

**Step 6: Commit**

```bash
git add MeetingReminder/Services/CalendarNotionSyncService.swift
git commit -m "refactor: shared run(mode:) core + runReactive() entry point"
```

---

## Task 4: `CalendarChangeWatcher` — NotificationCenter + coalesced Timer

Wraps the scheduler with real EventKit observation. Lives in the file created in Task 1.

**Files:**
- Modify: `MeetingReminder/Services/CalendarChangeWatcher.swift`

**Step 1: Append the watcher class**

```swift
/// Observes the system calendar store and triggers reactive syncs, debounced
/// and floored via `ReactiveSyncScheduler`. Coalescing: at most one pending
/// run timer exists at a time; a new change reschedules it.
@MainActor
final class CalendarChangeWatcher {
    private let store = EKEventStore()
    private let scheduler = ReactiveSyncScheduler()
    private let logger: CalendarSyncLogger
    private let onFire: () async -> Void

    private var observer: NSObjectProtocol?
    private var pendingTimer: Timer?
    private var lastRunAt: Date?

    init(logger: CalendarSyncLogger, onFire: @escaping () async -> Void) {
        self.logger = logger
        self.onFire = onFire
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleChange() }
            }
        logger.info("reactive watcher: started")
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        pendingTimer?.invalidate(); pendingTimer = nil
        logger.info("reactive watcher: stopped")
    }

    private func handleChange() {
        let fireAt = scheduler.fireTime(changeAt: Date(), lastRunAt: lastRunAt)
        let delay = max(0, fireAt.timeIntervalSinceNow)
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fire() }
        }
        logger.debug("reactive watcher: change observed, run scheduled in \(Int(delay))s")
    }

    private func fire() async {
        pendingTimer = nil
        lastRunAt = Date()
        await onFire()
    }
}
```

> Note: `MainActor.assumeIsolated` is safe because the observer queue is `.main`. If targeting macOS 13 where `assumeIsolated` is unavailable, replace the closure body with `Task { @MainActor in self?.handleChange() }`.

**Step 2: Build to verify** (after Task 6 registration). Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add MeetingReminder/Services/CalendarChangeWatcher.swift
git commit -m "feat: CalendarChangeWatcher observes EKEventStoreChanged with coalesced timer"
```

---

## Task 5: Setting + service wiring + Settings UI

Opt-in toggle `calendarNotionSyncReactiveEnabled`, default false. Service owns the watcher lifecycle.

**Files:**
- Modify: `MeetingReminder/Services/CalendarSyncTypes.swift` (pref key)
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` (property + watcher)
- Modify: `MeetingReminder/Views/SettingsView.swift` (toggle, near line ~803)
- Modify: `CLAUDE.md` (Settings table row)

**Step 1: Add the pref key constant**

In `CalendarSyncConstants` (after `prefAutoLinkRelationsKey`):

```swift
    /// When true, install a CalendarChangeWatcher that runs a narrow-window
    /// reactive sync whenever the calendar store changes (debounced + floored).
    /// Default false — opt-in. The 06:00 full run is unaffected.
    static let prefReactiveEnabledKey = "calendarNotionSyncReactiveEnabled"
```

**Step 2: Add the service property + watcher lifecycle**

In `CalendarNotionSyncService`, add a stored watcher and a published-style property:

```swift
    private var changeWatcher: CalendarChangeWatcher?

    var reactiveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: CalendarSyncConstants.prefReactiveEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: CalendarSyncConstants.prefReactiveEnabledKey)
            objectWillChange.send()
            reconfigureWatcher()
        }
    }

    private func reconfigureWatcher() {
        if reactiveEnabled && isConfigured {
            if changeWatcher == nil {
                changeWatcher = CalendarChangeWatcher(logger: logger) { [weak self] in
                    await self?.runReactive()
                }
            }
            changeWatcher?.start()
        } else {
            changeWatcher?.stop()
            changeWatcher = nil
        }
    }
```

Call `reconfigureWatcher()` from `startScheduleIfEnabled()` so it installs at launch:

```swift
    func startScheduleIfEnabled() {
        rescheduleDaily()
        reconfigureWatcher()
    }
```

**Step 3: Add the Settings toggle**

In `SettingsView.swift`, in the Cal Sync tab near the other opt-in toggles (~line 803), add:

```swift
                Toggle("Watch for changes (reactive sync)",
                       isOn: Binding(get: { calendarNotionSync.reactiveEnabled },
                                     set: { calendarNotionSync.reactiveEnabled = $0 }))
                Text("Sync changed events to Notion within ~2 min of a calendar change, instead of waiting for the daily 06:00 run. Feeds Co-Work pre-call briefs via a Notion automation.")
                    .font(.caption).foregroundStyle(.secondary)
```

**Step 4: Document the setting**

Add to the Settings table in `CLAUDE.md`:

```
| `calendarNotionSyncReactiveEnabled` | Bool | false | Opt-in: watch the calendar stream and reactively sync changed events (now→+30d window) within ~2 min, in addition to the 06:00 full run |
```

Also add a short paragraph under "Calendar → Notion sync" → Trigger paths describing the reactive watcher (30s debounce, 2-min floor, narrow window, orphan sweep forced off, rolling-week patch skipped).

**Step 5: Build to verify.** Expected: BUILD SUCCEEDED.

**Step 6: Commit**

```bash
git add MeetingReminder/Services/CalendarSyncTypes.swift MeetingReminder/Services/CalendarNotionSyncService.swift MeetingReminder/Views/SettingsView.swift CLAUDE.md
git commit -m "feat: reactive-sync opt-in toggle + watcher lifecycle wiring"
```

---

## Task 6: Register new files in Xcode project + full build/test/verify

`CalendarChangeWatcher.swift` and `ReactiveSyncSchedulerTests.swift` must be added to the project, or the build won't see them.

**Files:**
- Modify: `MeetingReminder.xcodeproj/project.pbxproj`

**Step 1: Register the source + test files**

Easiest: open in Xcode and drag both files into the correct groups (Services group → `MeetingReminder` target; the test file → `MeetingReminderTests` target). Then save.

Manual pbxproj alternative — add four entries mirroring the existing patterns:
- `PBXBuildFile` for `CalendarChangeWatcher.swift` in the **MeetingReminder** Sources phase (mirror an existing `Services/*.swift` entry).
- `PBXFileReference` for `CalendarChangeWatcher.swift` (path under the Services group).
- `PBXBuildFile` (`T2...`) + `PBXFileReference` (`T1...`) for `ReactiveSyncSchedulerTests.swift`, added to the `MeetingReminderTests` group (`T4000001`) and the test target's Sources phase — mirror `T1000005`/`T2000005` (`CalendarEventMapperTests.swift`).

**Step 2: Run the full test suite**

Run the Test command. Expected: all tests pass, including the four `ReactiveSyncSchedulerTests` and the existing `CalendarEventMapperTests`.

**Step 3: Full build**

Run the Build command. Expected: BUILD SUCCEEDED with no warnings about missing files.

**Step 4: Deploy + manual end-to-end verification**

Deploy per CLAUDE.md (kill, copy from DerivedData, relaunch). Then:

1. Settings → Cal Sync → enable **Watch for changes**. Confirm the log shows `reactive watcher: started`.
2. In Calendar.app, create or move a test meeting inside the next 30 days.
3. Within ~30s–2min, confirm:
   - Log shows `=== sync start (mode=reactive ...)` and a summary with `created=` or `updated=` ≥ 1 for that event, `unchanged=` for the rest.
   - The Notion *Calendar Events* row reflects the change.
4. Make a second rapid edit; confirm the floor defers the run (log shows it scheduled ~120s out, not immediately).
5. Toggle the setting off; confirm `reactive watcher: stopped` and no further reactive runs after a calendar edit.
6. Confirm the 06:00 full run is unaffected (a manual Dry Run still logs `mode=full`).

**Step 5: Commit**

```bash
git add MeetingReminder.xcodeproj/project.pbxproj
git commit -m "build: register CalendarChangeWatcher + ReactiveSyncSchedulerTests in project"
```

---

## Post-implementation (out of band, user action)

- In Notion, add an automation on the **Calendar Events** DB: *when a page is edited → call Co-Work webhook*. The app does not create this — it only keeps Notion fresh. Recommend filtering the automation to meaningful properties (e.g. Start) to avoid firing on incidental edits, though `PropertyDiff` already suppresses no-op writes from the app side.

## Verification checklist (definition of done)

- [ ] `ReactiveSyncSchedulerTests` (4 cases) pass.
- [ ] Existing test suite still green.
- [ ] `runNow` behaviour unchanged (full window, orphan sweep, rolling-week patch).
- [ ] Reactive run uses `now→+30d`, forces orphan sweep off, skips rolling-week patch.
- [ ] Only changed events produce Notion writes (PropertyDiff `unchanged` dominates the summary).
- [ ] Toggle installs/tears down the watcher live; default off.
- [ ] Manual end-to-end: a calendar edit reaches Notion within ~2 min.
