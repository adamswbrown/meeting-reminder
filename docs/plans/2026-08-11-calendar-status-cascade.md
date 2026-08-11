# Calendar Status Cascade Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When a briefed meeting is cancelled or rescheduled, make `CalendarNotionSyncService` authoritatively write the change back to the *Calendar Events* row **and** cascade it onto the linked *Pre-Call Briefing* metadata.

**Architecture:** Extend the existing disappearance detector (`CalendarSyncUpserter.processOrphans`). A row that was `Active`, is now absent from the calendar fetch, and whose date is in-window gets stamped `Status = Cancelled` + `Sync State = Orphaned`, and — if it links a Pre-Call Briefing — that brief's `Meeting Outcome` is set to `Cancelled`. A moved one-off (row date changed with a linked brief) cascades the new start onto the brief's `Date & Time`. All new behaviour is gated by a new default-ON pref `calendarNotionSyncCascadeStatus`, decoupled from the off-by-default `calendarNotionSyncArchiveOrphans`. New pure decision logic is extracted into a testable `CalendarSyncCascade` enum; network PATCH orchestration follows the codebase's existing untested-but-manual pattern.

**Tech Stack:** Swift 5 (region-based concurrency), XCTest, Notion API `2025-09-03`, `xcodebuild`. No SwiftPM deps.

**Design doc:** `docs/plans/2026-08-11-calendar-status-cascade-to-notion-design.md`

**Reference reading before starting:**
- `MeetingReminder/Services/CalendarNotionSyncService.swift` — `CalendarSyncNotionQueries.ExistingRow` (~line 111), `fetchExistingEvents` (~line 165-210), extract helpers (`relationCount`/`extractSelectName`/`extractDateStart`, ~205-270), `CalendarSyncUpserter.run` + `processOrphans` (~480-700), run-mode wiring (~1100).
- `MeetingReminder/Services/CalendarSyncTypes.swift` — `CalendarSyncConstants` pref keys + relation names (~70-118).
- `MeetingReminder/Services/CalendarEventMapper.swift` — `compositeAppleID`, `buildProperties`.
- `MeetingReminderTests/CalendarEventMapperTests.swift` — test style (`StubEvent`, `iso()` helper).

**Build/test commands (run from the worktree root):**
```bash
XCODE=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
# Run all tests:
$XCODE -project MeetingReminder.xcodeproj -scheme MeetingReminder -destination 'platform=macOS' test 2>&1 | tail -8
# Run one test class:
$XCODE -project MeetingReminder.xcodeproj -scheme MeetingReminder -destination 'platform=macOS' \
  -only-testing:MeetingReminderTests/CalendarSyncCascadeTests test 2>&1 | tail -12
# Build only:
$XCODE -project MeetingReminder.xcodeproj -scheme MeetingReminder -configuration Debug build 2>&1 | tail -5
```
Baseline as of this plan: **162 tests, 0 failures.**

