# Meeting Reminder for Mac

Native macOS menu bar app (Swift + SwiftUI) with ADHD-focused features. Reads the user's calendar, shows progressive alerts, displays a full-screen blocking overlay before meetings, integrates with Notion for meeting notes, and detects meeting end via Core Audio.

Target: macOS 13+ (Ventura). Swift (language mode 5), built with a modern Xcode — Xcode 26 locally; CI uses `latest-stable`. No external dependencies — no SwiftPM packages.

> **v3.0.0 (2026-06-15)** removed the **Minutes** (local transcription) and **Obsidian** integrations. Capture/notes is now **Notion-only**. Current integrations: Notion (notes + Calendar sync), **Busy Light** (Shortcuts — see [docs/BUSY-LIGHT.md](docs/BUSY-LIGHT.md)), the **Availability page** (Supabase push — see [docs/AVAILABILITY-PAGE.md](docs/AVAILABILITY-PAGE.md)), and **self-service Booking** (Supabase + EventKit + Microsoft Graph email, Mail.app fallback — see [docs/BOOKING.md](docs/BOOKING.md)).

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
│   └── PreCallBrief.swift                # Notion-fed pre-call brief model
├── Services/
│   ├── CalendarService.swift             # EventKit: access, fetch, filter, meeting stats. Filters all-day/declined/**cancelled** (`.canceled`) events via the pure `CalendarEventInclusion` predicate so an organiser-cancelled meeting stops showing in the menu bar
│   ├── MeetingMonitor.swift              # Core orchestrator: timers, alerts, end detection, ad-hoc meetings, mic state
│   ├── MeetingLauncher.swift             # Opens/join video links
│   ├── VideoLinkDetector.swift           # Regex detection: Zoom, Meet, Teams, Webex, Slack
│   ├── AlertTier.swift                   # Progressive alert tier enum + MenuBarUrgency enum
│   ├── NotificationService.swift         # UNUserNotificationCenter wrapper for banners
│   ├── ScreenDimmer.swift                # IOKit brightness control (gradual dimming)
│   ├── DisplayPreferences.swift          # Overlay/display preference helpers
│   ├── KeychainHelper.swift              # Generic Keychain wrapper (Generic password class)
│   ├── AudioProcessMonitor.swift         # Per-process mic-input detection (macOS 14+); busy-light source of truth
│   ├── BusyLightService.swift            # Shortcuts-driven busy light (meeting/mic state → run a Shortcut)
│   ├── AvailabilityPushService.swift     # EventKit → Supabase free/busy push for the public availability page
│   ├── BookingPollService.swift          # Polls Supabase booking_requests → live conflict check → EKEvent + confirmation email/.ics via Microsoft Graph (Mail.app fallback)
│   ├── GraphMailService.swift            # Sends booking email from Exchange via Graph /me/sendMail; OAuth device-code auth, refresh token in Keychain
│   ├── BookingSupport.swift              # Pure booking helpers: PendingBooking decode, overlap test, .ics builder, Mail AppleScript composer (Exchange-account-asserted)
│   ├── CalComService.swift               # Cal.com v2 REST wrapper: event types, schedules, bookings, cancel, reschedule. API key in Keychain as `calComAPIKey`
│   ├── CalComSyncService.swift           # Polls Cal.com every 5 min + on wake; creates/tags EKEvents (`[calcom-booking-id:<uid>]`); cancellation sweep
│   ├── CalComNotionBridge.swift          # On CalComSyncService .created, fires NotionService.createMeetingPage() so a meeting-notes page exists before the 06:00 CalendarNotionSyncService run
│   ├── NotionService.swift               # Notion: create meeting page + shared token
│   ├── NotionProvisioningService.swift   # OOTB guided setup: creates the 5 Notion DBs (Meeting Notes, Pre-Call Briefings, Calendar Events + relations, Skip List, Migrations) under a user-chosen page via the 2025-09-03 API; writes their data source IDs to UserDefaults overrides
│   ├── PreCallBriefService.swift         # Composes/fetches the Notion-fed pre-call brief
│   ├── CalendarNotionSyncService.swift   # Calendar → Notion sync orchestrator
│   ├── CalendarEventMapper.swift         # Pure-data event → Notion row mapping (no EventKit import)
│   ├── CalendarSyncTypes.swift           # EventLike protocol, EKEvent adapter, logger, constants
│   ├── CalendarSyncMigrations.swift      # Idempotent Notion schema migrations
│   ├── RelationLinker.swift              # Auto-link Meeting Notes / Pre-Call Briefings
│   ├── CalendarChangeWatcher.swift       # Reactive .EKEventStoreChanged watcher (opt-in)
│   └── PreCallBriefTriggerService.swift  # Intraday pre-call briefing catcher: on a new work-calendar meeting during 09:00–17:00, spawns headless `claude` running the derived skill (delivery via Slack `chat.postMessage` + `remctl` for Reminders). Also fires the skill in REMOVED mode when a meeting *disappears* (cancelled/moved) → Slack update; `IntradayBriefGate` gates fire/wait/drop (imminent exemption + started grace), `IntradayDiffClassifier` pairs a move into one reschedule. See docs/INTRADAY-BRIEFINGS.md
├── Views/
│   ├── MenuBarView.swift                 # Window-style popover (event list, meeting load, previews, ad-hoc start)
│   ├── OverlayWindow.swift               # NSPanel wrappers for meeting + break overlays
│   ├── OverlayView.swift                 # Full-screen overlay UI (Join/Snooze/Dismiss)
│   ├── MinimalAlertView.swift            # Lightweight alert UI
│   ├── SettingsView.swift                # 7-tab preferences (General, Alerts, Appearance, Checklist, Calendars, Notion, Integrations). Appearance folds in the old Display tab; Notion has a "Notes"/"Calendar Sync" segmented sub-tab (Cal Sync lives here now); Integrations has an "Availability"/"Busy Light"/"Cal.com" segmented sub-tab. Calendars tab is a two-column table: "Monitor" (enabledCalendarIDs) + "→ Notion" (calendarNotionSyncEnabledCalendarIDs)
│   ├── OnboardingView.swift              # First-launch setup (standalone NSWindow)
│   ├── ContextPanelView.swift            # Floating meeting context panel (attendees, notes, pre-call brief)
│   ├── BriefPanelView.swift              # Pre-call brief panel
│   ├── BusyLightSettingsView.swift       # Busy Light settings tab
│   ├── CalComSettingsView.swift          # Cal.com tab: connection, event types, schedules, upcoming bookings with cancel + reschedule
│   ├── NotionSetupWizardView.swift       # Guided Notion setup wizard (intro → token → share page → provision); shared by Settings → Notion and onboarding
│   ├── ChecklistView.swift               # Pre-meeting checklist panel
│   ├── BreakOverlayView.swift            # Soft full-screen break overlay
│   └── FloatingPromptView.swift          # Non-blocking context-switch prompt
├── Resources/Assets.xcassets             # App icon
│   └── Meeting Busy/Free.shortcut        # Bundled one-click starter Shortcuts for the busy light
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

