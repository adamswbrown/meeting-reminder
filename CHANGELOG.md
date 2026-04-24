# Changelog

All notable changes to Meeting Reminder will be documented in this file.

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
