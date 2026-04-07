<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Meeting Reminder icon">
</p>

<h1 align="center">Meeting Reminder for Mac</h1>

<p align="center">
A native macOS menu bar app built for people who lose track of time. Reads your calendar, shows a live countdown in the menu bar, escalates alerts progressively, and displays a full-screen blocking overlay before meetings — with one-click video conference join. Detects Zoom, Google Meet, Teams, Webex, and Slack links automatically.
</p>

<p align="center">
<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift"> <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

## Credits

This project was originally inspired by [In Your Face](https://www.inyourface.app), a fantastic Mac app that pioneered the full-screen meeting overlay concept. Meeting Reminder started as a free, open-source alternative and has since evolved with ADHD-focused features, progressive alerts, Notion integration, and meeting-end detection that go beyond the original inspiration. If you want a polished, commercial solution — In Your Face is excellent and worth supporting.

## Features

### Core
- **Full-screen overlay** on all screens at a configurable time before meetings (1–10 min)
- **Video link detection** — Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddle from event notes, URL, or location
- **One-click join** — press Join or hit Enter to open the meeting link
- **Snooze & dismiss** — micro-snooze (30 seconds) and standard snooze (1 minute), or dismiss with Escape
- **Menu bar app** — no Dock icon; lives entirely in the menu bar
- **Multiple calendars** — iCloud, Google, Exchange, or any calendar synced to macOS; choose which to monitor
- **Customisable backgrounds** — 9 overlay themes (Dark, Blue, Purple, Sunset, Red, Green, Night Ocean, Electric, Cyber)
- **Launch at login** — auto-start via macOS native API
- **Privacy-first** — all data stays on your Mac; no third-party analytics or tracking

### Time Blindness Support
- **Persistent menu bar countdown** — shows `"Standup in 12m"` directly in the menu bar. Updates every 10 seconds when close. No clicking required.
- **Colour-coded menu bar icon** — shifts from green → yellow → orange → red based on proximity to next meeting. Changes SF Symbol shape per tier for accessibility.
- **Colour-blind friendly mode** — alternative palette (blue/cyan/orange/magenta) avoiding the red-green axis, with distinct icon shapes per urgency level.
- **Wrap-up nudge** — menu bar text changes to `"Wrap up — Standup in 12m"` at a configurable threshold (default 10 min).

### Progressive Alerts
Instead of a single reminder, alerts escalate with increasing urgency:

| Time Before | Alert | Behaviour |
|-------------|-------|-----------|
| 15 min | Ambient | Menu bar turns yellow |
| 10 min | Banner | System notification: "Start wrapping up" |
| 5 min | Urgent | Menu bar turns orange, optional chime |
| 2–3 min | Blocking | Full-screen overlay (must interact) |
| 0 min | Last chance | Overlay re-fires if not dismissed |

Each tier is independently configurable in Settings.

### Hyperfocus Interruption
- **Micro-snooze (30 seconds)** — overlay returns quickly, making it harder to fall back into hyperfocus
- **Gentle screen dimming** — gradually reduces brightness to 70% over 5 minutes before a meeting. Linear transitions only, respects Reduce Motion, off by default. Safety-first.
- **Context-switch prompt** — a non-blocking floating message: "Save your work — you need to switch in 3 minutes." Stays visible but doesn't block interaction.

### Transition Support
- **Pre-meeting checklist** — a movable checklist panel appears alongside the overlay (e.g., "Close tabs", "Get water", "Open notes"). Fully customisable in Settings.
- **Meeting context panel** — a floating, semi-transparent panel showing title, time, attendees, agenda, and a clickable video link. Stays on screen during meetings.

### Meeting Fatigue & Overload
- **Daily meeting load indicator** — menu bar dropdown shows: "6 meetings today (4.5h)", "3 back-to-back", "Next break: 2:30 PM"
- **Break enforcement** — when back-to-back meetings are detected (< 5 min gap), a gentle full-screen break overlay appears between them with stretch/water/breathe suggestions. Skippable.

### Meeting End Detection
Detects when a meeting has ended using three layered signals:

1. **Core Audio monitoring** (primary) — detects when the microphone goes idle for 30+ seconds (debounced to avoid false triggers during screen-share transitions)
2. **Video app lifecycle** (secondary) — watches for Zoom, Teams, Webex, or Slack quitting via `NSWorkspace` notifications
3. **Calendar end time** (fallback) — uses the event's scheduled end time as a backstop
4. **Manual override** — "Done with meeting" button in the menu bar dropdown

### Notion Integration
- **Database connection** — configure your Notion Meeting Notes database in Settings (API token stored in Keychain)
- **Auto-create meeting page** — when the reminder fires, creates a page with title, date, attendees, agenda, video link, and empty Notes/Action Items sections. Opens in your browser automatically.
- **Post-meeting nudge** — 5 minutes after a meeting ends, a floating prompt asks "Capture action items?" with a button to open the Notion page.
- **Action item pull** — surfaces to-do items from the Notion page in the post-meeting nudge.

### Onboarding
First-launch setup assistant walks through permissions step by step:
1. Calendar access (required)
2. Notifications (recommended, for progressive alert banners)
3. Each step explains *why* before asking, shows live grant status, and allows skipping optional items.

## Screenshots

![Full-screen overlay with countdown and Join button](docs/screenshots/lock-screen.png)

<details>
<summary>Preferences</summary>

| General | Appearance | Calendars |
|---------|------------|-----------|
| ![General](docs/screenshots/preference-general.png) | ![Appearance](docs/screenshots/preference-appearance.png) | ![Calendars](docs/screenshots/preference-calendar.png) |

</details>

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build)
- Calendar access permission
- Notification permission (optional, for banner alerts)

