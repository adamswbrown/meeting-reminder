# Remove Minutes and Obsidian Integrations

**Date:** 2026-05-05
**Status:** Design — for review before implementation
**Sibling plan:** [2026-05-05-native-voice-transcription-design.md](./2026-05-05-native-voice-transcription-design.md) (recommended to apply this plan **first**, then build the native pipeline)

---

## Problem

The Minutes and Obsidian integrations are both feature-flagged off by default and Adam has been unable to get Minutes working reliably. Both add real maintenance cost — combined ~1800 LOC across services, models, views, and pbxproj entries — for zero shipping value. The native voice transcription work in the sibling plan replaces what Minutes was meant to provide. Obsidian was a downstream renderer of Minutes output and has nothing to render once Minutes is gone.

## Goal

Cleanly delete both integrations so the codebase is a smaller, simpler base for the native pipeline to build on. The app retains:

- Calendar monitoring + meeting alerts (untouched)
- Notion integration for page creation on meeting join (untouched)
- Pre-call brief panel (independent — untouched)
- Context panel (minus the prep brief section)
- Ad-hoc meeting starts (the `MeetingMonitor` API stays; only the Minutes-driven side effects are removed)
- Meeting end detection via calendar end time, video app termination, and manual button
- Live Transcript pane and Post-Meeting Nudge — **deleted** in this plan, **rebuilt** by Plan A

## Non-goals

- No data migration. Minutes' files in `~/meetings/` and `~/.minutes/` are the user's; the app never created them and won't delete them.
- No backwards-compatibility shims for the `minutes*` UserDefaults keys — they're orphaned and removed in a one-shot migration.
- No deprecation period — Minutes is feature-flagged off by default; the migration is invisible to anyone who hadn't enabled it.
- No changes to the Notion or Pre-Call Brief code paths.

---

## What gets deleted

### Source files (removed entirely)

| File | LOC |
|---|---|
| `Services/MinutesService.swift` | 676 |
| `Services/ObsidianService.swift` | 498 |
| `Services/LiveTranscriptService.swift` | 278 |
| `Models/MinutesMeeting.swift` | 262 |
| `Views/LiveTranscriptView.swift` | 205 |
| `Views/PostMeetingNudgeView.swift` | 288 |
| **Total deleted** | **~2,200** |

> `LiveTranscriptService` and `LiveTranscriptView` are deleted here and **rebuilt** by Plan A around the new `TranscriptionService`. Same for `PostMeetingNudgeView`. Doing it this way (delete first, rebuild fresh) is simpler than trying to surgically refactor — the existing files are tightly coupled to Minutes' JSONL format and `MinutesMeeting` model.

### Project file edits (no full deletion)

| File | Change |
|---|---|
| `MeetingReminderApp.swift` | Remove `MinutesService`/`ObsidianService`/`LiveTranscriptService` `StateObject` declarations, init wiring, and the corresponding `OverlayCoordinator` parameters. Remove the `presentRecordingFailureAlert` helper, the `recordingDidFail` Combine sink, the Minutes/Obsidian branches in the `currentMeetingInProgress` sink. The post-meeting flow is *gutted* (no nudge, no fetch, no Obsidian open) — Plan A puts a new flow back. |
| `Views/SettingsView.swift` | Delete the entire Integrations tab (the `integrationsTab` view, `minutesContent()`, `obsidianContent()`, `integrationCard(...)`, `dashboardInstallView`, `installDashboard`, `confirmReinstallDashboard`, `chooseMinutesBinary`, `featureRow`). Delete the `minutesService`, `liveTranscriptService`, `obsidianService` `@ObservedObject` parameters. Tab count drops from 8 to 7. |
| `Views/MenuBarView.swift` | Delete the `minutesService` parameter, the `recordingSection` `@ViewBuilder` (in-progress / reconnect / processing / idle states), and the "Live Transcript" preview button. Replace the recording section with a simpler `idleView` that just shows the ad-hoc start button when no meeting is in progress, and a `inProgressView` with End button when one is. (Both are stubs — Plan A re-wires them to the new `TranscriptionService`.) |
| `Views/ContextPanelView.swift` | Delete the `minutesService` parameter, the `prepBrief` / `isLoadingPrep` `@State`, the `prepBriefSection` view, and `loadPrepBriefIfEnabled()`. The panel becomes Notion-pure: title, time, attendees, calendar notes, video link. |
| `Services/MeetingMonitor.swift` | Delete `externalRecordingActive` flag and the early-return path it gates inside `checkAudioState`. Delete `reconnectToActiveRecording(title:)` (Minutes-specific). Audio silence detection works again on its own — no external recorder holding the mic.|
| `MeetingReminder.xcodeproj/project.pbxproj` | Remove the 6 deleted-file entries from `PBXBuildFile`, `PBXFileReference`, the Models/Services/Views `PBXGroup` children, and the Sources `PBXSourcesBuildPhase`. Specifically: `A1000010`, `A1000020`, `A1000022`, `A1000023` (LiveTranscriptView), `A1000015` (PostMeetingNudgeView), `A1000030`, plus their corresponding `B1...` file refs. |