**Ad-hoc meetings** — `MeetingMonitor.startAdHocMeeting(title:durationMinutes:)` creates a synthetic `MeetingEvent` (id `adhoc-<uuid>`, calendar `"Ad-hoc"`, no video link) and assigns it to `currentMeetingInProgress`. This **deliberately reuses the same publisher** that the OverlayCoordinator subscribes to, so the entire downstream pipeline (show context panel, drive busy light, etc.) runs identically to a calendar-driven meeting. Default title is `"Ad-hoc meeting · HH:mm"` if none supplied. Default duration is 60 min — only used as the calendar-based fallback for end detection; Core Audio silence still ends the meeting earlier in practice.

**OverlayCoordinator** (in `MeetingReminderApp.swift`) — owns all NSPanel window controllers and observes `MeetingMonitor` published state via Combine. Listens for `NSApplication.willTerminateNotification` to close all panels on quit.

**Busy Light** — `BusyLightService` runs a user-chosen macOS Shortcut when you go busy (in a meeting or mic hot) and another when free, driven by `MeetingMonitor.currentMeetingInProgress` + `MeetingMonitor.micActive`. Mic state comes from `AudioProcessMonitor` (per-process input enumeration, macOS 14+), which ignores always-on listeners (Superwhisper, dictation) so the light isn't pinned to Busy. Full detail: [docs/BUSY-LIGHT.md](docs/BUSY-LIGHT.md).

**Availability page** — `AvailabilityPushService` pushes a sanitised free/busy snapshot to Supabase on a timer; a public Vercel/Next.js page (in this monorepo under `availability-page/`) reads it. Full detail: [docs/AVAILABILITY-PAGE.md](docs/AVAILABILITY-PAGE.md).