## Installation

### Build from Source

```bash
git clone https://github.com/your-username/meeting-reminder.git
cd meeting-reminder
open MeetingReminder.xcodeproj
```

Then press **Cmd+R** in Xcode to build and run.

### Command Line Build

```bash
xcodebuild -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/`.

## Usage

1. Launch the app — a calendar icon with countdown text appears in the menu bar
2. Grant calendar access when prompted (onboarding walks you through this)
3. The menu bar shows a live countdown to your next meeting, colour-coded by urgency
4. Progressive alerts escalate as the meeting approaches
5. A full-screen overlay appears with Join, Snooze (30s / 1 min), and Dismiss buttons
6. After the meeting, a nudge prompts you to capture action items

## Configuration

Open **Preferences** from the menu bar dropdown:

| Tab | Settings |
|-----|----------|
| **General** | Reminder time (1–10 min), sound, colour-blind mode, launch at login, re-run setup |
| **Alerts** | Progressive alert tiers (toggle each), wrap-up threshold, context-switch prompt timing, break enforcement, screen dimming |
| **Appearance** | 9 overlay background themes |
| **Checklist** | Add/remove/reorder pre-meeting checklist items |
| **Calendars** | Select which calendars to monitor |
| **Notion** | API token, database ID, test connection |

## Project Structure

```
MeetingReminder/
├── MeetingReminderApp.swift              # App entry, MenuBarExtra, OverlayCoordinator, onboarding
├── Models/
│   ├── MeetingEvent.swift                # Meeting data model (attendees, notes, location)
│   └── ChecklistItem.swift              # Pre-meeting checklist data model
├── Services/
│   ├── CalendarService.swift            # EventKit: access, fetch, filter, meeting stats
│   ├── MeetingMonitor.swift             # Progressive alerts, break detection, audio monitoring
│   ├── VideoLinkDetector.swift          # Conference URL parser (regex)
│   ├── AlertTier.swift                  # Alert tier definitions + MenuBarUrgency enum
│   ├── NotificationService.swift        # UNUserNotificationCenter wrapper
│   ├── ScreenDimmer.swift               # IOKit brightness control (gradual dimming)
│   └── NotionService.swift              # Notion API client + Keychain storage
├── Views/
│   ├── MenuBarView.swift                # Menu bar dropdown (meeting load, event list, done button)
│   ├── OverlayWindow.swift              # NSPanel wrappers (meeting + break overlays)
│   ├── OverlayView.swift                # Full-screen overlay (micro-snooze, attendees)
│   ├── SettingsView.swift               # 6-tab preferences (General, Alerts, Appearance, Checklist, Calendars, Notion)
│   ├── OnboardingView.swift             # First-launch setup assistant
│   ├── ContextPanelView.swift           # Floating meeting context panel
│   ├── ChecklistView.swift              # Pre-meeting checklist panel
│   ├── BreakOverlayView.swift           # Break enforcement overlay
│   ├── FloatingPromptView.swift         # Context-switch prompt
│   └── PostMeetingNudgeView.swift       # Post-meeting action item nudge
├── Resources/Assets.xcassets             # App icon
├── Info.plist
└── MeetingReminder.entitlements          # Sandbox + calendar + network
```

## Supported Video Platforms

| Platform | URL Pattern |
|----------|-------------|
| Zoom | `zoom.us/j/...` |
| Google Meet | `meet.google.com/...` |
| Microsoft Teams | `teams.microsoft.com/l/meetup-join/...` |
| Webex | `*.webex.com/...` |
| Slack Huddle | `app.slack.com/huddle/...` |

Links are detected in the event's URL, notes, and location fields.

## Roadmap

Features planned but not yet implemented (Phase 4 from the [ADHD Features Roadmap](docs/ADHD-FEATURES-ROADMAP.md)):

- [ ] **"What Was I Doing?" bookmark** — capture the frontmost app and window title when joining a meeting, then nudge the user to return to it afterwards. Requires Accessibility permission; degrades gracefully to app name only without it.
- [ ] **Decline assist** — flag likely-optional meetings (large attendee lists, "optional" / "FYI" in invite text) and surface a "Decline with template" button with pre-written responses. Blocked by EventKit limitation (can't programmatically decline); v1 would copy template to clipboard.
- [ ] **Per-calendar checklist overrides** — different pre-meeting checklists for different calendar types (e.g., 1:1s vs all-hands).
- [ ] **Notion AI summary surfacing** — if Notion AI has generated meeting notes, pull the summary into the post-meeting nudge rather than just linking to the page.
- [ ] **Multi-monitor screen dimming** — current dimming targets the primary display only; extend to all connected displays with per-display brightness control.
- [ ] **Overlay theming by urgency** — automatically shift overlay background colour based on how late the alert is (e.g., warmer tones when the meeting has already started).

See [docs/ADHD-FEATURES-ROADMAP.md](docs/ADHD-FEATURES-ROADMAP.md) for the full feature roadmap and design rationale.

## License

MIT
