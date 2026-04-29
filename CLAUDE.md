# Meeting Reminder for Mac

Native macOS menu bar app (Swift + SwiftUI) with ADHD-focused features. Reads the user's calendar, shows progressive alerts, displays a full-screen blocking overlay before meetings, integrates with Notion for meeting notes, and detects meeting end via Core Audio.

Target: macOS 13+ (Ventura). Swift 5. No external dependencies.

---

## Build & Run

```bash
# Build via xcodebuild
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build

# Open in Xcode
open MeetingReminder.xcodeproj
```

### Deploy build to /Applications

The standard local workflow after building:

```bash
killall MeetingReminder 2>/dev/null
rm -rf "/Applications/MeetingReminder.app"
cp -R "$HOME/Library/Developer/Xcode/DerivedData/MeetingReminder-altmwzoqczxbuhdhhyinjhkmcsgv/Build/Products/Debug/MeetingReminder.app" "/Applications/MeetingReminder.app"
open -a "/Applications/MeetingReminder.app"
```

The DerivedData hash (`altmwzoqczxbuhdhhyinjhkmcsgv`) is stable per machine. If it changes, find it via:

```bash
xcodebuild -project MeetingReminder.xcodeproj -scheme MeetingReminder -configuration Debug -showBuildSettings | grep " BUILT_PRODUCTS_DIR"
```

### Reset onboarding (for testing)

```bash
defaults write com.meetingreminder.app hasCompletedOnboarding -bool false
```

---

## Git Remotes

This project has **two remotes**:

| Name | URL | Purpose |
|------|-----|---------|
| `mine` | `https://github.com/adamswbrown/meeting-reminder.git` | Adam's fork — **default push target** |
| `origin` | `https://github.com/nilBora/meeting-reminder/` | Upstream — fetch only, never push |

### Push behaviour

`git push` (with no arguments) pushes to `mine` because of these git config settings:

```
remote.pushDefault = mine
branch.main.pushRemote = mine
```

So:

```bash
git push                  # → adamswbrown/meeting-reminder (your fork) ✅
git push mine main        # explicit, same destination ✅
git push origin main      # → nilBora upstream ❌ DO NOT DO THIS
```

### Pulling upstream changes

`git pull` still pulls from `origin` (nilBora upstream) by default. To merge upstream changes:

```bash
git fetch origin
git merge origin/main
git push  # pushes the merge to mine
```

### When making commits

- **Always push to `mine`**, never `origin`
- The `git push` command (no args) is safe — pre-configured to push to `mine`
- If you need to verify before pushing: `git remote -v` and check the config with `git config --get remote.pushDefault`

---

## Architecture

```
MeetingReminder/
├── MeetingReminderApp.swift              # @main entry, MenuBarExtra, OverlayCoordinator, onboarding
├── Models/
│   ├── MeetingEvent.swift                # Wraps EKEvent (title, dates, attendees, notes, location)
│   ├── ChecklistItem.swift               # Pre-meeting checklist data model (Codable)
│   └── MinutesMeeting.swift              # Parsed `minutes` markdown + YAML frontmatter
├── Services/
│   ├── CalendarService.swift             # EventKit: access, fetch, filter, meeting stats
│   ├── MeetingMonitor.swift              # Core orchestrator: timers, alerts, end detection, ad-hoc meetings
│   ├── VideoLinkDetector.swift           # Regex detection: Zoom, Meet, Teams, Webex, Slack
│   ├── AlertTier.swift                   # Progressive alert tier enum + MenuBarUrgency enum
│   ├── NotificationService.swift         # UNUserNotificationCenter wrapper for banners
│   ├── ScreenDimmer.swift                # IOKit brightness control (gradual dimming)
│   ├── KeychainHelper.swift              # Generic Keychain wrapper (Generic password class)
│   ├── MinutesService.swift              # Wrapper around the local `minutes` CLI (record, stop, fetch, prep)
│   └── LiveTranscriptService.swift       # Tails ~/.minutes/live-transcript.jsonl + heuristic in-call coach
├── Views/
│   ├── MenuBarView.swift                 # Window-style popover (event list, meeting load, previews, ad-hoc start)
│   ├── OverlayWindow.swift               # NSPanel wrappers for meeting + break overlays
│   ├── OverlayView.swift                 # Full-screen overlay UI (Join/Snooze/Dismiss)
│   ├── SettingsView.swift                # 7-tab preferences
│   ├── OnboardingView.swift              # First-launch setup (standalone NSWindow)
│   ├── ContextPanelView.swift            # Floating meeting context panel (attendees, notes, AI prep brief)
│   ├── ChecklistView.swift               # Pre-meeting checklist panel
│   ├── BreakOverlayView.swift            # Soft full-screen break overlay
│   ├── FloatingPromptView.swift          # Non-blocking context-switch prompt
│   ├── PostMeetingNudgeView.swift        # Post-meeting nudge with parsed action items + decisions
│   └── LiveTranscriptView.swift          # Floating live transcript pane + heuristic coach hints
├── Resources/Assets.xcassets             # App icon
├── Info.plist                            # LSUIElement=true, calendar usage descriptions
└── MeetingReminder.entitlements          # Network client (sandbox disabled — see Sandbox section)
```

