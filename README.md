<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Meeting Reminder icon">
</p>

<h1 align="center">Meeting Reminder for Mac</h1>

<p align="center">
A native macOS menu bar app built for people who lose track of time. Reads your calendar, shows a live countdown in the menu bar, escalates alerts progressively, and displays a full-screen blocking overlay before meetings — with one-click video conference join. Optionally records meetings locally via <a href="https://github.com/silverstein/minutes">Minutes</a>, auto-opens the transcript in Obsidian, and shows a live in-call transcript pane. Detects Zoom, Google Meet, Teams, Webex, and Slack links automatically.
</p>

<p align="center">
<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift"> <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

## Credits

This project was originally inspired by [In Your Face](https://www.inyourface.app), a fantastic Mac app that pioneered the full-screen meeting overlay concept. Meeting Reminder started as a free, open-source alternative and has since evolved into something different — an ADHD-focused meeting assistant with progressive alerts, live transcription via [Minutes](https://github.com/silverstein/minutes), Obsidian integration, Notion integration, and hybrid meeting-end detection. If you want a polished, commercial full-screen reminder — In Your Face is excellent and worth supporting.

---

## Features

### Core
- **Full-screen overlay** on one or all screens at a configurable time before meetings (1–10 min)
- **Video link detection** — Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddle from event notes, URL, or location
- **One-click join** — press Join or hit Enter to open the meeting link
- **Snooze & dismiss** — micro-snooze (30 seconds) and standard snooze (1 minute), or dismiss with Escape
- **Menu bar app** — no Dock icon; lives entirely in the menu bar
- **Multiple calendars** — iCloud, Google, Exchange, or any calendar synced to macOS; choose which to monitor
- **Customisable backgrounds** — 9 overlay themes (Dark, Blue, Purple, Sunset, Red, Green, Night Ocean, Electric, Cyber)
- **Launch at login** — auto-start via macOS native API
- **Privacy-first** — all data stays on your Mac; no cloud, no analytics, no tracking

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

### Multi-Monitor & In-Call Safety
- **Monitor picker** — choose which display the overlay appears on: all screens, primary only, or a specific connected monitor by name
- **In-call minimal alert** — when the mic is active (you're in a call or sharing your screen), the full-screen overlay is replaced with a compact, screen-share-safe notification in the corner of your chosen screen. Sound is also suppressed. Prevents broadcasting a giant "MEETING IN 2 MIN" banner to other participants.

### Hyperfocus Interruption
- **Micro-snooze (30 seconds)** — overlay returns quickly, making it harder to fall back into hyperfocus
- **Gentle screen dimming** — gradually reduces brightness to 70% over 5 minutes before a meeting. Linear transitions only, respects Reduce Motion, off by default. Safety-first.
- **Context-switch prompt** — a non-blocking floating message: "Save your work — you need to switch in 3 minutes." Stays visible but doesn't block interaction.

### Transition Support
- **Pre-meeting checklist** — a movable checklist panel appears alongside the overlay (e.g., "Close tabs", "Get water", "Open notes"). Fully customisable in Settings.
- **Meeting context panel** — a floating, semi-transparent panel showing title, time, attendees, agenda, and a clickable video link. Stays on screen during meetings. Optionally includes an **AI prep brief** (see Minutes integration below).

### Meeting Fatigue & Overload
- **Daily meeting load indicator** — menu bar dropdown shows: "6 meetings today (4.5h)", "3 back-to-back", "Next break: 2:30 PM"
- **Break enforcement** — when back-to-back meetings are detected (< 5 min gap), a gentle full-screen break overlay appears between them with stretch/water/breathe suggestions. Skippable.

### Ad-Hoc Meetings
- **"Start ad-hoc meeting" button** in the menu bar for calls that aren't on your calendar (someone pings you, impromptu stand-ups, etc.)
- **Start with title…** option opens a native prompt for a custom title, otherwise it defaults to `"Ad-hoc meeting · HH:mm"`
- Triggers the full meeting pipeline: context panel, live transcript pane, recording via Minutes, post-meeting nudge, auto-open in Obsidian

### Meeting End Detection
Detects when a meeting has ended using four layered signals, in order of reliability:

1. **Core Audio monitoring** (primary) — polls `kAudioDevicePropertyDeviceIsRunningSomewhere` every 5 seconds; when the mic has been idle for 30+ continuous seconds, treats the meeting as ended. 30-second debounce prevents false triggers during screen-share transitions or brief mute toggles.
2. **Video app lifecycle** (secondary) — watches for Zoom, Teams, Webex, or Slack quitting via `NSWorkspace.didTerminateApplicationNotification`.
3. **Calendar end time** (fallback) — uses the event's scheduled `endDate` as a backstop.
4. **Manual override** — **"End meeting"** button in the menu bar dropdown; required when Minutes is recording (the mic is held by the external recorder, so silence detection is suppressed).

### State Recovery & Reconnect
- **Status polling** — the app polls `minutes status` every 3 seconds and surfaces it in the menu bar
- **Reconnect to active recording** — when the app is relaunched mid-call (or a recording was started from the CLI), the menu bar shows "External recording detected" with a **Reconnect** button that adopts the existing session into the app's state. No lost recordings.
- **"Stop external recording"** fallback for when you want to kill a stray recording cleanly without adopting it.
- **Processing view** — shows the current Minutes processing stage (Transcribing → Generating summary → Saving) when a recording has stopped but is still being finalised.

### Minutes Integration (local transcription)
Uses the [`silverstein/minutes`](https://github.com/silverstein/minutes) Rust CLI for fully local transcription with whisper.cpp. No cloud, no API keys.

- **Auto-record** when a meeting becomes in-progress (calendar-joined or ad-hoc) — spawns `minutes record --title "<title>"` in the background
- **Live transcript pane** — a floating, movable panel that tails `~/.minutes/live-transcript.jsonl` and displays rolling whisper transcription while the meeting is in progress
- **In-call coach** — lightweight heuristics over the live transcript surface three kinds of hints:
  - **Question detected** (line ends with `?` or starts with a classic question word)
  - **You were mentioned** (word-boundary match against your name — plays a Tink chime)
  - **Commitment** (matches `"i'll send"`, `"i'll follow up"`, `"by friday"`, `"by eod"`, etc. — ~19 patterns)
- **Pre-meeting AI prep brief** — when the context panel opens, runs `minutes research <title>` and `minutes person <attendee>` for each of the first three attendees, and displays the joined output as a "Prep brief" section
- **Post-meeting parsed summary** — after the recording is stopped and transcribed, polls for the `~/meetings/<slug>.md` markdown file, parses its YAML frontmatter, and surfaces action items (with assignees and due dates) + decisions in the post-meeting nudge
- **Live transcript config health check** — if `[live_transcript].model` is empty in `~/.config/minutes/config.toml`, Settings → Minutes shows a warning and offers one-click buttons to write any installed whisper model as the active one. Without this, Minutes silently skips live transcription.
- **Spawn failure detection** — when `minutes record` crashes immediately on start (stale device name in config, missing whisper model, audio I/O failure), the app captures stderr, rolls back the "Recording" UI state, and shows an NSAlert with the real error plus a "Copy error details" button for bug reports. No more silent "Recording" state with nothing being recorded.

### Obsidian Integration
- **Vault detection** — reads `~/Library/Application Support/obsidian/obsidian.json` to enumerate all vaults registered with the Obsidian desktop app
- **Auto-open meeting note** — after a meeting ends and Minutes finishes transcribing, the app builds an `obsidian://open?vault=<name>&file=<relative-path>` URL and opens the note directly in the Obsidian desktop app (not the browser)
- **Symlink-aware vault resolution** — Minutes uses a symlink strategy by default (`<vault>/<subdir>/meetings` → `~/meetings`). The app walks the vault looking for any symlink whose target matches the meeting file, so it works transparently with this layout.
- **"Open in Obsidian"** button in the post-meeting nudge
- **Not-installed fallback** — if Obsidian.app isn't installed, Settings → Obsidian shows install instructions (Homebrew command + download link)
- **Vault-not-registered fallback** — if a meeting file can't be mapped to any known vault, the app launches Obsidian standalone so the user can open the note manually
- **Dataview Meetings Dashboard** — one-click installer in Settings → Obsidian drops a pre-built `Meetings Dashboard.md` into your vault (next to your meetings folder). It queries Minutes' YAML frontmatter with Dataview and renders live tables for: this week, today, open action items, recent decisions, people you're meeting most, **people you're losing touch with** (no contact in 30+ days), and monthly stats. Requires the Dataview and Tasks community plugins.

### Notion Integration
- **Database connection** — configure your Notion Meeting Notes database in Settings (API token stored in Keychain)
- **Auto-create meeting page** — when the reminder fires, creates a page with title, date, attendees, agenda, video link
- **Open in Notion desktop app** — uses `NSWorkspace.shared.open(url, withApplicationAt:)` with bundle id `notion.id` so pages open in the desktop app instead of the browser
- **Property mapping** — hardcoded to the canonical "Meeting Notes" schema (`Title`, `Start`, `End`, `Attendees Name`)
- **Known limitation** — Notion's API explicitly blocks creating `meeting_notes` (AI Meeting Notes transcription) blocks. The user must click "Apply template" once after the page opens to add the AI block. There is no workaround.

### Onboarding
First-launch setup assistant walks through permissions step by step in a standalone window (not a sheet on the menu bar popover):

1. Welcome screen
2. Calendar access (required)
3. Notifications (recommended, for progressive alert banners) — triggers the standard macOS notification permission prompt
4. Summary with per-item status indicators

Re-runnable any time from Settings → General.

---

## Screenshots

![Full-screen overlay with countdown and Join button](docs/screenshots/lock-screen.png)

<details>
<summary>Preferences</summary>

| General | Appearance | Calendars |
|---------|------------|-----------|
| ![General](docs/screenshots/preference-general.png) | ![Appearance](docs/screenshots/preference-appearance.png) | ![Calendars](docs/screenshots/preference-calendar.png) |

</details>

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build)
- Calendar access permission
- Notification permission (optional, for banner alerts)

### Optional dependencies

| Tool | Install | Used for |
|---|---|---|
| [Minutes](https://github.com/silverstein/minutes) | `brew tap silverstein/tap && brew install minutes` | Local transcription, live transcript pane, post-meeting action items |
| [Obsidian](https://obsidian.md) | `brew install --cask obsidian` | Auto-opening meeting notes after meetings |

Both are optional — the app works without them, and gracefully hides the relevant Settings sections if they're not installed. Settings → Obsidian has a one-click "copy install command" button if you want to set it up later.

---

## Installation

### Build from Source

```bash
git clone https://github.com/adamswbrown/meeting-reminder.git
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

### Deploy to /Applications

```bash
killall MeetingReminder 2>/dev/null
rm -rf "/Applications/MeetingReminder.app"
cp -R "$HOME/Library/Developer/Xcode/DerivedData/MeetingReminder-*/Build/Products/Debug/MeetingReminder.app" "/Applications/MeetingReminder.app"
open -a "/Applications/MeetingReminder.app"
```

---

## Usage

1. Launch the app — a calendar icon with countdown text appears in the menu bar
2. Grant calendar access when prompted (onboarding walks you through this)
3. The menu bar shows a live countdown to your next meeting, colour-coded by urgency
4. Progressive alerts escalate as the meeting approaches
5. A full-screen overlay appears with Join, Snooze (30s / 1 min), and Dismiss buttons
6. When you click Join (or start an ad-hoc meeting), the context panel opens with attendees + AI prep brief, and the live transcript pane starts (if Minutes is installed)
7. After the meeting, a nudge prompts you to capture action items and auto-opens the note in Obsidian

### Ad-hoc meetings

Click the menu bar icon → **Start ad-hoc meeting** for calls that aren't on your calendar. Add a custom title with **Start with title…** or accept the default (`"Ad-hoc meeting · HH:mm"`).

### Preview mode

The menu bar dropdown has a **Preview** section with buttons to preview each UI element without a real meeting:

- Meeting Overlay
- Pre-Meeting Checklist
- Context Panel (also opens the live transcript pane with seeded sample data)
- In-Call Minimal Alert
- Live Transcript

---

## Configuration

Open **Preferences** from the menu bar dropdown:

| Tab | Settings |
|-----|----------|
| **General** | Reminder time (1–10 min), sound, colour-blind mode, launch at login, re-run setup assistant |
| **Alerts** | Progressive alert tiers (toggle each), wrap-up threshold, context-switch prompt timing, break enforcement, screen dimming |
| **Display** | Overlay monitor (all / primary / specific), in-call minimal alert toggle |
| **Appearance** | 9 overlay background themes |
| **Checklist** | Add/remove/reorder pre-meeting checklist items |
| **Calendars** | Select which calendars to monitor |
| **Minutes** | CLI status, binary picker, auto-record toggle, AI prep brief toggle, live transcript toggle, in-call coach toggle, live transcript config health check + one-click fix |
| **Obsidian** | Installation status, vault list, auto-open-after-meeting toggle |

---

## Project Structure

```
MeetingReminder/
├── MeetingReminderApp.swift              # @main entry, MenuBarExtra, OverlayCoordinator, onboarding
├── Models/
│   ├── MeetingEvent.swift                # Meeting data model (attendees, notes, location)
│   ├── ChecklistItem.swift               # Pre-meeting checklist data model (Codable)
│   └── MinutesMeeting.swift              # Parsed `minutes` markdown + YAML frontmatter
├── Services/
│   ├── CalendarService.swift             # EventKit: access, fetch, filter, meeting stats
│   ├── MeetingMonitor.swift              # Core orchestrator: timers, alerts, end detection, ad-hoc, reconnect
│   ├── VideoLinkDetector.swift           # Regex detection: Zoom, Meet, Teams, Webex, Slack
│   ├── AlertTier.swift                   # Progressive alert tier enum + MenuBarUrgency enum
│   ├── NotificationService.swift         # UNUserNotificationCenter wrapper for banners
│   ├── ScreenDimmer.swift                # IOKit brightness control (gradual dimming)
│   ├── DisplayPreferences.swift          # Monitor picker resolution (all/primary/specific)
│   ├── KeychainHelper.swift              # Generic Keychain wrapper
│   ├── MinutesService.swift              # `minutes` CLI wrapper: record, stop, fetch, status polling, prep brief
│   ├── LiveTranscriptService.swift       # Tails live-transcript.jsonl + heuristic in-call coach
│   ├── ObsidianService.swift             # Vault detection, symlink-aware file resolution, obsidian:// URLs
│   └── NotionService.swift               # Notion API client
├── Views/
│   ├── MenuBarView.swift                 # Dropdown: event list, meeting load, recording/reconnect/ad-hoc, previews
│   ├── OverlayWindow.swift               # NSPanel wrappers for meeting + break overlays
│   ├── OverlayView.swift                 # Full-screen overlay UI (Join/Snooze/Dismiss, attendees)
│   ├── SettingsView.swift                # 8-tab preferences
│   ├── OnboardingView.swift              # First-launch setup (standalone NSWindow)
│   ├── ContextPanelView.swift            # Floating meeting context panel + AI prep brief
│   ├── ChecklistView.swift               # Pre-meeting checklist panel
│   ├── BreakOverlayView.swift            # Soft full-screen break overlay
│   ├── FloatingPromptView.swift          # Non-blocking context-switch prompt
│   ├── PostMeetingNudgeView.swift        # Post-meeting nudge (action items, decisions, Obsidian button)
│   ├── MinimalAlertView.swift            # Compact screen-share-safe in-call alert
│   └── LiveTranscriptView.swift          # Floating live transcript pane + heuristic coach hints
├── Resources/Assets.xcassets             # App icon
├── Info.plist                            # LSUIElement=true, calendar usage descriptions
└── MeetingReminder.entitlements          # Network client (sandbox disabled — required for `minutes` CLI spawn)
```

---

## Supported Video Platforms

| Platform | URL Pattern |
|----------|-------------|
| Zoom | `zoom.us/j/...` |
| Google Meet | `meet.google.com/...` |
| Microsoft Teams | `teams.microsoft.com/l/meetup-join/...` |
| Webex | `*.webex.com/...` |
| Slack Huddle | `app.slack.com/huddle/...` |

Links are detected in the event's URL, notes, and location fields.

---

## Roadmap

Features planned but not yet implemented (Phase 4 from the [ADHD Features Roadmap](docs/ADHD-FEATURES-ROADMAP.md)):

- [ ] **"What Was I Doing?" bookmark** — capture the frontmost app and window title when joining a meeting, then nudge the user to return to it afterwards. Requires Accessibility permission; degrades gracefully to app name only without it.
- [ ] **Decline assist** — flag likely-optional meetings (large attendee lists, "optional" / "FYI" in invite text) and surface a "Decline with template" button with pre-written responses. Blocked by EventKit limitation (can't programmatically decline); v1 would copy template to clipboard.
- [ ] **Per-calendar checklist overrides** — different pre-meeting checklists for different calendar types (e.g., 1:1s vs all-hands).
- [ ] **Multi-monitor screen dimming** — current dimming targets the primary display only; extend to all connected displays with per-display brightness control.
- [ ] **Overlay theming by urgency** — automatically shift overlay background colour based on how late the alert is.

See [docs/ADHD-FEATURES-ROADMAP.md](docs/ADHD-FEATURES-ROADMAP.md) for the full feature roadmap and design rationale.

---

## License

MIT