**Window controllers** — each floating UI element has its own controller class wrapping an `NSPanel`:
- `OverlayWindowController` — meeting overlay (`.screenSaver` level, all screens)
- `BreakOverlayWindowController` — break enforcement overlay
- `ChecklistWindowController` — checklist panel (`.screenSaver - 1` level)
- `ContextPanelWindowController` — meeting context panel (`.floating`)
- `FloatingPromptWindowController` — context-switch nudge (`.floating`)
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
5. **Manual override** — "Done with meeting" button in menu bar dropdown (`monitor.markMeetingDone()`)

### Busy Light (Shortcuts) & Availability page

These are the two external-integration features that replaced Minutes/Obsidian in v3.0.0. Both have their own setup docs; the architecture notes live there:

- **Busy Light** — [docs/BUSY-LIGHT.md](docs/BUSY-LIGHT.md). `BusyLightService` + `AudioProcessMonitor`. Process-aware mic detection (macOS 14+) ignores always-on listeners; extend the ignore set via `busyLightIgnoredAudioBundleIDs`. Bundled starter Shortcuts ship in `Resources/`.
- **Availability page** — [docs/AVAILABILITY-PAGE.md](docs/AVAILABILITY-PAGE.md). `AvailabilityPushService` pushes EventKit free/busy to Supabase (service-role key in Keychain); the public Vercel/Next.js frontend lives **in this monorepo** under `availability-page/` (deploy on Vercel with Root Directory = `availability-page`).
- **Self-service Booking** — Cal.com is the **source of truth for all new bookings** (as of 2026-06-29). Bookers visit `cal.com/adamswbrown/<slug>` (or `book.askadam.cloud/book/<slug>` which redirects there). Cal.com reads the Exchange calendar directly for availability and sends instant confirmation + Teams link — no Mac involvement in the critical path. The availability page (`availability-page/`) links the "Book a call" cards directly to Cal.com. The old Supabase `pending` → Mac confirms loop (`BookingPollService`) is preserved as a legacy fallback but is **disabled whenever `calComAPIKey` is set in Keychain** (gate in `BookingPollService.start()`). The Mac app's `CalComSyncService` polls Cal.com every 5 min + on wake to create local EKEvents (tagged `[calcom-booking-id:<uid>]`) for overlays, busy light, and Notion sync — it detects Exchange-synced duplicates and tags them rather than creating new events. Manage Cal.com event types, schedules, and bookings via **Settings → Cal.com** (API key in Keychain as `calComAPIKey`). Cal.com account: `adamswbrown`. Active event types: `advisory`, `demo`, `partner-intro`, `discovery`, `white-glove` (kickoff), `white-glove-session` (post-kickoff working sessions, direct link only — not on public grid). White Glove automation: Azure Function in `/Users/adambrown/Developer/cal-auto` adds Sandra Murray to all bookings + Luke Lloyd & Joey Undis for `white-glove` slug bookings via Cal.com webhook. Legacy Supabase tables (`booking_event_types`, `booking_requests`, `public_booked_slots`) remain in place but receive no new traffic.

### Calendar → Notion sync

A scheduled feature that pushes Apple Calendar events (Exchange-backed) into a pre-built Notion database called *Calendar Events* (data source `1d605620-3b70-47f1-96d8-465e57fd0bdd`, under the Operations parent page). Becomes the canonical event ledger that downstream automations (e.g. the 07:00 pre-call briefings task) read from. **One-way only** — Notion → Apple is out of scope.

- **Orchestrator** lives in `Services/CalendarNotionSyncService.swift`. Pure-data transformation logic is split out into `CalendarEventMapper.swift` (no EventKit imports — testable with stub structs) and `CalendarSyncTypes.swift` (the `EventLike` protocol, `EKEvent` adapter, logger, constants, skip filter).
- **Identity strategy** — the upsert key is a composite "Apple Event ID":
  - Non-recurring events: bare `calendarItemExternalIdentifier` (the Exchange iCal UID).
  - Recurring occurrences: `<external_id>_<YYYY-MM-DD>` where the date is the occurrence's start time rendered in **Europe/London** local time (so a 23:30 BST meeting doesn't get tagged with tomorrow's UTC date).
  - Synthetic series-master rows: bare `<external_id>` (no date suffix). Emitted once per recurring series so Notion has a single row representing the series definition alongside one row per occurrence in the window. Mapper code: `CalendarEventMapper.expandToRows`.