### Key components

**MeetingMonitor** (`Services/MeetingMonitor.swift`) — the heart of the app. Runs two timers:
- 30s check timer for meeting state changes
- 10s menu bar update timer for countdown text

Tracks state via several sets/dicts:
- `shownEventIDs` — overlay already shown for this event
- `snoozedEvents` — eventID → snooze-until-Date
- `firedAlertTiers` — eventID → set of tier raw values fired
- `meetingEndedIDs` — events marked as ended (prevents re-firing)
- `currentMeetingInProgress` — currently active meeting (set on join, on `markMeetingDone`, or via `startAdHocMeeting`)

**Ad-hoc meetings** — `MeetingMonitor.startAdHocMeeting(title:durationMinutes:)` creates a synthetic `MeetingEvent` (id `adhoc-<uuid>`, calendar `"Ad-hoc"`, no video link) and assigns it to `currentMeetingInProgress`. This **deliberately reuses the same publisher** that the OverlayCoordinator subscribes to, so the entire downstream pipeline (start `minutes record`, show context panel, open live transcript pane, fire post-meeting nudge on end) runs identically to a calendar-driven meeting. Default title is `"Ad-hoc meeting · HH:mm"` if none supplied. Default duration is 60 min — only used as the calendar-based fallback for end detection; Core Audio silence still ends the meeting earlier in practice.

**OverlayCoordinator** (in `MeetingReminderApp.swift`) — owns all NSPanel window controllers and observes `MeetingMonitor` published state via Combine. Holds a `MinutesService` and a `LiveTranscriptService` (passed via init) and uses them to drive recording lifecycle and the live transcript pane. Listens for `NSApplication.willTerminateNotification` to close all panels and stop any active recording on quit.