### CLAUDE.md edits

The project's CLAUDE.md is heavily oriented around Minutes (entire sections on Minutes CLI Integration, troubleshooting, conflict notes, the `externalRecordingActive` rationale, etc). After Plan B applies:

- Remove the **"Minutes CLI Integration"** section
- Remove the **"⚠️ Conflict: minutes record holds the mic for the entire meeting"** subsection
- Remove the **"Manually verifying the Minutes pipeline"** workflow block
- Remove the **"Minutes troubleshooting"** section
- Trim the architecture diagram entries for `MinutesService`, `LiveTranscriptService`, `MinutesMeeting`, `LiveTranscriptView`, `PostMeetingNudgeView`, and the Obsidian-related window controllers
- Remove the table rows for `minutesBinaryPath`, `autoRecordWithMinutes`, `minutesPrepEnabled`, `liveTranscriptEnabled`, `inCallCoachEnabled`, `coachUserName`, `obsidianIntegrationEnabled`, `obsidianAutoOpenEnabled`
- Strip the "Starting an ad-hoc meeting" section's mention of `MinutesService.startRecording` (downstream pipeline now stops at "context panel + Notion page creation")
- Remove the "Roadmap → Notion AI summary surfacing" line — it's the very gap Plan A fills

This is mechanical but high-volume; do it as a separate commit so the diff is reviewable.

---

## UserDefaults keys to clean up

These keys are orphaned by the deletions. We add a one-shot migration in `MeetingReminderApp.init` that removes them on first launch after the new build, gated by a sentinel:

```swift
// Run once per binary version that introduced the cleanup
let cleanupKey = "didCleanupMinutesObsidianV1"
if !UserDefaults.standard.bool(forKey: cleanupKey) {
    let orphaned = [
        "minutesIntegrationEnabled",
        "autoRecordWithMinutes",
        "minutesPrepEnabled",
        "minutesBinaryPath",
        "liveTranscriptEnabled",
        "inCallCoachEnabled",
        "coachUserName",
        "obsidianIntegrationEnabled",
        "obsidianAutoOpenEnabled",
    ]
    orphaned.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    UserDefaults.standard.set(true, forKey: cleanupKey)
}
```

This is purely hygienic — leaving them in `UserDefaults` would be functionally harmless but litters `defaults read com.meetingreminder.app` output and makes "what state does this app keep" harder to audit later.

The Keychain has no Minutes/Obsidian secrets (Minutes was config-file-driven, Obsidian was URL-scheme-driven). No keychain cleanup needed.

---

## What survives, with deliberate detail

### MeetingMonitor.startAdHocMeeting

The method stays. Today it does three things: creates a synthetic `MeetingEvent`, sets `currentMeetingInProgress`, and resets audio debounce state. The first two stay — the third becomes mostly redundant when `externalRecordingActive` is removed but the variable reset is harmless to keep.

The downstream effect of setting `currentMeetingInProgress` changes:
- **Before:** Minutes records, prep brief loads in context panel, live transcript opens, post-meeting nudge fires
- **After Plan B (alone):** Notion page is created (if configured), context panel opens, pre-call brief opens (if configured). Nothing else.
- **After Plan A:** Native recording starts, live transcript pane opens, post-meeting summary is pushed to Notion.

So Plan B alone leaves the app in a state where ad-hoc meetings still work, just with no recording. That's a deliberate intermediate state — the app remains useful, just less ambitious, until Plan A lands.

### Audio silence detection

Today, `MeetingMonitor.checkAudioState` short-circuits when `externalRecordingActive` is true (because Minutes was holding the mic). After Plan B removes that flag, the check works again as originally designed: if `kAudioDevicePropertyDeviceIsRunningSomewhere` reports the input device is idle for 30+ continuous seconds, the meeting is ended automatically. Plan A later replaces this with a per-stream RMS check, but in the Plan-B-only intermediate state, the original Core Audio heuristic is restored to functional health for the first time since Minutes was added.

### Notion + Pre-Call Brief

Both are completely independent of Minutes/Obsidian. No edits to:
- `Services/NotionService.swift`
- `Services/PreCallBriefService.swift`
- `Models/PreCallBrief.swift`
- `Views/BriefPanelView.swift`
- The Notion settings tab
- The pre-call brief settings (`preCallBriefsDatabaseID` etc.)