- **Shared Notion token with `NotionService`** — both use the same Keychain entry `notionAPIToken`. Token management UI lives in the Notion tab; the Cal Sync tab is a consumer that just shows whether a token is set. Originally planned as two separate tokens but collapsed once the user extended their existing integration's permissions to cover the Operations subtree (Calendar Events + Skip List) in addition to the create-meeting-page database.
- **Per-user data source IDs (OOTB, v3.1.0)** — the five Notion data source IDs (`calendarEvents`, `skipList`, `migrations`, `meetingNotes`, `preCallBriefings`) in `CalendarSyncConstants` are now computed vars that resolve a UserDefaults override (`notion*DataSourceID` keys), falling back to the original hardcoded production IDs when unset. `NotionProvisioningService` (driven by `NotionSetupWizardView`) creates a fresh set of databases in any workspace and writes those overrides, so the app works out of the box for anyone — while Adam's existing install, with no overrides set, is byte-for-byte unchanged. See [docs/NOTION-SETUP.md](docs/NOTION-SETUP.md). Settings → Notion → Advanced surfaces a read-only "Currently in use" panel of every resolved ID with Default/Custom badges.
- **Trigger paths**:
  - Daily timer at 06:00 local — scheduled when the app launches if the Settings toggle is on. Single-shot `Timer.scheduledTimer` that re-arms after each fire (no launchd needed; the menu bar app is always running).
  - Menu bar dropdown row "Sync calendar to Notion now" — appears once a token is configured.
  - Settings → "Cal Sync" tab — Sync Now / Dry Run / Open Log buttons + token entry + enable toggle.
  - URL scheme `meetingreminder://calsync` — wired up in `MeetingReminderApp.onOpenURL`. Apple Shortcuts hook: build a Shortcut with one *Open URL* action targeting that URL.
  - Reactive watcher — opt-in via the `calendarNotionSyncReactiveEnabled` toggle. `CalendarChangeWatcher` (owned by `CalendarNotionSyncService`, lifecycle reconfigured at launch via `startScheduleIfEnabled` and whenever the toggle is flipped) observes `.EKEventStoreChanged` and runs `runReactive()` after a 30s debounce, with a 2-min floor between runs to avoid thrashing. Reactive runs use a narrow `now→+30d` window (not the full 90/30), force the orphan sweep off, and skip the rolling-week view patch — they exist only to keep upcoming-meeting rows fresh, not to reconcile the whole ledger. The pre-call-brief pipeline is **not** triggered by a webhook (there is none — an earlier design proposed one but it was never built). Instead the **Daily Pre-Call Briefing** Claude task (ruleset in `breifingskill.txt`) runs on a cloud schedule and reads the Calendar Events DB directly as its primary trigger source (Step 1C) — the app's only job is to keep that DB fresh so a new meeting appears there within ~2 min. `PropertyDiff` gates writes so only genuinely-changed events produce upserts. The 06:00 full run is unaffected. See [docs/plans/2026-07-28-reactive-precall-briefing-trigger-design.md](docs/plans/2026-07-28-reactive-precall-briefing-trigger-design.md) for the planned Mac-app reactive trigger that fires the ruleset the moment a new meeting lands (the scheduled task currently fires only ~3×/day, so same-day meetings booked between runs are missed). **Token-dependence:** `reconfigureWatcher()` gates on `isConfigured`. Saving a token mid-session via the Notion tab calls `calendarNotionSync.startScheduleIfEnabled()` (in `SettingsView.saveAndTestNotion`), which re-runs both `rescheduleDaily()` and `reconfigureWatcher()` — so enabling the reactive toggle before a token exists still activates the watcher the moment the token is saved, no relaunch needed.
