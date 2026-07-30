# Changelog

All notable changes to Meeting Reminder will be documented in this file.

## [3.4.0] - 2026-07-30

### Added
- **Slack updates when a meeting is removed or moved during the day** — the intraday catcher now watches for meetings that *disappear* from your work calendar, not just new ones. When a meeting is cancelled or rescheduled between the scheduled cloud runs, the app fires the briefing skill in a new **REMOVED mode** and posts a single change-alert to `#daily-breifings`.
  - A removal is only a meeting that was present, is now absent, **and still starts in the future** — a meeting that merely *started* is never mistaken for a cancellation.
  - A reschedule (a same-title meeting vanishing at one time and reappearing at another) is paired into **one `🔁 moved` post** rather than a `❌ cancelled` *and* a `🆕 new meeting` (new `IntradayDiffClassifier`).
  - The skill re-derives cancel-vs-moved **authoritatively** from the Outlook ICS + Notion (never trusting the app's guess), updates the Notion row/brief (`Meeting Outcome = Cancelled`, or the brief's new `Date & Time`), and never briefs or creates a page in this mode.
  - Removals share the briefing queue's debounce, floor, working-hours gate, and single-in-flight guard (only ever one `claude` at a time), with their own persisted dedup set (`preCallBriefRemovalFiredIDs`). Rides on the existing **"Auto-brief new meetings during the day"** toggle — no new setting. Full detail: [docs/INTRADAY-BRIEFINGS.md](docs/INTRADAY-BRIEFINGS.md).

### Fixed
- **Meetings starting at the 09:00 boundary were never briefed** — a meeting booked that morning for a 09:00 start fell into a dead zone: before 09:00 the working-hours gate deferred it to 09:00, and at 09:00 the "already-started" drop discarded it before it could fire. A new `IntradayBriefGate` decides fire/wait/drop per meeting: an **imminent** meeting (one starting before the next working-window opens) is briefed now even outside hours, while a non-imminent early booking still waits for 09:00; the already-started drop gains a 5-minute grace so a boundary meeting isn't lost in the detection→debounce→drain race.
- **Cancelled meetings lingered in the menu bar** — an organiser-cancelled Exchange meeting is not deleted from the local store; it stays as a `.canceled` event (struck-through in Calendar.app) and was never filtered, so it kept showing in the menu bar and driving alerts, overlays, and the busy light. `CalendarService` now excludes cancelled events (alongside all-day and declined) via a new pure, unit-tested `CalendarEventInclusion` predicate.

## [3.3.0] - 2026-07-29