Plan A later adds an `appendStructuredSummary` method to `NotionService`, but Plan B doesn't touch it.

### OverlayCoordinator

Loses three Combine sinks (one for the Minutes/Obsidian recording pipeline, one for `recordingDidFail`, one for the post-meeting nudge), the `liveTranscriptController` and `postMeetingController` window-controller properties (deleted along with their views), and the `presentRecordingFailureAlert` static helper.

What's left in the coordinator:
- `monitor.$shouldShowOverlay` sink → `OverlayWindowController` + `ChecklistWindowController` + brief panel
- `monitor.$shouldShowMinimalAlert` sink → `MinimalAlertWindowController`
- `monitor.$shouldShowBreakOverlay` sink → `BreakOverlayWindowController`
- `monitor.$currentMeetingInProgress` sink → `NotionService.createMeetingPage` + `ContextPanelWindowController` + `BriefPanelWindowController`
- `NSApplication.willTerminateNotification` observer → close all panels (no recording to stop)

Initialiser drops to:
```swift
init(
    monitor: MeetingMonitor,
    notionService: NotionService,
    preCallBriefService: PreCallBriefService
) { ... }
```

Three params instead of six.

---

## Step-by-step removal sequence

A single PR is fine; the steps below are commit-sized chunks within it that keep the build green at each commit.

1. **Delete unused services first.** `ObsidianService` has no consumers outside `MeetingReminderApp.swift`, `SettingsView.swift`, and the post-meeting nudge. Delete the Swift file, remove from pbxproj, remove the `StateObject` from `MeetingReminderApp`, remove the parameter from `OverlayCoordinator.init`, remove all `obsidianService` references in `SettingsView.swift` (the obsidian sub-content view, dashboard install logic, etc.). The Integrations tab still renders (it just shows the Minutes card alone). Build passes.

2. **Delete the Integrations tab outright.** Remove `integrationsTab`, `integrationCard`, `minutesContent`, `featureRow`, `chooseMinutesBinary`. Remove the tab from the `TabView`. Build passes — `SettingsView` still has `minutesService` and `liveTranscriptService` `@ObservedObject` parameters, but no view references them.

3. **Delete the post-meeting nudge.** Delete `Views/PostMeetingNudgeView.swift` and remove from pbxproj. Remove `postMeetingController` from `OverlayCoordinator`. Remove the post-meeting Combine sink. The post-meeting flow becomes a no-op. Build passes.

4. **Delete the live transcript path.** Delete `Services/LiveTranscriptService.swift`, `Views/LiveTranscriptView.swift`. Remove from pbxproj. Remove `liveTranscriptService` `StateObject`, `liveTranscriptController` from `OverlayCoordinator`, the live-transcript `show(...)` calls in the in-progress sink, the "Live Transcript" preview button in `MenuBarView`. Remove `liveTranscriptService` from `SettingsView` and the now-unused references. Build passes.

5. **Delete `MinutesService` and `MinutesMeeting`.** Remove from pbxproj. Remove `minutesService` `StateObject`, the `OverlayCoordinator` param, all references in `MenuBarView` (the recording status section uses `MinutesService.status` cases — replace with simpler in-progress/idle states based on `meetingMonitor.currentMeetingInProgress` alone). Remove `loadPrepBriefIfEnabled` and the `minutesService` parameter in `ContextPanelView`. Remove `presentRecordingFailureAlert`, the `recordingDidFail` sink, and the entire Minutes branch in the in-progress sink. Build passes.

6. **Clean up `MeetingMonitor`.** Delete `externalRecordingActive`, `reconnectToActiveRecording`, the early-return path in `checkAudioState`. Audio silence detection now works unconditionally. Build passes.

7. **CLAUDE.md cleanup.** Strip the Minutes/Obsidian sections. Separate commit so the docs diff is reviewable.

8. **UserDefaults migration.** Add the one-shot cleanup block to `MeetingReminderApp.init`. Tested by setting `defaults write com.meetingreminder.app obsidianIntegrationEnabled -bool true` first, launching, then `defaults read` — the key should be gone.

9. **Verify build + manual smoke test.**

After all steps the integration-pruned app does:
- Calendar alerts (full feature)
- Ad-hoc meetings (Notion page + context panel + pre-call brief; no recording)
- Notion-driven meeting note creation
- Pre-call brief panel
- Audio silence detection for end-of-meeting (working again)

Plan A then fills in the recording / transcription / summary side.

---

## Testing