- **Window** — 90 days lookback, 30 days lookahead. EventKit expands recurrence automatically via `predicateForEvents`, so each occurrence comes back as its own `EKEvent`.
- **Source calendar resolution** — `CalendarSyncReader.resolveExchangeCalendar()` filters `eventStore.calendars(for: .event)` by `title == "Calendar"` and `source.title == "Exchange"`. If multiple match, ties broken by trailing-30-day event volume. No caching — it's a fast in-memory filter.
- **Skip List** — `CalendarSyncNotionQueries.fetchSkipRules` reads from Notion DS `77164bfd-8536-4c3a-ba3d-701fe64fc9b3` at runtime. Schema: `Meeting Title` (title), `Match Type` (select: "Exact Title" / "Title Contains"), `Active` (checkbox). Filter applied in `MeetingMonitor`-style: matches are dropped from the upsert pipeline entirely. Sharing the rule list with the existing Pre-Call Briefings task avoids drift.
- **Notion API** — `2025-09-03` version. All upserts target the **data source ID**, not the database ID. Backoff: 3 attempts, exponential (0.5s, 1s, 2s), retriable on 429/502/503/504 + transport errors.
- **Log file** — `~/Library/Logs/MeetingReminder/calendar-notion-sync.log`. Rotating at 5 MB (one `.1` backup). Open via Settings button or `tail -f` directly.
- **Rolling-week view auto-patch** — Notion's view DSL only supports absolute date filters, so a "this week" view goes stale every Monday. After each sync run, `CalendarNotionSyncService.patchRollingWeekViewIfConfigured` recomputes Mon–Sun in Europe/London and PATCHes `/v1/views/{id}` with `{filter: {and: [{property: "Date", date: {on_or_after: "..."}}, {property: "Date", date: {on_or_before: "..."}}]}}`. View ID stored in `calendarNotionRollingWeekViewID` UserDefaults. Skipped on dry-run. Manual "Patch now" button in Settings runs only the patch (no full sync).
- **Schema migrations** — `Services/CalendarSyncMigrations.swift` runs at the top of every `runNow` (before upserts) and is gated by a Notion log database (DS `7590658a-f038-45c1-b6ca-d50b2421b0c4`). Each `Migration` has a stable `id`, a description, and a closure that mutates the DS schema via `PATCH /v1/data_sources/{id}`. Helpers like `ensureSelectColumn` are idempotent — re-running an already-applied migration is a safe no-op even if the log entry was deleted. Failures abort the sync run; refusing to write against a half-migrated schema is safer than silently dropping new properties. Dry-run logs the migrations that *would* apply but doesn't mutate. Registered to date: `001-add-sync-state-column`, `002-add-source-calendar-column`, `003-add-availability-column`.
- **Multi-calendar** — `CalendarSyncReader.enabledCalendars()` reads `calendarNotionSyncEnabledCalendarIDs` (a Settings list of opted-in `EKCalendar` identifiers) and returns the matching calendars. When the list is empty, `runNow` falls back to the single Exchange "Calendar" via `resolveExchangeCalendar()` so v1 behaviour is preserved on first launch after upgrade. Each row carries its source calendar's display name through the pipeline as a third tuple element `(event, isSeriesMaster, sourceCalendarName)`. `CalendarSyncReader.notionCalendarName(for:)` maps the Exchange calendar to the legacy `"Calendar (Exchange)"` label and uses the EKCalendar title for everything else — Notion's `Calendar` and `Source Calendar` select columns auto-create new options on write. The orphan-detection set is global across all opted-in calendars in a single run, so events present on calendar A aren't false-archived just because they're missing from calendar B.
- **Availability column + OOO heuristic** — every row writes an `Availability` select (Busy / Free / Tentative / OOO / Unknown) derived from `EKEvent.availability` (`EKEventAvailability` raw values 1–4). EventKit's Exchange bridge often returns `.notSupported` (rawValue 0) for events that *are* OOO at the Exchange end (verified 2026-04-29 against an "Annual Leave" all-day block — Exchange's free/busy bit is dropped at the bridge layer; there's no API to recover it). When `.notSupported`, `CalendarEventMapper.looksLikeOOO` falls back to a title heuristic matching: `annual leave / out of office / out-of-office / ooo / on leave / pto / vacation / holiday / sick leave / off work / off sick`. Hits become `OOO`, everything else `Unknown`. The `calendarNotionSyncSkipFreeAndOOO` opt-in toggle drops `.free` and OOO rows before upsert.
- **Orphan sweep (B2)** — opt-in via `calendarNotionSyncArchiveOrphans`. After upserts, any row in `existing.keys - touched` **whose event date falls inside the run's fetch window** is classified: rows with manual `Meeting Notes` or `Pre-Call Briefing` populated → `Sync State = Stale`; otherwise → `Sync State = Orphaned`. The sweep deliberately does **not** set `archived: true` — Notion's data-source query never returns trashed pages (verified live 2026-07-18), so an archived row would be invisible to `fetchExistingEvents` and a returning event would CREATE a duplicate instead of reviving. Orphaned/Stale rows stay queryable; hide them in views by filtering on `Sync State`. Rows already in their target state are skipped (no re-PATCH churn), and a row that comes back from the calendar diffs on `Sync State` and is revived to `Active` by the normal UPDATE path.
- **Auto-link Meeting Notes / Pre-Call Briefings (B1)** — opt-in via `calendarNotionSyncAutoLinkRelations`. After each upsert, rows whose `Meeting Notes` and/or `Pre-Call Briefing` columns are empty become candidates. `Services/RelationLinker.swift` queries the corresponding Notion DS server-side with an `and` filter (`title contains <event title>` AND date `on_or_after` / `on_or_before` the event's start day in Europe/London), then re-filters locally to **exact case-insensitive title equality** so a "Sync" event can't grab "Sync with Bob". Exactly 1 hit → PATCH the relation column on the Calendar Events row (Notion auto-mirrors the inverse `Calendar Event` relation onto the MN/PCB row). 0 hits = no-op. >1 hits = ambiguous, skipped, both pageIDs logged. Append-only: rows with manual relations are filtered out at target-collection time inside the upserter — `ExistingRow.hasMeetingNotesLink` / `hasPreCallBriefingLink` are checked per-column. Schema (verified 2026-04-29): Meeting Notes uses title=`Title`, date=`Start`; Pre-Call Briefings uses title=`Meeting Title`, date=`Date & Time`.
- **Status cascade (cancellations/reschedules)** — default-ON via `calendarNotionSyncCascadeStatus`, decoupled from the off-by-default `calendarNotionSyncArchiveOrphans`. Pure decision logic lives in `Services/CalendarSyncCascade.swift` (`classifyDisappearance`, `isRecurringAppleID`, `isCancelledStatus`, `startChanged`, `briefPageID`), unit-tested in `CalendarSyncCascadeTests`. **Cancellation:** a row that was `Active`, is now absent from the calendar fetch, and whose date is in-window is stamped `Status = Cancelled` + `Sync State = Orphaned`; if it links a Pre-Call Briefing, that brief's `Meeting Outcome` is set to `Cancelled`. The write is transition-only (guarded on the row not already being `Cancelled`) so the brief PATCH fires exactly once even though Orphaned rows stay queryable. Rows carrying manual relations go `Stale` and are **never** marked Cancelled. **Reschedule:** in the UPDATE path, when a one-off meeting's start moves (`startChanged`, ≥60s), the new start/end is pushed onto the linked brief's `Date & Time` (Europe/London ISO8601). **Recurring safety:** reactive runs skip recurring occurrences (a moved occurrence vanishes from EventKit like a cancellation — the reactive window can't disambiguate), so they're deferred to the 06:00 full run; the reschedule cascade also excludes recurring appleIDs to avoid rewriting a prior occurrence's brief. `ExistingRow.preCallBriefingPageID` carries the linked brief's pageID (read from the relation payload — no extra Notion query). Wired into `CalendarSyncUpserter.processOrphans` + the UPDATE branch; the orphan pass now runs when `archiveOrphans || cascadeStatus`. Coexists with the intraday skill's REMOVED path — both writes are idempotent and converge.
- **Duplicate detection** — `fetchExistingEvents` builds an `appleID → ExistingRow` map and a separate `[String: [String]]` duplicates list when the same `Apple Event ID` appears on more than one row. Canonical pageID is deterministic: prefer non-archived, then first-seen. Run summary surfaces `duplicates=N` when any are present, and the Settings "Scan Duplicates" button runs the same query read-only and writes the result to `lastResult`. Archived rows are included in the lookup so a previously-archived row that comes back from the calendar gets PATCHed (with `archived: false`) instead of duplicating.
- **Things this deliberately does not do**:
  - No deletion of Notion rows. Archive (B2) is reversible; rows with manual relations are marked Stale, not archived.
  - No automatic resolution of duplicate rows — the Scan reports them; the user decides which to archive.
  - No bidirectional sync.

