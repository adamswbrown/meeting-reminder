# Changelog

All notable changes to Meeting Reminder will be documented in this file.

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