**MinutesService** (`Services/MinutesService.swift`) — wrapper around the local [`silverstein/minutes`](https://github.com/silverstein/minutes) CLI. Spawns `minutes record --title "<title>"` as a detached background process when `currentMeetingInProgress` transitions non-nil. Spawns `minutes stop` on the reverse transition. Polls `~/meetings/<slug>.md` for the parsed markdown, then surfaces `MinutesMeeting` (action items + decisions parsed from YAML frontmatter) to the post-meeting nudge. Also composes a "prep brief" by running `minutes person <name>` per attendee + `minutes research <title>` and feeds it to the context panel. Slug is computed deterministically as `YYYY-MM-DD-{kebab-title}` matching Minutes' filename convention.

**LiveTranscriptService** (`Services/LiveTranscriptService.swift`) — `@MainActor ObservableObject` that polls `~/.minutes/live-transcript.jsonl` every 1.5 seconds during a meeting. The Minutes recording sidecar writes one JSON object per chunk: `{line, ts, offset_ms, duration_ms, text, speaker}`. New lines are appended to a `@Published` array (bounded to 200 entries) and analysed by lightweight pattern detectors that publish `CoachHint` records:
- **Question detected** — line ends with `?` or starts with `what/when/where/why/how/who/which/could you/can you/would you/do you/does anyone`
- **Mention** — user's first name or full name appears with word boundaries (defaults to `NSFullUserName()`, overridable in Settings); plays a Tink chime
- **Commitment** — match against ~19 patterns like `i'll send`, `i'll follow up`, `by friday`, `by eod`

Hints are de-duped (same kind suppressed for 8 seconds) and bounded to the last 5 visible.

**Window controllers** — each floating UI element has its own controller class wrapping an `NSPanel`:
- `OverlayWindowController` — meeting overlay (`.screenSaver` level, all screens)
- `BreakOverlayWindowController` — break enforcement overlay
- `ChecklistWindowController` — checklist panel (`.screenSaver - 1` level)
- `ContextPanelWindowController` — meeting context panel (`.floating`)
- `FloatingPromptWindowController` — context-switch nudge (`.floating`)
- `PostMeetingNudgeWindowController` — post-meeting capture nudge
- `LiveTranscriptWindowController` — live transcript pane (`.floating`)
- `OnboardingWindowController` — first-launch setup (titled `NSWindow`, `.floating`)

---

## Key Technical Decisions

### SwiftUI & MenuBarExtra
- **MenuBarExtra with `.window` style** — avoids the SwiftUI NSMenu item tracking bug ("rep returned item view with wrong item") that occurs with `.menu` style when content changes dynamically
- **Dynamic menu bar label** — uses `meetingMonitor.menuBarText` and `menuBarUrgency` published properties to drive the label content (icon + text), updated every 10s
- **`.symbolRenderingMode(.palette)`** — required to colourise SF Symbols in the menu bar label
- **Onboarding as standalone NSWindow** — NOT a `.sheet` on the menu bar popover (sheets break on `MenuBarExtra` popovers; can't be clicked through). `OnboardingWindowController` creates its own `.titled, .closable` window at `.floating` level

### Window Management
- **NSPanel at `.screenSaver` level** — overlay appears above full-screen apps and all spaces
- **LSUIElement = true** — runs as background menu bar agent, no Dock icon
- **`NSApp.activate(ignoringOtherApps: true)` + `orderFrontRegardless()`** — required after opening Settings because LSUIElement apps don't get focus automatically
- **All panels closed on `NSApplication.willTerminateNotification`** — prevents lingering windows after quit
- **`@Environment(\.openSettings)`** (macOS 14+) — required to open Settings; the `sendAction(showSettingsWindow:)` selector is blocked on macOS 14+. Wrapped in `PreferencesButton14` with `@available` check, falls back to `showPreferencesWindow:` on macOS 13

### Meeting End Detection (hybrid)
1. **Core Audio monitoring** (primary, when no external recorder) — `kAudioDevicePropertyDeviceIsRunningSomewhere` polled every 5s. Detects when the mic goes idle.
2. **30-second debounce** — audio must be inactive for 30+ continuous seconds before triggering "meeting ended". Prevents false positives during screen-share transitions or brief mic drops.
3. **Video app lifecycle** (secondary) — `NSWorkspace.didTerminateApplicationNotification` for known video bundle IDs (Zoom, Teams, Webex, Slack)
4. **Calendar end time** (fallback) — `event.endDate` as backstop
5. **Manual override** — "Done with meeting" button in menu bar dropdown, **and the End Meeting button in the live transcript pane** (only path that works while Minutes is recording)

#### ⚠️ Conflict: `minutes record` holds the mic for the entire meeting

When `MinutesService.startRecording` is active, the mic stays open until `minutes stop` runs. `kAudioDevicePropertyDeviceIsRunningSomewhere` returns `true` continuously, so the silence-debounce in `checkAudioState` can never fire.

The fix: `MeetingMonitor.externalRecordingActive` is a flag the `OverlayCoordinator` flips to `true` when it spawns a Minutes recording and back to `false` when the meeting ends. While set, `checkAudioState` short-circuits and clears `audioInactiveSince`, so silence detection is paused. In this mode, the **only** end signals are:

- The user clicks **End Meeting** in the live transcript pane (`onEndMeeting` callback → `monitor.markMeetingDone()`)
- The user clicks **Done with meeting** in the menu bar dropdown
- The calendar `endDate` is reached (`checkMeetingEnded` fallback — for calendar-driven events only; ad-hoc meetings have a 60-min default duration that's effectively a max length)
- A known video app (Zoom/Teams/Webex/Slack) terminates (`startVideoAppMonitoring` — only fires if such an app was actually running)

This is a **deliberate trade-off**, not a bug: the value of having a transcript outweighs the loss of automatic mic-silence end detection. Users in real Zoom calls who *also* enable Minutes get both — Zoom holds the mic, Minutes piggybacks on it, and the end signal comes from Zoom terminating, not silence.

### Minutes CLI Integration
- **Local-first**, no API keys, no network. The user installs the [`silverstein/minutes`](https://github.com/silverstein/minutes) Rust CLI separately via Homebrew (`brew tap silverstein/tap && brew install minutes`). All transcription happens locally via whisper.cpp.
- **CLI invocation pattern** — every call goes through `MinutesService.runCLI(args:)` which spawns `/bin/sh -lc "<binary> <quoted args>"` on a background DispatchQueue. Login-shell `-l` is critical so Homebrew's `/opt/homebrew/bin` is on PATH inside the spawned subprocess.
- **Recording is detached, not synchronous** — `startRecording` spawns `minutes record --title "..." >/dev/null 2>&1 &` so the shell forks the recording into the background and exits immediately. The grandchild reparents to launchd. `stopRecording` is a separate process call (`minutes stop`) that signals the running recorder via Minutes' own state file. This means we never hold a long-lived `Process` reference.
- **Status check before start** — `minutes status` returns JSON with `recording: bool` and `processing: bool`. We parse it (not string-grep — the word "recording" is always in the JSON output as a key) and skip starting if either flag is true.
- **Filename slug** — Minutes saves meetings as `~/meetings/YYYY-MM-DD-{kebab-title}.md`. We compute the same slug deterministically client-side from the event title and current date so we don't need to scrape `minutes list` to find the file.
- **Markdown parsing** — `MinutesMeeting.parse(markdownAt:)` reads the YAML frontmatter between `---` fences using a hand-rolled minimal YAML parser (`MinutesYAML` in the same file). It handles top-level scalars, lists of strings, and lists of mappings (for `action_items` and `decisions`). Nested mappings like `entities:` are silently skipped. **No external dependency** — preserves the project's "no SwiftPM packages" promise.
- **Prep brief composition** — `minutes prep` is a Claude Code plugin command, **not** a CLI subcommand (verified). We compose the equivalent by running `minutes research <title>` once and `minutes person <name>` per attendee (capped at 3 to bound cost). Output is plain text joined into the context panel's prep section. Triggered from `ContextPanelView.onAppear`, not from `joinMeeting`, so it doesn't block the join click.
- **Live transcript schema** — the Minutes recording sidecar writes JSON lines to `~/.minutes/live-transcript.jsonl` while `minutes record` is active. Each line: `{line: int, ts: ISO8601 with fractional seconds + tz, offset_ms: int, duration_ms: int, text: string, speaker: string?}`. `LiveTranscriptService` polls (not file-watches — simpler) every 1.5s and tracks the last seen `line` number to skip already-processed entries.
- **Calendar feature must be disabled** in `~/.config/minutes/config.toml` — set `[calendar] enabled = false`. Otherwise `minutes health` shells out to AppleScript trying to talk to Calendar.app, which produces a `Application isn't running. (-600)` warning. We use Meeting Reminder as the calendar source of truth and only feed Minutes the title via `--title`.

### Calendar → Notion sync

A scheduled feature that pushes Apple Calendar events (Exchange-backed) into a pre-built Notion database called *Calendar Events* (data source `1d605620-3b70-47f1-96d8-465e57fd0bdd`, under the Operations parent page). Becomes the canonical event ledger that downstream automations (e.g. the 07:00 pre-call briefings task) read from. **One-way only** — Notion → Apple is out of scope.

- **Orchestrator** lives in `Services/CalendarNotionSyncService.swift`. Pure-data transformation logic is split out into `CalendarEventMapper.swift` (no EventKit imports — testable with stub structs) and `CalendarSyncTypes.swift` (the `EventLike` protocol, `EKEvent` adapter, logger, constants, skip filter).
- **Identity strategy** — the upsert key is a composite "Apple Event ID":
  - Non-recurring events: bare `calendarItemExternalIdentifier` (the Exchange iCal UID).
  - Recurring occurrences: `<external_id>_<YYYY-MM-DD>` where the date is the occurrence's start time rendered in **Europe/London** local time (so a 23:30 BST meeting doesn't get tagged with tomorrow's UTC date).
  - Synthetic series-master rows: bare `<external_id>` (no date suffix). Emitted once per recurring series so Notion has a single row representing the series definition alongside one row per occurrence in the window. Mapper code: `CalendarEventMapper.expandToRows`.
- **Shared Notion token with `NotionService`** — both use the same Keychain entry `notionAPIToken`. Token management UI lives in the Notion tab; the Cal Sync tab is a consumer that just shows whether a token is set. Originally planned as two separate tokens but collapsed once the user extended their existing integration's permissions to cover the Operations subtree (Calendar Events + Skip List) in addition to the create-meeting-page database.
- **Trigger paths**:
  - Daily timer at 06:00 local — scheduled when the app launches if the Settings toggle is on. Single-shot `Timer.scheduledTimer` that re-arms after each fire (no launchd needed; the menu bar app is always running).
  - Menu bar dropdown row "Sync calendar to Notion now" — appears once a token is configured.
  - Settings → "Cal Sync" tab — Sync Now / Dry Run / Open Log buttons + token entry + enable toggle.
  - URL scheme `meetingreminder://calsync` — wired up in `MeetingReminderApp.onOpenURL`. Apple Shortcuts hook: build a Shortcut with one *Open URL* action targeting that URL.
- **Window** — 90 days lookback, 30 days lookahead. EventKit expands recurrence automatically via `predicateForEvents`, so each occurrence comes back as its own `EKEvent`.
- **Source calendar resolution** — `CalendarSyncReader.resolveExchangeCalendar()` filters `eventStore.calendars(for: .event)` by `title == "Calendar"` and `source.title == "Exchange"`. If multiple match, ties broken by trailing-30-day event volume. No caching — it's a fast in-memory filter.
- **Skip List** — `CalendarSyncNotionQueries.fetchSkipRules` reads from Notion DS `77164bfd-8536-4c3a-ba3d-701fe64fc9b3` at runtime. Schema: `Meeting Title` (title), `Match Type` (select: "Exact Title" / "Title Contains"), `Active` (checkbox). Filter applied in `MeetingMonitor`-style: matches are dropped from the upsert pipeline entirely. Sharing the rule list with the existing Pre-Call Briefings task avoids drift.
- **Notion API** — `2025-09-03` version. All upserts target the **data source ID**, not the database ID. Backoff: 3 attempts, exponential (0.5s, 1s, 2s), retriable on 429/502/503/504 + transport errors.
- **Log file** — `~/Library/Logs/MeetingReminder/calendar-notion-sync.log`. Rotating at 5 MB (one `.1` backup). Open via Settings button or `tail -f` directly.
- **Rolling-week view auto-patch** — Notion's view DSL only supports absolute date filters, so a "this week" view goes stale every Monday. After each sync run, `CalendarNotionSyncService.patchRollingWeekViewIfConfigured` recomputes Mon–Sun in Europe/London and PATCHes `/v1/views/{id}` with `{filter: {and: [{property: "Date", date: {on_or_after: "..."}}, {property: "Date", date: {on_or_before: "..."}}]}}`. View ID stored in `calendarNotionRollingWeekViewID` UserDefaults. Skipped on dry-run. Manual "Patch now" button in Settings runs only the patch (no full sync).
- **Schema migrations** — `Services/CalendarSyncMigrations.swift` runs at the top of every `runNow` (before upserts) and is gated by a Notion log database (DS `7590658a-f038-45c1-b6ca-d50b2421b0c4`). Each `Migration` has a stable `id`, a description, and a closure that mutates the DS schema via `PATCH /v1/data_sources/{id}`. Helpers like `ensureSelectColumn` are idempotent — re-running an already-applied migration is a safe no-op even if the log entry was deleted. Failures abort the sync run; refusing to write against a half-migrated schema is safer than silently dropping new properties. Dry-run logs the migrations that *would* apply but doesn't mutate. Registered to date: `001-add-sync-state-column`, `002-add-source-calendar-column`, `003-add-availability-column`.
- **Multi-calendar** — `CalendarSyncReader.enabledCalendars()` reads `calendarNotionSyncEnabledCalendarIDs` (a Settings list of opted-in `EKCalendar` identifiers) and returns the matching calendars. When the list is empty, `runNow` falls back to the single Exchange "Calendar" via `resolveExchangeCalendar()` so v1 behaviour is preserved on first launch after upgrade. Each row carries its source calendar's display name through the pipeline as a third tuple element `(event, isSeriesMaster, sourceCalendarName)`. `CalendarSyncReader.notionCalendarName(for:)` maps the Exchange calendar to the legacy `"Calendar (Exchange)"` label and uses the EKCalendar title for everything else — Notion's `Calendar` and `Source Calendar` select columns auto-create new options on write. The orphan-detection set is global across all opted-in calendars in a single run, so events present on calendar A aren't false-archived just because they're missing from calendar B.
- **Availability column + OOO heuristic** — every row writes an `Availability` select (Busy / Free / Tentative / OOO / Unknown) derived from `EKEvent.availability` (`EKEventAvailability` raw values 1–4). EventKit's Exchange bridge often returns `.notSupported` (rawValue 0) for events that *are* OOO at the Exchange end (verified 2026-04-29 against an "Annual Leave" all-day block — Exchange's free/busy bit is dropped at the bridge layer; there's no API to recover it). When `.notSupported`, `CalendarEventMapper.looksLikeOOO` falls back to a title heuristic matching: `annual leave / out of office / out-of-office / ooo / on leave / pto / vacation / holiday / sick leave / off work / off sick`. Hits become `OOO`, everything else `Unknown`. The `calendarNotionSyncSkipFreeAndOOO` opt-in toggle drops `.free` and OOO rows before upsert.
- **Orphan archive (B2)** — opt-in via `calendarNotionSyncArchiveOrphans`. After upserts, any row in `existing.keys - touched` is classified: rows with manual `Meeting Notes` or `Pre-Call Briefing` populated → `Sync State = Stale` (visible, never archived). Otherwise → `Sync State = Orphaned` plus `archived: true` on the page. UPDATE path always writes `archived: false` plus `Sync State = Active`, so a row that comes back from the calendar (or got mistakenly archived) auto-un-archives on the next run.
- **Auto-link Meeting Notes / Pre-Call Briefings (B1)** — opt-in via `calendarNotionSyncAutoLinkRelations`. After each upsert, rows whose `Meeting Notes` and/or `Pre-Call Briefing` columns are empty become candidates. `Services/RelationLinker.swift` queries the corresponding Notion DS server-side with an `and` filter (`title contains <event title>` AND date `on_or_after` / `on_or_before` the event's start day in Europe/London), then re-filters locally to **exact case-insensitive title equality** so a "Sync" event can't grab "Sync with Bob". Exactly 1 hit → PATCH the relation column on the Calendar Events row (Notion auto-mirrors the inverse `Calendar Event` relation onto the MN/PCB row). 0 hits = no-op. >1 hits = ambiguous, skipped, both pageIDs logged. Append-only: rows with manual relations are filtered out at target-collection time inside the upserter — `ExistingRow.hasMeetingNotesLink` / `hasPreCallBriefingLink` are checked per-column. Schema (verified 2026-04-29): Meeting Notes uses title=`Title`, date=`Start`; Pre-Call Briefings uses title=`Meeting Title`, date=`Date & Time`.
- **Duplicate detection** — `fetchExistingEvents` builds an `appleID → ExistingRow` map and a separate `[String: [String]]` duplicates list when the same `Apple Event ID` appears on more than one row. Canonical pageID is deterministic: prefer non-archived, then first-seen. Run summary surfaces `duplicates=N` when any are present, and the Settings "Scan Duplicates" button runs the same query read-only and writes the result to `lastResult`. Archived rows are included in the lookup so a previously-archived row that comes back from the calendar gets PATCHed (with `archived: false`) instead of duplicating.
- **Things this deliberately does not do**:
  - No deletion of Notion rows. Archive (B2) is reversible; rows with manual relations are marked Stale, not archived.
  - No automatic resolution of duplicate rows — the Scan reports them; the user decides which to archive.
  - No bidirectional sync.

### Sandbox
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO` in both Debug and Release configs). This is required because spawning arbitrary user-installed binaries (like `/opt/homebrew/bin/minutes`) is fundamentally incompatible with the macOS sandbox — there's no entitlement that grants execute permission for unsigned third-party binaries. We tried security-scoped bookmarks and they don't help here.
- The entitlements file still declares `com.apple.security.network.client = true` (harmless leftover, useful for any future HTTP integrations) and explicitly sets `com.apple.security.app-sandbox = false`.

### Settings & Persistence
- **`@AppStorage`** for simple preferences
- **JSON-encoded UserDefaults** for `defaultChecklist` (array of `ChecklistItem`)
- **Keychain** — `KeychainHelper` (`Services/KeychainHelper.swift`) is a generic Keychain wrapper kept around for future API-token use cases. Currently no secrets are stored.
- **OverlayBackground enum** — stores background choice as string in `@AppStorage("overlayBackground")`, returns `AnyShapeStyle` for use in overlay

---

## Settings (UserDefaults keys)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hasCompletedOnboarding` | Bool | false | Onboarding finished — skip on next launch |
| `reminderMinutes` | Int | 5 | Minutes before meeting to show overlay |
| `soundEnabled` | Bool | true | Play alert sound with overlay |
| `colorBlindMode` | Bool | false | Use colour-blind friendly menu bar palette |
| `overlayBackground` | String | "dark" | Background theme (9 options) |
| `enabledCalendarIDs` | [String] | [] | Calendar IDs to monitor (empty = all) |
| `wrapUpMinutes` | Int | 10 | Minutes before meeting for wrap-up nudge |
| `progressiveAlertsEnabled` | Bool | true | Enable tiered alert escalation |
| `alertTierAmbientEnabled` | Bool | true | 15-min menu bar colour change |
| `alertTierBannerEnabled` | Bool | true | 10-min system notification |
| `alertTierUrgentEnabled` | Bool | true | 5-min menu bar orange + chime |
| `alertTierBlockingEnabled` | Bool | true | 2-3 min full-screen overlay |
| `alertTierLastChanceEnabled` | Bool | true | 0-min overlay re-fire |
| `screenDimmingEnabled` | Bool | false | Gradual brightness reduction (off by default) |
| `breakEnforcementEnabled` | Bool | true | Break overlay between back-to-back meetings |
| `contextSwitchPromptMinutes` | Int | 3 | Minutes before meeting for context-switch nudge |
| `defaultChecklist` | Data (JSON) | defaults | Pre-meeting checklist items |
| `minutesBinaryPath` | String | `/opt/homebrew/bin/minutes` | Path to the `minutes` CLI binary (user-pickable in Settings) |
| `autoRecordWithMinutes` | Bool | true | Automatically run `minutes record` when a meeting joins |
| `minutesPrepEnabled` | Bool | true | Generate AI prep brief from past meetings + show in context panel |
| `liveTranscriptEnabled` | Bool | true | Show floating live transcript pane during meetings |
| `inCallCoachEnabled` | Bool | true | Run heuristic detectors on the live transcript and surface hints |
| `coachUserName` | String | "" | Override for mention detection (defaults to `NSFullUserName()` when empty) |
| `calendarNotionSyncEnabled` | Bool | false | Enable the daily 06:00 Calendar→Notion sync timer |
| `calendarNotionSyncLastRunAt` | Date | nil | Timestamp of the last sync attempt (success or failure) |
| `calendarNotionSyncLastResult` | String | nil | Single-line summary of the last sync (e.g. `created=12 updated=180 skipped=4 failed=0`) |
| `calendarNotionRollingWeekViewID` | String | "" | Optional Notion view UUID to PATCH each run with the current Mon–Sun bracket |
| `calendarNotionSyncArchiveOrphans` | Bool | false | Opt-in: archive Notion rows whose source calendar event has disappeared (B2) |
| `calendarNotionSyncEnabledCalendarIDs` | [String] | [] | Opt-in list of EKCalendar IDs to sync. Empty = fall back to single Exchange calendar (B4) |
| `calendarNotionSyncSkipFreeAndOOO` | Bool | false | Opt-in: drop `.free` and OOO events before upsert |
| `calendarNotionSyncAutoLinkRelations` | Bool | false | Opt-in: auto-link Meeting Notes & Pre-Call Briefings on unambiguous title+day match (B1) |

### Keychain keys

| Key | Purpose |
|-----|---------|
| `notionAPIToken` | Single Notion integration token used by both `NotionService` (create-meeting-page) and `CalendarNotionSyncService` (Cal Sync). The integration must have access to all the relevant databases — including the Operations parent page where Calendar Events + Skip List live. |

---

## Common workflows

### Adding a new feature

1. Decide which layer it belongs to (Service vs View vs Model)
2. If it's a new view with its own panel, create both the SwiftUI View and an `NSWindowController` wrapper class in the same file
3. Wire up the controller in `OverlayCoordinator` (`MeetingReminderApp.swift`)
4. Add it to the appropriate Settings tab if it has user-facing options
5. **Add to Xcode project** — new files must be added to `MeetingReminder.xcodeproj/project.pbxproj`. Either via Xcode UI or by manually editing PBXBuildFile/PBXFileReference/group children/Sources build phase entries
6. Build to verify: `xcodebuild ... build`
7. Deploy: kill, copy, relaunch (see Deploy section above)

### Testing previews without real meetings

The menu bar dropdown has a Preview section:
- **Meeting Overlay** — calls `meetingMonitor.testOverlay()` with a fake event
- **Pre-Meeting Checklist** — `overlayCoordinator.previewChecklist()`
- **Context Panel** — `overlayCoordinator.previewContextPanel()` (also shows the AI prep brief loading state)

### Starting an ad-hoc meeting (no calendar event)

Call `meetingMonitor.startAdHocMeeting(title:durationMinutes:)` from anywhere in the UI (typically a menu bar button). Both arguments are optional:
- `title` defaults to `"Ad-hoc meeting · HH:mm"`
- `durationMinutes` defaults to `60`

This creates a synthetic `MeetingEvent` with calendar `"Ad-hoc"`, no video link, and no attendees. Setting `currentMeetingInProgress` triggers the Combine sink in `OverlayCoordinator.startObserving()` which fires the *exact same downstream pipeline* as a calendar-driven meeting:

1. `MinutesService.startRecording(for: event)` spawns `minutes record --title "<adhoc title>"`
2. `ContextPanelWindowController` opens (prep brief will be empty since there are no attendees and no past meetings on this exact title — this is fine, it just shows the meeting context)
3. After 1.5s, `LiveTranscriptWindowController` opens
4. Core Audio silence detection (or `markMeetingDone()`) eventually fires `handleMeetingEnded`, which stops recording, closes panels, and shows the post-meeting nudge with parsed action items

The 60-minute duration is only consumed by the calendar-end-time fallback in `checkMeetingEnded`. In practice the Core Audio 30-second silence debounce ends ad-hoc meetings well before the duration expires.

### Manually verifying the Minutes pipeline

```bash
# 1. Confirm minutes is on PATH and healthy
which minutes && minutes --version && minutes health

# 2. Confirm the live transcript file is being written during recording
nohup minutes record --title "Pipeline test" </dev/null >/tmp/m.log 2>&1 &
disown
sleep 8
minutes transcript --status   # should show {"active": true, "source": "recording-sidecar", ...}
cat ~/.minutes/live-transcript.jsonl   # should contain JSON lines as soon as whisper has chunks
minutes stop
```

### Testing onboarding

```bash
defaults write com.meetingreminder.app hasCompletedOnboarding -bool false
```

Then click the menu bar icon — onboarding will appear in a standalone window.

### Minutes troubleshooting

Common issues:

- **`minutes` command not found in app but works in Terminal** — your shell PATH isn't being inherited. `MinutesService` runs commands via `/bin/sh -lc` (login shell) so Homebrew's bin dir gets picked up. If it's still missing, set the binary path manually in Settings → Minutes → Choose binary…
- **`minutes health` warns about Calendar (-600)** — Minutes' built-in calendar feature uses AppleScript to query Calendar.app. We don't use it. Disable with `[calendar] enabled = false` in `~/.config/minutes/config.toml` (only have one `[calendar]` section — the file rejects duplicates with a TOML parse error).
- **`failed to symlink meeting.dir, file exists, OS error 17`** — stale recording state from a crashed session. Run `minutes status` to confirm idle, then `pkill -f "minutes record"` and inspect `~/.minutes/` for dangling symlinks or `meeting.dir` files to delete.
- **Live transcript pane shows "Listening…" forever** — the recording sidecar takes ~5–8s to write its first chunk (whisper needs to buffer enough audio). If it never appears, check `~/.minutes/live-transcript.jsonl` directly: `tail -f ~/.minutes/live-transcript.jsonl` while a recording is running.
- **Post-meeting nudge says "Transcribing… check Minutes in a moment"** — `MinutesService.fetchMeeting` polls 6 times at 5s intervals (30s max). For long meetings transcription can take longer; the file will appear in `~/meetings/` eventually even if the nudge gives up.

---

## Icon Generation

```bash
python3 generate_icon.py
```

Requires `Pillow`. Generates all 10 sizes into `AppIcon.appiconset/`.

---

## Roadmap

See [docs/ADHD-FEATURES-ROADMAP.md](docs/ADHD-FEATURES-ROADMAP.md) for the full feature roadmap. Phase 4 items (not yet implemented):

- "What Was I Doing?" bookmark (requires Accessibility permission)
- Decline assist (blocked by EventKit limitation)
- Per-calendar checklist overrides
- Notion AI summary surfacing
- Multi-monitor screen dimming