1. **Fresh launch on a clean profile** — no Integrations tab visible. Settings has 7 tabs (General, Alerts, Display, Appearance, Checklist, Calendars, Notion).
2. **Calendar meeting flow** — overlay fires at reminder, user clicks Join, Notion page opens, context panel appears (no prep brief section), no live transcript pane, no post-meeting nudge. Meeting ends via calendar end time → Notion page stays open as the durable artefact.
3. **Ad-hoc meeting** — menu bar → "Start ad-hoc meeting" → context panel + Notion page open. End meeting via "End meeting" button. No nudge, no errors. The MeetingMonitor's `currentMeetingInProgress` correctly transitions back to nil.
4. **No Minutes binary on disk** — confirm there are no stderr complaints, no PATH probes, no `minutes status` polling. `Activity Monitor` should show no spawned processes related to the app during a meeting.
5. **UserDefaults migration** — set the legacy keys before upgrade, launch, run `defaults read com.meetingreminder.app | grep -E "minutes|obsidian|liveTranscript|coach"` → should produce no matches.
6. **Audio silence end-detection** — start an ad-hoc meeting on a Mac with no apps using the mic, wait 35 seconds, verify the meeting ends automatically (Core Audio device-not-running fallback works again).
7. **Manual Quit while in meeting** — `⌘Q` mid-call. No recording to stop, all panels close cleanly. (The willTerminate observer's `await stopRecording` line is gone.)
8. **Existing tests** — the 4 XCTest files (`VideoLinkDetectorTests`, `MeetingEventTests`, `OverlayBackgroundTests`, `ClampedExtensionTests`) reference none of the removed types and should pass without modification. Verify with `xcodebuild test`.

---

## Files

| File | Change |
|---|---|
| `Services/MinutesService.swift` | DELETE |
| `Services/ObsidianService.swift` | DELETE |
| `Services/LiveTranscriptService.swift` | DELETE |
| `Models/MinutesMeeting.swift` | DELETE |
| `Views/LiveTranscriptView.swift` | DELETE |
| `Views/PostMeetingNudgeView.swift` | DELETE |
| `MeetingReminderApp.swift` | EDIT — strip Minutes/Obsidian/LiveTranscript wiring; add one-shot UserDefaults cleanup |
| `Services/MeetingMonitor.swift` | EDIT — drop `externalRecordingActive`, `reconnectToActiveRecording`, audio-skip path |
| `Views/SettingsView.swift` | EDIT — delete Integrations tab and dependent helpers |
| `Views/MenuBarView.swift` | EDIT — drop `minutesService` param, simplify recording section, drop preview button |
| `Views/ContextPanelView.swift` | EDIT — drop `minutesService` param and prep brief section |
| `MeetingReminder.xcodeproj/project.pbxproj` | EDIT — remove the 6 file references and their PBXBuildFile/PBXGroup entries |
| `CLAUDE.md` | EDIT — strip the Minutes-/Obsidian-specific sections (separate commit) |

LOC removed: ~2,200 source + ~200 docs. LOC added: ~10 (the one-shot UserDefaults cleanup).

---

## Risks

1. **Ad-hoc meetings feel broken in the intermediate state.** Between Plan B landing and Plan A landing, "Start ad-hoc meeting" creates a Notion page and opens the context panel but doesn't record anything. If we ship Plan B alone for >1-2 days, users may complain. Mitigation: ship both as a single release, or temporarily disable the ad-hoc start buttons in the menu bar until Plan A lands.

2. **CLAUDE.md drift.** If Plan A is in-flight while Plan B is being applied, two parallel branches will both edit CLAUDE.md and conflict. Mitigation: do them sequentially, one PR each, with Plan B merged first.

3. **PBXProj merge conflicts.** Manual pbxproj edits are conflict-prone. Mitigation: do the deletes in one commit, on a fresh branch off main, and rebase Plan A on top of Plan B before opening the second PR.

4. **A user has files in `~/meetings/` they wanted preserved.** We don't touch the user's filesystem, only the app's state. Their Minutes-generated markdown files are untouched. Worth a one-line README note to that effect.

5. **A user actually uses the Obsidian dashboard.** If anyone has installed the Dataview dashboard via `obsidianService.installDashboard()`, that file is in their vault and still works (Dataview queries against `~/meetings/<slug>.md` files Minutes wrote). Plan B doesn't touch it. They'd lose the ability to *reinstall* the dashboard from inside the app, but the dashboard itself keeps functioning as long as Minutes writes new meetings. Document this in the changelog.

---

## Out of scope

- Migrating Minutes-generated markdown into Notion. The user's `~/meetings/` files are theirs to keep or delete. Plan A's Notion-based pipeline is forward-looking only.
- Refactoring `MeetingMonitor` beyond the minimal removal of `externalRecordingActive` / `reconnectToActiveRecording`. The class is fine as-is.
- Touching the existing test suite. None of its assertions cover removed code.
- Changing CLAUDE.md sections that aren't directly about Minutes/Obsidian (build/run, git remotes, deploy, etc. all stay).