### Added
- **Intraday pre-call briefings** — an opt-in catcher that briefs a **new meeting the moment it lands in your work calendar during the day (09:00–17:00, Mon–Fri)**, instead of waiting for the next scheduled cloud run. It's the local counterpart to the scheduled "Co Work" Daily Pre-Call Briefing task: when a genuinely-new meeting appears, the app spawns a headless `claude` run of a derived briefing skill that researches the meeting (prior history, attendees, White Glove/Jira context) and writes the briefing — following the *same rules* as the scheduled task — then sends a short change-alert.
  - **How it fires** — keys off EventKit (`CalendarService`'s always-live `.EKEventStoreChanged`), independent of the Notion sync toggle. Baseline-seeds the current diary at launch (no launch storm), then debounces 30s, floors runs at 120s, runs serially, and remembers what it's already briefed. Zero idle cost — it only runs when a new meeting actually appears. Only meetings on your **monitored** calendars qualify.
  - **macOS notifications** — a standard banner fires the moment a new meeting is detected ("🆕 New meeting detected — generating a pre-call briefing for …"), then updates in place to the outcome ("✅ Pre-call briefing ready" or a warning if it degraded).
  - **Generation transcript saved to Notion** — each run appends a collapsible **🧠 Generation Log** toggle to the briefing page recording what the agent did: the sources it queried, what it found, how it resolved the customer/partner and White Glove/Jira, and the delivery outcome — so every automated briefing is reviewable after the fact.
  - **Divergent delivery by design** — the cloud task keeps its own delivery; the app path delivers through local CLIs (`imessage-tools` for the iMessage alert, `remctl` for Reminders) because those are reachable from a headless spawn where interactively-authenticated integrations are not. The two runners share the same Notion databases + action-item hashes, so neither double-briefs.
  - **Setup** — off by default. Enable under **Settings → Notion → Calendar Sync → "Auto-brief new meetings during the day"**. A **"Grant permissions…"** button triggers the macOS **Automation (Messages)** and **Reminders** consent prompts (those System Settings panes have no “+”, so an app can only be added by requesting access programmatically); Full Disk Access is added manually. Full guide: [docs/INTRADAY-BRIEFINGS.md](docs/INTRADAY-BRIEFINGS.md).
  - New `PreCallBriefTriggerService`; new `preCallBriefTriggerEnabled` / `preCallBriefCLIPath` / `preCallBriefSkillPath` / `preCallBriefMinIntervalSeconds` / `preCallBriefFiredIDs` UserDefaults keys; `NSAppleEventsUsageDescription` + `NSRemindersFullAccessUsageDescription` + the Apple-events hardened-runtime entitlement.

## [3.2.2] - 2026-07-22

### Fixed
- **Crash during window layout** — floating panels that host SwiftUI (meeting overlay, break overlay, context panel, pre-call brief, checklist, floating prompt, minimal alert, and the onboarding window) could crash the app with an uncaught `NSException` from `-[NSWindow _postWindowNeedsUpdateConstraints]`. Each panel set its `NSHostingView` as the window's content view without disabling content-driven window sizing, so when the hosted content resized after appearing (e.g. a pre-call brief loading from Notion, or advancing an onboarding step) the hosting view re-invalidated the window's constraints mid-display-cycle and AppKit trapped. All eight panels now set `NSHostingView.sizingOptions = []`; the panels are explicitly framed so nothing else changes.

## [3.2.1] - 2026-07-18

**AI Bug Fix** — a full-codebase AI review found and fixed 30+ bugs across the meeting engine, Notion sync, booking, and UI layers.

### Fixed
- Quitting Chrome no longer ends an in-progress meeting (stray bundle ID in the video-app quit watcher).
- The "Full overlay" and "Last chance" alert toggles now work — the overlay respects its tier toggle, and the last-chance re-fire at meeting start is actually implemented.
- Expired snoozes near meeting start re-fire the overlay instead of being silently swallowed; midnight no longer wipes alert state for imminent meetings or re-fires dismissed ones; meetings shortly after midnight now get advance alerts.
- Overlay previews no longer auto-dismiss after 10 seconds; screen dimming restores when you dismiss without joining and can no longer brighten a dark screen.
- ⌘, (Settings) works on macOS 14+; "Re-run Setup Assistant" window closes properly; onboarding no longer dead-ends when calendar access was denied.
- Busy light: no more spurious "Free" shortcut run ~30s after launch; rapid busy/free flips can't race the light into the wrong state.
- Calendar → Notion sync: the orphan sweep only classifies rows inside the fetch window (no more archiving of >90-day history) and no longer trashes pages at all — orphans are marked `Sync State = Orphaned` and revive automatically if the event returns (Notion's query API never returns trashed pages, so archiving made revival impossible). Reactive runs no longer churn series-master rows or self-retrigger via EventKit echoes; a busy 06:00 run retries instead of skipping the day; three unpaginated Notion queries (brief bodies, brief lookup, relation candidates) now follow cursors.
- Cal.com: cancel uses the correct v2 route (`POST /bookings/{uid}/cancel`); sync waits out Exchange lag before creating local events (no more duplicates); title matching is prefix-based and cancellation only deletes events the app itself created.
- Booking (legacy path): conflict check ignores all-day/free events (holidays no longer block bookings); the recovery path sends the confirmation email it used to skip; booker emails are validated against CRLF injection in the .ics and Mail composer.
- Keychain writes are update-first — a failed write can no longer destroy a stored token (Graph refresh token, Notion/Supabase/Cal.com keys).
- Availability push: cancelled in-progress events disappear from the public page; past rows are cleaned up; URLs are properly percent-encoded.
- Video link detection: the link that appears earliest in the notes wins (a footer Webex link can't beat the real Teams link), look-alike domains like `evilzoom.us` are rejected, and trailing punctuation is stripped.

## [3.2.0] - 2026-07-18

### Added
- **Customizable full-screen overlay timing** ([#13](https://github.com/adamswbrown/meeting-reminder/issues/13)) — the overlay lead time now lives in **Settings → Alerts → "Full-Screen Overlay"** and offers **1 / 2 / 3 / 5 / 10 / 15 minutes** before the meeting. Previously it was capped at 10 minutes and tucked away in the General tab labelled "Remind me before meetings". Same `reminderMinutes` setting — nothing to migrate.
- **Snooze until a set time before the meeting** ([#13](https://github.com/adamswbrown/meeting-reminder/issues/13)) — the full-screen overlay and the in-call minimal alert now offer **"Snooze until"** buttons (`10 min` / `5 min` / `2 min` before, or `Start`) alongside the existing 30s / 1 min quick-snooze. Each button holds the overlay until that point relative to the meeting start and re-fires there — so you can snooze to *2 minutes before*, then snooze again to *the start*. Buttons only appear while they're still in the future and drop off as the meeting approaches.
  - Choose which buttons appear in **Settings → Alerts → "Snooze"** — `5 min`, `2 min`, and `Start` are on by default; `10 min` is off.
  - New `SnoozeUntilThreshold` model (unit-tested) reuses the existing snooze plumbing; new `snoozeUntil10Enabled` / `snoozeUntil5Enabled` / `snoozeUntil2Enabled` / `snoozeUntil0Enabled` UserDefaults keys.

### Changed
- **Settings consolidated from 11 tabs to 7** — General, Alerts, Appearance, Checklist, Calendars, Notion, Integrations. Appearance folds in the old Display tab; Calendar Sync moves under a **Notion** "Notes / Calendar Sync" sub-tab; **Availability**, **Busy Light**, and **Cal.com** now share a single **Integrations** tab. The **Calendars** tab is a two-column table — "Monitor" and "→ Notion" — replacing the separate pickers.

### Fixed
- Repaired the test target build — `BookingSupportTests` still called `MailAppleScript.compose()` without the `senderEmail:` argument that the production signature now requires.

## [3.1.0] - 2026-07-18

### Added
- **Guided Notion setup — works out of the box** — a new wizard creates every Notion database the app needs, so you no longer have to hand-build databases or copy IDs. **Settings → Notion → "Set up Notion automatically…"** (also an optional step in first-launch onboarding).
  - You do two things by hand — create a Notion integration and share one page with it — then the app builds five databases under that page with the exact schemas it expects: **Meeting Notes**, **Pre-Call Briefings**, **Calendar Events** (with two-way relations to the first two), **Skip List**, and **Cal Sync Migrations**. On success the wizard links straight to each new database.
  - `NotionProvisioningService` creates the databases via the Notion `2025-09-03` API and wires the app to them; `NotionSetupWizardView` is the shared UI, reused by Settings and onboarding.
  - The five Notion data source IDs are now **per-user** — provisioned installs use their own databases, while existing installs fall back to their current IDs unchanged (no re-provisioning, nothing overwritten). A guard warns before repointing an already-connected workspace.
  - **Settings → Notion → Advanced** now shows a read-only **"Currently in use"** panel listing every ID the app is pointed at, each labelled by purpose with a Default/Custom badge and a copy button.
  - New reference doc: [docs/NOTION-SETUP.md](docs/NOTION-SETUP.md).
- **Cal.com integration** — Cal.com is now the source of truth for all new bookings. Bookers get an instant calendar invite + Teams link with no Mac involvement in the critical path; availability is read directly from the Exchange calendar by Cal.com.
  - `CalComService` — REST wrapper around the Cal.com v2 API (event types, schedules, bookings, cancel). API key stored in Keychain as `calComAPIKey`.
  - `CalComSyncService` — polls Cal.com every 5 minutes + on wake to create local EKEvents tagged `[calcom-booking-id:<uid>]`. Detects Exchange-synced duplicates (title + ±15 min window) and tags them rather than duplicating. Cancellation sweep removes tagged events for cancelled bookings (30-day lookback).
  - **Settings → Cal.com** — new tab for connection, event type list, schedule viewer, and upcoming bookings with cancel action.
  - **Availability page** — "Book a call" cards now link directly to `cal.com/adamswbrown/<slug>` (instant confirmation copy); `/book/<slug>` redirects to Cal.com for old bookmarks. White Glove slugs hidden from the public grid.
  - **White Glove Working Session** (`white-glove-session`) — new Cal.com event type for post-kickoff engagement stages (Deployment Validation, Workshop 1 & 2, Post-Workshop Coaching, Delivery Validation). Accessible via direct link; partner name and session-type selector built in.
  - Cal.com webhook automation updated: Sandra Murray added to all bookings; Luke Lloyd & Joey Undis added for `white-glove` bookings.
- `calComSyncEnabled`, `calComLastSyncedAt`, `calComLastSyncResult` UserDefaults keys.

- **Cal.com → Notion bridge** (`CalComNotionBridge`) — when `CalComSyncService` creates a new EKEvent for a booking, it immediately fires `NotionService.createMeetingPage()` so a meeting-notes page exists before the next 06:00 `CalendarNotionSyncService` run. Deduped by `"calcom-<uid>"` event ID.
- **Reschedule action** in Settings → Cal.com — "Reschedule" button per booking opens a `DatePicker` sheet; confirms via `POST /v2/bookings/{uid}/reschedule` and updates the row in place.
- **White Glove Working Session email template** — intro email now has a single "Working Sessions" section with the `white-glove-session` booking link and a bulleted list of all session types (Deployment, Workshop 1 & 2, Post-Workshop Coaching, Delivery Validation).

### Changed
- `BookingPollService.start()` is now gated — skips entirely when `calComAPIKey` is present in Keychain. The Supabase pending-loop is preserved as a legacy fallback for setups without a Cal.com key.

### Removed
- Dead Supabase booking frontend: `BookingForm.tsx`, `SlotBookingDialog.tsx`, `bookingApi.ts`, `bookingSlots.ts` and their tests. `BookingPage` simplified to always render `SlotActionsDialog` (view-only actions — Outlook/Google/ICS/email/copy).

## [3.0.0] - 2026-06-15

### Added
- **Busy Light via Shortcuts** — a new *Busy Light* tab in Settings drives a HomeKit accessory (or anything else you can do in a Shortcut) automatically when you're in a meeting or your microphone is hot, and again when you're free. Picks the right Shortcut from a dropdown populated by `shortcuts list`, with a 30-second debounce on the falling edge so brief mic drops don't flicker the light.
- **Process-aware mic detection** — the busy light now enumerates per-process audio input (macOS 14+ `kAudioHardwarePropertyProcessObjectList`) instead of the device-wide "is anything using the mic" flag, so always-on listeners like Superwhisper and Apple's dictation/speech daemons no longer pin the light to Busy forever. Default ignore set covers those; extend it via the `busyLightIgnoredAudioBundleIDs` UserDefaults key. Falls back to the device-level check on macOS 13.
- **One-click starter Shortcuts** — two signed `.shortcut` files (*Meeting Busy*, *Meeting Free*) ship bundled in the app. Install buttons in Settings hand them to Shortcuts.app for a one-tap add; bind your bulb on first open. Starters built using [viticci/shortcuts-playground-plugin](https://github.com/viticci/shortcuts-playground-plugin) — credit to Federico Viticci for the toolkit.
- `MeetingMonitor.micActive` is now published so any future integration can react to mic state independently of calendar meetings.
- **Availability page** — opt-in push of a sanitised 14-day free/busy snapshot to Supabase every 5 minutes, so a public Vercel/Next.js page can show "when am I free?" without exposing titles or attendees. New *Availability* tab in Settings (project URL + service-role key in Keychain). Frontend lives in its own repo. See [docs/AVAILABILITY-PAGE.md](docs/AVAILABILITY-PAGE.md).
- **Docs** — setup guides for [Busy Light](docs/BUSY-LIGHT.md) and the [Availability Page](docs/AVAILABILITY-PAGE.md).

### Removed
- **Minutes integration** — local-first transcription via the `minutes` CLI, the live transcript pane, the post-meeting nudge with parsed action items, and the AI prep-brief section of the context panel.
- **Obsidian integration** — the Obsidian vault detection, "Open in Obsidian" buttons, and the Meetings Dashboard installer. Notion is now the single capture story; the context panel still shows attendees, notes, location, and the Notion-fed pre-call brief.
- The Integrations tab and its associated Settings UI.

## [2.1.0] - 2026-05-29

### Added
- **Calendar → Notion sync** — one-way push of Apple Calendar events (Exchange-backed) into a Notion *Calendar Events* database as a canonical event ledger. Includes:
  - Multi-calendar support — opt in to any combination of calendars (falls back to the single Exchange "Calendar" on first launch)
  - Recurring-series expansion — one row per occurrence plus a synthetic series-master row, keyed by a composite Apple Event ID rendered in Europe/London time
  - Availability column with an OOO heuristic for events Exchange reports as unsupported (annual leave, PTO, out-of-office, etc.); optional toggle to skip Free/OOO events
  - Auto-link Meeting Notes & Pre-Call Briefings on an unambiguous title-and-day match (opt-in, append-only — never overwrites manual links)
  - Orphan archive (opt-in) — rows whose calendar event disappears are archived, or marked Stale if they carry manual notes; reversible on the next run
  - Duplicate detection with a read-only "Scan Duplicates" report
  - Rolling-week Notion view auto-patch (recomputes Mon–Sun each run)
  - Idempotent schema migrations gated by a Notion log database
  - Skip List read from Notion at runtime (Exact Title / Title Contains)
  - Triggers: daily 06:00 timer, menu bar "Sync now", Settings tab (Sync / Dry Run / Patch), and `meetingreminder://calsync` URL scheme for Shortcuts
  - Rotating log at `~/Library/Logs/MeetingReminder/calendar-notion-sync.log`
- **Availability push** — publishes a sanitised 14-day free/busy snapshot to Supabase so a public web page can show availability without calendar access; cancellations/reschedules are reconciled on each push
- **Obsidian integration** — detects installed vaults and opens meeting-note markdown via the `obsidian://` URL scheme
- **Reopen pre-call brief** — a brief button on each menu bar event row (and in the in-progress recording section) reopens the in-app pre-call brief if it gets closed, without reopening Notion

### Changed
- Notion API upgraded to the `2025-09-03` data-source model; all sync upserts target data source IDs with retry/backoff on transient errors
- `PreCallBriefService` and `CalendarNotionSyncService` share the single `notionAPIToken` Keychain entry used by `NotionService`

## [2.0.6] - 2026-04-24

### Added
- Restored the Notion pre-call brief flow in the meeting startup pipeline
- Added a configurable "Pre-call briefs database ID" field in Settings -> Notion

### Changed
- Wired the pre-call brief panel into both overlay and direct-join paths so briefs appear when a meeting starts

### Fixed
- Added missing pre-call brief source files to the Xcode target so Release builds compile reliably
- Fixed DMG signing script handling for empty keychain argument expansion under `set -u`

### Distribution
- Published a signed and notarized DMG for v2.0.6

## [2.0.3] - 2026-04-09

### Fixed
- Notion HTTP 400 when calendar notes exceed 2000 characters — long notes are now split into multiple rich_text elements within the same paragraph block
- Attendees rich_text property truncated to 2000 characters to prevent the same Notion validation error on meetings with many participants

## [2.0.2] - 2026-04-09

### Changed
- Auto Minutes recording disabled by default — the Minutes CLI only captures mic input (one side of a call), not system audio. Notion handles full call capture natively, so `autoRecordWithMinutes` now defaults to `false`. Re-enable in Settings → Minutes if needed

## [2.0.1] - 2026-04-09

### Fixed
- Minutes recording not triggering — `detectInstall()` only ran at app launch when the Minutes toggle was already on. Enabling the integration in Settings after launch left `isInstalled = false`, silently skipping recording. The pipeline now lazily detects the CLI when a meeting starts
- Keychain password prompts on every Preferences open — switching between Debug and Release builds changed the code-signing identity, triggering macOS Keychain ACL prompts. Fixed by creating entries with no per-app ACL restriction

### Changed
- Split entitlements files — hardened-runtime exceptions moved to a dedicated release entitlements file

## [2.0.0] - 2026-04-08

### Added
- Notion integration — auto-creates meeting pages in a configured Notion database on meeting join
- Minutes CLI integration — automatic recording, live transcript, and post-meeting nudge with parsed action items
- Progressive alert tiers (ambient, banner, urgent, blocking, last-chance) with per-tier toggles
- Pre-meeting checklist panel
- Context panel with attendees, notes, and AI prep brief
- Break enforcement overlay between back-to-back meetings
- Context-switch floating prompt
- Live transcript pane with in-call coach hints (questions, mentions, commitments)
- Ad-hoc meeting support (no calendar event required)
- Onboarding flow for first launch
- Screen dimming option (IOKit brightness control)
- Colour-blind mode for menu bar
- 7-tab Settings with full configuration

## [1.0.1] - 2026-02-19

### Fixed
- Recurring events not triggering overlay on subsequent days — EventKit returns the same `eventIdentifier` for every occurrence, so the event was incorrectly marked as already shown. Event ID now includes the start date to uniquely identify each occurrence
- Daily cleanup of shown/snoozed event sets to prevent stale state across days

### Improved
- Time until meeting now displays in hours and minutes (e.g. "1 h 30 min") instead of raw minutes for events 60+ minutes away

## [1.0.0] - 2026-02-17

### Initial Release

**Core Features**
- Native macOS menu bar app — runs as a background agent (no Dock icon)
- Reads events from the system calendar via EventKit
- Full-screen blocking overlay appears N minutes before a meeting starts
- One-click "Join" button to open video conference links directly from the overlay
- Snooze and Dismiss controls on the overlay
- Live countdown timer to meeting start

**Video Link Detection**
- Automatic detection of video conference URLs in event notes, location, and URL fields
- Supported services: Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddles

**Menu Bar**
- Window-style popover showing upcoming events for the day
- Quick access to Preferences and Quit

**Settings**
- Configurable reminder time (1, 2, 5, or 10 minutes before meeting)
- Alert sound toggle
- 9 overlay background themes: Dark, Blue, Purple, Sunset, Red, Green, Night Ocean, Electric, Cyber
- Calendar selection — choose which calendars to monitor
- Launch at login support (via SMAppService)

**Technical**
- macOS 13+ (Ventura) support
- Auto-refresh: events update every 5 minutes and on `EKEventStoreChanged` notifications
- Overlay uses `NSPanel` at `.screenSaver` window level — appears above full-screen apps
- App Sandbox with calendar entitlement