### Sandbox
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO` in both Debug and Release configs). Required because the app shells out to user tooling (e.g. `shortcuts run`, `shortcuts list` for the busy light) and arbitrary binaries — fundamentally incompatible with the macOS sandbox, which grants no execute permission for unsigned third-party processes. Security-scoped bookmarks don't help here.
- The entitlements file declares `com.apple.security.network.client = true` (used by the Notion + Supabase HTTP integrations) and explicitly sets `com.apple.security.app-sandbox = false`.
- **Hardened runtime** is enabled for notarized release builds (commit `18040af`); keep it on or notarization fails.

### Settings & Persistence
- **`@AppStorage`** for simple preferences
- **JSON-encoded UserDefaults** for `defaultChecklist` (array of `ChecklistItem`)
- **Keychain** — `KeychainHelper` (`Services/KeychainHelper.swift`) stores secrets: `notionAPIToken` (Notion), `supabaseServiceRoleKey` (availability push + booking poll), and `msGraphRefreshToken` (Exchange booking-email sending via Graph). See Keychain keys table below.
- **OverlayBackground enum** — stores background choice as string in `@AppStorage("overlayBackground")`, returns `AnyShapeStyle` for use in overlay

---

## Settings (UserDefaults keys)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hasCompletedOnboarding` | Bool | false | Onboarding finished — skip on next launch |
| `reminderMinutes` | Int | 5 | Minutes before meeting to show the full-screen overlay (1/2/3/5/10/15). Configured in **Alerts** tab → "Full-Screen Overlay" |
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
| `snoozeUntil10Enabled` | Bool | false | Show "10 min before" snooze-until button on the overlay (issue #13) |
| `snoozeUntil5Enabled` | Bool | true | Show "5 min before" snooze-until button |
| `snoozeUntil2Enabled` | Bool | true | Show "2 min before" snooze-until button |
| `snoozeUntil0Enabled` | Bool | true | Show "Until start" snooze-until button |
| `screenDimmingEnabled` | Bool | false | Gradual brightness reduction (off by default) |
| `breakEnforcementEnabled` | Bool | true | Break overlay between back-to-back meetings |
| `contextSwitchPromptMinutes` | Int | 3 | Minutes before meeting for context-switch nudge |
| `defaultChecklist` | Data (JSON) | defaults | Pre-meeting checklist items |
| `busyLightBusyEnabled` | Bool | true | Run the Busy shortcut on the rising edge (busy) |
| `busyLightFreeEnabled` | Bool | true | Run the Free shortcut on the falling edge (free) |
| `busyLightBusyShortcut` | String | "" | Name of the Shortcut to run when busy |
| `busyLightFreeShortcut` | String | "" | Name of the Shortcut to run when free |
| `busyLightIgnoredAudioBundleIDs` | [String] | [] | Extra bundle IDs to ignore for mic detection (Superwhisper/dictation covered by default) |
| `availabilityPushEnabled` | Bool | false | Enable the availability free/busy push to Supabase |
| `supabaseProjectURL` | String | "" | `https://<ref>.supabase.co` for the availability push |
| `availabilityPushIntervalMinutes` | Int | 5 | Availability push cadence |
| `availabilityPushWindowDays` | Int | 14 | Days forward to snapshot for availability |
| `bookingPollEnabled` | Bool | false | Enable the 60s booking-confirmation poll loop (`BookingPollService`). Reuses `supabaseProjectURL` + `supabaseServiceRoleKey`. Toggle in Settings → Availability tab |
| `calendarNotionSyncEnabled` | Bool | false | Enable the daily 06:00 Calendar→Notion sync timer |
| `calendarNotionSyncLastRunAt` | Date | nil | Timestamp of the last sync attempt (success or failure) |
| `calendarNotionSyncLastResult` | String | nil | Single-line summary of the last sync (e.g. `created=12 updated=180 skipped=4 failed=0`) |
| `calendarNotionRollingWeekViewID` | String | "" | Optional Notion view UUID to PATCH each run with the current Mon–Sun bracket |
| `calendarNotionSyncArchiveOrphans` | Bool | false | Opt-in: archive Notion rows whose source calendar event has disappeared (B2) |
| `calendarNotionSyncEnabledCalendarIDs` | [String] | [] | Opt-in list of EKCalendar IDs to sync. Empty = fall back to single Exchange calendar (B4) |
| `calendarNotionSyncSkipFreeAndOOO` | Bool | false | Opt-in: drop `.free` and OOO events before upsert |
| `calendarNotionSyncAutoLinkRelations` | Bool | false | Opt-in: auto-link Meeting Notes & Pre-Call Briefings on unambiguous title+day match (B1) |
| `calendarNotionSyncReactiveEnabled` | Bool | false | Opt-in: watch the calendar stream and reactively sync changed events (now→+30d window) within ~2 min, in addition to the 06:00 full run |
| `calendarNotionSyncCascadeStatus` | Bool | true | Cascade cancellations/reschedules into Notion: row `Status=Cancelled`/`Sync State=Orphaned` + linked brief `Meeting Outcome=Cancelled`; a one-off move re-dates the brief. Only flips status metadata, never archives. Independent of `calendarNotionSyncArchiveOrphans` |
| `notionCalendarEventsDataSourceID` | String | "" | Per-user Calendar Events data source ID (set by guided setup). Empty ⇒ fall back to built-in default |
| `notionSkipListDataSourceID` | String | "" | Per-user Skip List data source ID. Empty ⇒ built-in default |
| `notionMigrationsDataSourceID` | String | "" | Per-user Cal Sync Migrations data source ID. Empty ⇒ built-in default |
| `notionMeetingNotesDataSourceID` | String | "" | Per-user Meeting Notes data source ID (sync auto-link). Empty ⇒ built-in default |
| `notionPreCallBriefingsDataSourceID` | String | "" | Per-user Pre-Call Briefings data source ID (sync auto-link). Empty ⇒ built-in default |
| `msGraphConnectedEmail` | String | nil | Display-only email of the connected Exchange account for booking email (set after a successful `GraphMailService` device-code sign-in) |

### Keychain keys

| Key | Purpose |
|-----|---------|
| `notionAPIToken` | Single Notion integration token used by both `NotionService` (create-meeting-page) and `CalendarNotionSyncService` (Cal Sync). The integration must have access to all the relevant databases — including the Operations parent page where Calendar Events + Skip List live. |
| `supabaseServiceRoleKey` | Supabase service-role key. Shared by `AvailabilityPushService` (writes free/busy rows) **and** `BookingPollService` (reads/PATCHes `booking_requests`). Write key — bypasses RLS; never reaches the browser. See [docs/AVAILABILITY-PAGE.md](docs/AVAILABILITY-PAGE.md) and [docs/BOOKING.md](docs/BOOKING.md). |
| `msGraphRefreshToken` | OAuth refresh token for sending booking email from Exchange via Microsoft Graph (`GraphMailService`). Obtained via the device-code flow (delegated `Mail.Send`, public Graph CLI client, no admin). Exchanged for a short-lived access token per send; rotated on each refresh. Connect/disconnect in Settings → Availability → "Exchange sending". |

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

This creates a synthetic `MeetingEvent` with calendar `"Ad-hoc"`, no video link, and no attendees. Setting `currentMeetingInProgress` triggers the Combine sink in `OverlayCoordinator.startObserving()` which fires the *exact same downstream pipeline* as a calendar-driven meeting (context panel opens, busy light flips to Busy, etc.).

The 60-minute duration is only consumed by the calendar-end-time fallback in `checkMeetingEnded`. In practice the Core Audio 30-second silence debounce ends ad-hoc meetings well before the duration expires.

### Testing onboarding

```bash
defaults write com.meetingreminder.app hasCompletedOnboarding -bool false
```

Then click the menu bar icon — onboarding will appear in a standalone window.

---

## Releasing & CI

Full process in [docs/RELEASING.md](docs/RELEASING.md). Key facts (learned the hard way):

- **Releases are CI-driven by a tag push** — `git tag -a vX.Y.Z -m "..." && git push mine vX.Y.Z` triggers `.github/workflows/release.yml` to build → sign → notarize → DMG → publish a GitHub Release. **No local build needed**; do NOT build/upload by hand.
- **`gh` defaults to the `nilBora` upstream**, not the fork. ALWAYS pass `-R adamswbrown/meeting-reminder` to `gh release`/`gh run`/`gh secret`/`gh pr`.
- **CI runs on `macos-15` with `maxim-lobanov/setup-xcode@v1` `latest-stable`** (Xcode 26.3 as of v3.0.0). Do NOT pin an old Xcode — the code uses Swift 6.x region-based concurrency that Xcode 15.4 rejects with "reference to captured var 'self'" errors.
- **6 GitHub secrets** drive signing/notarization on the fork: `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `NOTARIZATION_APPLE_ID`, `NOTARIZATION_PWD`, `KEYCHAIN_PASSWORD` (Team ID `NZ87XY99SR` is auto-extracted). Set as of v3.0.0.
- **The DMG must be notarized before stapling** — the release step submits the DMG to notarytool (not just the `.app`), else `stapler` fails "Record not found / Error 65".
- **Release notes** come from the matching `## [VERSION]` section of `CHANGELOG.md` (extracted to `RELEASE_NOTES.md` in CI), with GitHub's auto PR-list appended.
- **Manual pbxproj edits MUST use globally-unique object IDs.** An ID collision between branches (e.g. `A1000052` reused for two files) compiles-fail silently with "cannot find X in scope". Mirror an existing file's 4 entries (PBXBuildFile / PBXFileReference / group children / Sources phase) with a fresh ID.

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