**pbxproj warning:** new source/test files must be added to `MeetingReminder.xcodeproj/project.pbxproj` with **globally-unique** object IDs (mirror an existing file's 4 entries: PBXBuildFile / PBXFileReference / group children / Sources phase). ID collisions fail silently with "cannot find X in scope". Adding via Xcode UI is safest; if editing by hand, pick a fresh unused ID.

---

### Task 1: New pref key `calendarNotionSyncCascadeStatus`

**Files:**
- Modify: `MeetingReminder/Services/CalendarSyncTypes.swift` (in `CalendarSyncConstants`, after `prefReactiveEnabledKey`, ~line 100)

**Step 1: Add the key.** No test (it's a constant). Add:

```swift
    /// When true, cancel/reschedule status changes are cascaded onto the
    /// Calendar Events row (Status = Cancelled / Sync State) AND the linked
    /// Pre-Call Briefing (Meeting Outcome = Cancelled / Date & Time). Default
    /// TRUE — this only ever flips status metadata, never archives. Independent
    /// of `prefArchiveOrphansKey`. See docs/plans/2026-08-11-calendar-status-cascade-to-notion-design.md
    static let prefCascadeStatusKey = "calendarNotionSyncCascadeStatus"
```

**Step 2: Build.** `$XCODE ... build | tail -5` → `** BUILD SUCCEEDED **`.

**Step 3: Commit.**
```bash
git add MeetingReminder/Services/CalendarSyncTypes.swift
git commit -m "feat(cal-sync): add calendarNotionSyncCascadeStatus pref key (default on)"
```

---

### Task 2: `CalendarSyncCascade` pure helpers — brief pageID + recurring detection

**Files:**
- Create: `MeetingReminder/Services/CalendarSyncCascade.swift`
- Create: `MeetingReminderTests/CalendarSyncCascadeTests.swift`
- Modify: `MeetingReminder.xcodeproj/project.pbxproj` (add both files to their targets)

**Step 1: Write the failing tests.** Create `MeetingReminderTests/CalendarSyncCascadeTests.swift`:

```swift
import XCTest
@testable import MeetingReminder

final class CalendarSyncCascadeTests: XCTestCase {

    // MARK: briefPageID(fromRelation:)

    func testBriefPageIDReturnsFirstRelationID() {
        let prop: [String: Any] = ["relation": [["id": "abc-123"], ["id": "def-456"]]]
        XCTAssertEqual(CalendarSyncCascade.briefPageID(fromRelation: prop), "abc-123")
    }

    func testBriefPageIDNilWhenEmpty() {
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: ["relation": [[String: Any]]()]))
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: nil))
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: ["select": ["name": "x"]]))
    }

    // MARK: isRecurringAppleID

    func testRecurringAppleIDDetectsDateSuffix() {
        XCTAssertTrue(CalendarSyncCascade.isRecurringAppleID("XYZ_2026-08-12"))
    }

    func testRecurringAppleIDDetectsRID() {
        XCTAssertTrue(CalendarSyncCascade.isRecurringAppleID("040000008200E000/RID=20260812"))
    }

    func testRecurringAppleIDFalseForPlainUUID() {
        XCTAssertFalse(CalendarSyncCascade.isRecurringAppleID("0277BA37-EDB2-46DF-B159-D97DEDC48C5E"))
    }
}
```

**Step 2: Run to verify it fails** (`CalendarSyncCascade` undefined → compile fail). Expected: build error.

**Step 3: Write minimal implementation.** Create `MeetingReminder/Services/CalendarSyncCascade.swift`:

```swift
import Foundation

/// Pure decision logic for cascading calendar status changes into Notion.
/// Extracted so the branching is unit-testable without a live Notion client.
/// See docs/plans/2026-08-11-calendar-status-cascade-to-notion-design.md
enum CalendarSyncCascade {

    /// First related page ID from a Notion relation property payload
    /// (read-format `{"relation":[{"id":"..."}]}`), or nil.
    static func briefPageID(fromRelation any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["relation"] as? [[String: Any]],
              let first = arr.first,
              let id = first["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// True when an Apple Event ID represents a recurring occurrence — it ends
    /// in `_YYYY-MM-DD` or contains `/RID=`. Recurring occurrences vanish from
    /// EventKit when *moved* (not cancelled), so they are excluded from the
    /// reactive cancel cascade. Mirrors the intraday skill's Step 5 rule.
    static func isRecurringAppleID(_ id: String) -> Bool {
        if id.contains("/RID=") { return true }
        return id.range(of: "_[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }
}
```

**Step 4: Add both files to the Xcode project** (source → `MeetingReminder` target, test → `MeetingReminderTests` target). Run the class tests:
`$XCODE ... -only-testing:MeetingReminderTests/CalendarSyncCascadeTests test | tail -12` → all pass.

**Step 5: Commit.**
```bash
git add MeetingReminder/Services/CalendarSyncCascade.swift MeetingReminderTests/CalendarSyncCascadeTests.swift MeetingReminder.xcodeproj/project.pbxproj
git commit -m "feat(cal-sync): CalendarSyncCascade pure helpers (brief pageID, recurring detection)"
```

---

### Task 3: `classifyDisappearance` — the cancel-vs-stale-vs-skip decision

**Files:**
- Modify: `MeetingReminder/Services/CalendarSyncCascade.swift`
- Modify: `MeetingReminderTests/CalendarSyncCascadeTests.swift`

Model the outcome so `processOrphans` can drive both Sync State and Status writes plus the brief cascade from one pure call.

**Step 1: Write failing tests.** Append to `CalendarSyncCascadeTests`:

```swift
    // MARK: classifyDisappearance

    private func decide(manual: Bool, recurring: Bool, reactive: Bool,
                        cascade: Bool = true, archive: Bool = true) -> CalendarSyncCascade.Disappearance {
        CalendarSyncCascade.classifyDisappearance(
            hasManualRelations: manual, isRecurring: recurring,
            isReactive: reactive, cascadeEnabled: cascade, archiveEnabled: archive)
    }

    func testCleanCancellationCascades() {
        let d = decide(manual: false, recurring: false, reactive: false)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    func testManualRelationsRowGoesStaleNotCancelled() {
        let d = decide(manual: true, recurring: false, reactive: false)
        XCTAssertEqual(d.syncState, "Stale")
        XCTAssertNil(d.rowStatus)              // never mark a manually-worked row Cancelled
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    func testRecurringSkippedOnReactive() {
        let d = decide(manual: false, recurring: true, reactive: true)
        XCTAssertTrue(d.skip)                  // moved recurring occurrence — not a cancellation
    }

    func testRecurringSweptOnFullRun() {
        let d = decide(manual: false, recurring: true, reactive: false)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.rowStatus, "Cancelled")
    }

    func testCascadeDisabledStillWritesSyncStateWhenArchiveOn() {
        let d = decide(manual: false, recurring: false, reactive: false, cascade: false, archive: true)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertNil(d.rowStatus)              // Status/brief writes are cascade-gated
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    func testBothDisabledSkips() {
        let d = decide(manual: false, recurring: false, reactive: false, cascade: false, archive: false)
        XCTAssertTrue(d.skip)
    }
```

**Step 2: Run to verify fail** (undefined `Disappearance`/`classifyDisappearance`).

**Step 3: Implement.** Append to `CalendarSyncCascade`:

```swift
    /// Decision for a row whose event has disappeared from the calendar
    /// (already filtered to in-window, not-touched by the caller).
    struct Disappearance {
        /// Target `Sync State` select, or nil to leave unchanged.
        let syncState: String?
        /// Target `Status` select (only "Cancelled"), or nil to leave unchanged.
        let rowStatus: String?
        /// Whether to PATCH the linked brief's Meeting Outcome = Cancelled.
        let cascadeBriefCancelled: Bool
        /// Whether the caller should do nothing for this row.
        let skip: Bool
    }

    static func classifyDisappearance(hasManualRelations: Bool,
                                      isRecurring: Bool,
                                      isReactive: Bool,
                                      cascadeEnabled: Bool,
                                      archiveEnabled: Bool) -> Disappearance {
        let noop = Disappearance(syncState: nil, rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: true)
        // Neither behaviour enabled → nothing to do.
        guard cascadeEnabled || archiveEnabled else { return noop }
        // A moved recurring occurrence vanishes from EventKit without being
        // cancelled; the reactive window can't disambiguate, so defer to the
        // daily full run.
        if isReactive && isRecurring { return noop }

        // A row carrying manual work is marked Stale, never Cancelled.
        if hasManualRelations {
            return Disappearance(syncState: "Stale", rowStatus: nil,
                                 cascadeBriefCancelled: false, skip: false)
        }
        // A clean disappearance: Orphaned always; Cancelled + brief cascade
        // only when the cascade behaviour is enabled.
        return Disappearance(syncState: "Orphaned",
                             rowStatus: cascadeEnabled ? "Cancelled" : nil,
                             cascadeBriefCancelled: cascadeEnabled,
                             skip: false)
    }
```

**Step 4: Run class tests → pass.**

**Step 5: Commit.**
```bash
git add MeetingReminder/Services/CalendarSyncCascade.swift MeetingReminderTests/CalendarSyncCascadeTests.swift
git commit -m "feat(cal-sync): classifyDisappearance decision (cancel/stale/skip)"
```

---

### Task 4: Capture the linked brief pageID on `ExistingRow`

**Files:**
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` — `ExistingRow` struct (~line 111) and `fetchExistingEvents` construction (~line 180-195)

**Step 1:** Add a stored field to `ExistingRow` (after `hasPreCallBriefingLink`):
```swift
        /// Page ID of the first linked Pre-Call Briefing (read from the
        /// relation payload), or nil. Used by the status cascade to PATCH the
        /// brief's Meeting Outcome / Date & Time. No extra Notion query.
        let preCallBriefingPageID: String?
```

**Step 2:** In `fetchExistingEvents`, where the `ExistingRow(...)` candidate is built, add:
```swift
                    preCallBriefingPageID: CalendarSyncCascade.briefPageID(
                        fromRelation: props[CalendarSyncConstants.calendarEventsPreCallBriefingRelation]),
```
(Place it alongside `hasPreCallBriefingLink:` in the initializer.)

**Step 3: Build.** Expect `** BUILD SUCCEEDED **` (all `ExistingRow(...)` call sites updated — there is one).

**Step 4: Run full tests** → 162 pass (no behaviour change yet).

**Step 5: Commit.**
```bash
git add MeetingReminder/Services/CalendarNotionSyncService.swift
git commit -m "feat(cal-sync): capture linked Pre-Call Briefing pageID on ExistingRow"
```

---

### Task 5: Wire the cancel cascade into `processOrphans`

**Files:**
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` — `CalendarSyncUpserter` init/props (~454-463), `run(...)` orphan gate (~610-616), `processOrphans` (~635-700), run-mode construction (~1100-1106)

This wires the pure decisions into real PATCHes. No unit test (network orchestration — verified by build + full suite + manual acceptance in Task 8), matching the codebase's existing pattern.

**Step 1:** Add stored props to `CalendarSyncUpserter` beside `archiveOrphans`:
```swift
    private let cascadeStatus: Bool
    private let isReactive: Bool
```
Add matching init params and assignments.

**Step 2:** Change the orphan-pass gate. In `run(...)` where it reads `if archiveOrphans {`, broaden to:
```swift
        if archiveOrphans || cascadeStatus {
            await processOrphans(touched: touched,
                                 existing: existing,
                                 orphanWindow: orphanWindow,
                                 counts: &counts)
        }
```

**Step 3:** Rewrite the per-row body of `processOrphans` to use `classifyDisappearance` and write Status + brief cascade. Replace the `for appleID in orphanIDs { ... }` loop body with:
```swift
        for appleID in orphanIDs {
            guard let row = existing[appleID] else { continue }
            let decision = CalendarSyncCascade.classifyDisappearance(
                hasManualRelations: row.hasManualRelations,
                isRecurring: CalendarSyncCascade.isRecurringAppleID(appleID),
                isReactive: isReactive,
                cascadeEnabled: cascadeStatus,
                archiveEnabled: archiveOrphans)
            if decision.skip { continue }

            // Build the row PATCH. Skip when already in target state to avoid
            // re-PATCH churn (transition-only) — covers both Sync State and Status.
            var rowProps: [String: Any] = [:]
            if let ss = decision.syncState, row.syncState != ss {
                rowProps["Sync State"] = ["select": ["name": ss]]
            }
            let alreadyCancelled = CalendarSyncCascade
                .isCancelledStatus(row.properties["Status"])
            if let st = decision.rowStatus, !alreadyCancelled {
                rowProps["Status"] = ["select": ["name": st]]
            }

            // The brief cascade fires only on the transition into Cancelled
            // (i.e. the row wasn't already Cancelled) so it runs exactly once.
            let doBriefCascade = decision.cascadeBriefCancelled
                && !alreadyCancelled
                && row.preCallBriefingPageID != nil

            if rowProps.isEmpty && !doBriefCascade { continue }

            do {
                if dryRun {
                    logger.info("DRY \(decision.rowStatus ?? decision.syncState ?? "?") \(appleID) :: \(row.pageID)\(doBriefCascade ? " +brief" : "")")
                } else {
                    if !rowProps.isEmpty {
                        _ = try await client.patch(path: "/pages/\(row.pageID)",
                                                   body: ["properties": rowProps])
                    }
                    if doBriefCascade, let briefID = row.preCallBriefingPageID {
                        _ = try await client.patch(path: "/pages/\(briefID)",
                            body: ["properties": ["Meeting Outcome": ["select": ["name": "Cancelled"]]]])
                    }
                }
                if decision.rowStatus == "Cancelled" { counts.orphaned += 1 } else { counts.staled += 1 }
            } catch {
                logger.error("cascade/orphan failed for \(appleID): \(error)")
                counts.failed += 1
            }
        }
```

**Step 4:** Add the small `isCancelledStatus` helper to `CalendarSyncCascade` (with a test in `CalendarSyncCascadeTests`: a `{"select":{"name":"Cancelled"}}` payload → true; `Upcoming` → false; nil → false). Implement:
```swift
    static func isCancelledStatus(_ any: Any?) -> Bool {
        guard let dict = any as? [String: Any],
              let sel = dict["select"] as? [String: Any],
              let name = sel["name"] as? String else { return false }
        return name == "Cancelled"
    }
```

**Step 5:** Update the upserter construction (~line 1103) to pass the new args:
```swift
            let upserter = CalendarSyncUpserter(client: client,
                                                logger: logger,
                                                dryRun: dryRun,
                                                archiveOrphans: mode == .full && archiveOrphansEnabled,
                                                cascadeStatus: cascadeStatusEnabled && (mode == .full),
                                                isReactive: mode != .full)
```
Add a computed `cascadeStatusEnabled` next to `archiveOrphansEnabled` (~854):
```swift
    var cascadeStatusEnabled: Bool {
        UserDefaults.standard.object(forKey: CalendarSyncConstants.prefCascadeStatusKey) as? Bool ?? true
    }
```
(Full-run only for now; reactive is enabled in Task 6.)

**Step 6: Build + full tests** → `** BUILD SUCCEEDED **`, 162+ pass.

**Step 7: Commit.**
```bash
git add MeetingReminder/Services/CalendarNotionSyncService.swift MeetingReminder/Services/CalendarSyncCascade.swift MeetingReminderTests/CalendarSyncCascadeTests.swift
git commit -m "feat(cal-sync): cascade cancellation to row Status + linked brief Meeting Outcome"
```

---

### Task 6: Enable the cascade on reactive runs (fast path, recurring-safe)

**Files:**
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` — reactive-run construction

**Step 1:** Flip the Task-5 `cascadeStatus` argument so reactive runs also cascade:
```swift
                                                cascadeStatus: cascadeStatusEnabled,
```
`isReactive: mode != .full` is already correct — `classifyDisappearance` skips recurring rows when `isReactive` is true, so a moved recurring occurrence is never mis-cancelled reactively; the daily full run reconciles it.

**Step 2:** Confirm `runReactive()`'s orphanWindow is passed to the upserter run (it uses the reactive now→+30d window as the in-window guard). If `runReactive` currently passes `orphanWindow: nil`, set it to the reactive window so out-of-window rows aren't swept. Verify at the `runReactive` call site (~line 949) and the `mode` wiring (~1100).

**Step 3: Build + full tests** → pass.

**Step 4: Commit.**
```bash
git add MeetingReminder/Services/CalendarNotionSyncService.swift
git commit -m "feat(cal-sync): cascade cancellations on reactive runs (skip recurring)"
```

---

### Task 7: Reschedule cascade — new start onto the linked brief's Date & Time

**Files:**
- Modify: `MeetingReminder/Services/CalendarSyncCascade.swift` (+ tests)
- Modify: `MeetingReminder/Services/CalendarNotionSyncService.swift` — inside `CalendarSyncUpserter.run`'s per-row UPDATE branch (~530-560), after a successful PATCH of a row whose date changed

**Step 1: Write failing test** for a pure date-change detector. Append to `CalendarSyncCascadeTests`:
```swift
    func testDateChangedDetectsMove() {
        let old = iso("2026-08-11T13:00:00Z")
        let new = iso("2026-08-12T08:00:00Z")
        XCTAssertTrue(CalendarSyncCascade.startChanged(incoming: new, existing: old))
        XCTAssertFalse(CalendarSyncCascade.startChanged(incoming: old, existing: old))
        XCTAssertFalse(CalendarSyncCascade.startChanged(incoming: new, existing: nil))
    }
```
(Add an `iso()` helper to the test file if not present — copy from `CalendarEventMapperTests`.)

**Step 2: Implement:**
```swift
    /// True when a row's incoming start differs from what Notion currently has
    /// (both non-nil). Used to cascade a one-off move onto the linked brief.
    static func startChanged(incoming: Date, existing: Date?) -> Bool {
        guard let existing else { return false }
        return abs(incoming.timeIntervalSince(existing)) >= 60
    }
```

**Step 3:** In the UPDATE branch of `run(...)`, after the row PATCH succeeds, cascade to the brief when the start moved and a brief is linked. Use the incoming event start (`row.event.eventStart`) vs `existingRow.eventDate`, gated on `cascadeStatus` and a non-recurring appleID:
```swift
                        if cascadeStatus,
                           !CalendarSyncCascade.isRecurringAppleID(appleID),
                           let briefID = existingRow.preCallBriefingPageID,
                           CalendarSyncCascade.startChanged(incoming: row.event.eventStart,
                                                            existing: existingRow.eventDate) {
                            let london = TimeZone(identifier: "Europe/London")!
                            let iso = ISO8601DateFormatter(); iso.timeZone = london
                            iso.formatOptions = [.withInternetDateTime]
                            let start = iso.string(from: row.event.eventStart)
                            let end = iso.string(from: row.event.eventEnd)
                            _ = try? await client.patch(path: "/pages/\(briefID)", body: ["properties": [
                                "Date & Time": ["date": ["start": start, "end": end]]
                            ]])
                            logger.info("cascade: re-dated brief \(briefID) → \(start)")
                        }
```
(Note: `EventLike` exposes `eventStart`/`eventEnd`. Confirm the row tuple's `.event` conforms — it does; the mapper reads the same. Recurring occurrences are excluded to avoid rewriting a prior occurrence's brief.)

**Step 4: Build + full tests** → pass.

**Step 5: Commit.**
```bash
git add MeetingReminder/Services/CalendarSyncCascade.swift MeetingReminderTests/CalendarSyncCascadeTests.swift MeetingReminder/Services/CalendarNotionSyncService.swift
git commit -m "feat(cal-sync): cascade a one-off reschedule onto the linked brief Date & Time"
```

---

### Task 8: Settings toggle + docs

**Files:**
- Modify: `MeetingReminder/Views/SettingsView.swift` (or `CalComSettingsView`/Notion Cal-Sync sub-tab where `calendarNotionSyncArchiveOrphans` is surfaced — grep for it)
- Modify: `CLAUDE.md` (settings table + Cal-Sync section)

**Step 1:** Grep for the existing archive-orphans toggle to mirror it:
```bash
grep -rn "calendarNotionSyncArchiveOrphans\|archiveOrphans" MeetingReminder/Views
```
Add an `@AppStorage("calendarNotionSyncCascadeStatus") var cascadeStatus = true` toggle in the same Cal-Sync settings section, labelled e.g. **"Reflect cancellations/reschedules in Notion (row + brief)"** with a short help string.

**Step 2:** Update `CLAUDE.md`:
- Add `calendarNotionSyncCascadeStatus | Bool | true | ...` to the UserDefaults keys table.
- Add a bullet to the **Calendar → Notion sync** section describing the cascade (row `Status=Cancelled`/`Sync State=Orphaned` + brief `Meeting Outcome=Cancelled`; reschedule re-dates the brief; reactive skips recurring; decoupled from archive-orphans).

**Step 3: Build** → success.

**Step 4: Commit.**
```bash
git add MeetingReminder/Views CLAUDE.md
git commit -m "feat(cal-sync): Settings toggle + docs for status cascade"
```

---

### Task 9: Full verification + manual acceptance

**Step 1:** Full suite: `$XCODE ... test | tail -8` → all green.

**Step 2:** Deploy the debug build (see CLAUDE.md "Deploy build to /Applications"): kill, copy, relaunch.

**Step 3: Manual acceptance (reactive path):**
- Ensure `calendarNotionSyncReactiveEnabled` and `calendarNotionSyncCascadeStatus` are on and a Notion token is configured.
- Create a throwaway Exchange meeting today with a linked brief (or reuse a test row), let it sync, then cancel it.
- Within ~2 min confirm in Notion: the Calendar Events row shows `Status=Cancelled` + `Sync State=Orphaned`, and the linked brief shows `Meeting Outcome=Cancelled`.
- Tail the log: `tail -f ~/Library/Logs/MeetingReminder/calendar-notion-sync.log` for the `cascade` lines.

**Step 4: Dry-run safety check:** run a Dry Run from Settings and confirm the log shows `DRY … +brief` lines but no writes occur.

**Step 5:** When green, use `superpowers:finishing-a-development-branch` to merge/PR `feat/cal-status-cascade` and clean up the worktree.

---

## Notes / risks

- **pbxproj IDs** (Task 2) are the top failure risk — use fresh unique IDs.
- **`EventLike.eventStart/eventEnd`** are used for the reschedule cascade; verify the tuple's `.event` type exposes them (it feeds the mapper, so it does).
- **Idempotence** relies on the transition-only guard (`!alreadyCancelled`); without it the brief would be re-PATCHed every reactive tick while the row sits Orphaned.
- **Coexistence** with the intraday skill REMOVED path is fine — both writes are idempotent and converge.
