<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Meeting Reminder icon">
</p>

<h1 align="center">Meeting Reminder for Mac</h1>

<p align="center">
A native macOS menu bar app built for people who lose track of time. Reads your calendar, shows a live countdown in the menu bar, escalates alerts progressively, and displays a full-screen blocking overlay before meetings — with one-click video conference join. Optionally creates a page in your <a href="https://www.notion.so">Notion</a> meeting database when you join a call, so Notion's AI Meeting Notes handles recording and summarisation. Detects Zoom, Google Meet, Teams, Webex, and Slack links automatically.
</p>

<p align="center">
<img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS"> <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift"> <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

## Credits

This project was originally inspired by [In Your Face](https://www.inyourface.app), a fantastic Mac app that pioneered the full-screen meeting overlay concept. Meeting Reminder started as a free, open-source alternative and has since evolved into something different — an ADHD-focused meeting assistant with progressive alerts, Notion integration for meeting notes, and hybrid meeting-end detection. If you want a polished, commercial full-screen reminder — In Your Face is excellent and worth supporting.

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
- **Meeting context panel** — a floating, semi-transparent panel showing title, time, attendees, agenda, and a clickable video link. Stays on screen during meetings.

### Meeting Fatigue & Overload
- **Daily meeting load indicator** — menu bar dropdown shows: "6 meetings today (4.5h)", "3 back-to-back", "Next break: 2:30 PM"
- **Break enforcement** — when back-to-back meetings are detected (< 5 min gap), a gentle full-screen break overlay appears between them with stretch/water/breathe suggestions. Skippable.

### Ad-Hoc Meetings
- **"Start ad-hoc meeting" button** in the menu bar for calls that aren't on your calendar (someone pings you, impromptu stand-ups, etc.)
- **Start with title…** option opens a native prompt for a custom title, otherwise it defaults to `"Ad-hoc meeting · HH:mm"`
- Triggers the full meeting pipeline: context panel opens, and (if configured) a new page is created in your Notion meeting database and opened in the Notion desktop app

### Meeting End Detection
Detects when a meeting has ended using four layered signals, in order of reliability:

1. **Core Audio monitoring** (primary) — polls `kAudioDevicePropertyDeviceIsRunningSomewhere` every 5 seconds; when the mic has been idle for 30+ continuous seconds, treats the meeting as ended. 30-second debounce prevents false triggers during screen-share transitions or brief mute toggles.
2. **Video app lifecycle** (secondary) — watches for Zoom, Teams, Webex, or Slack quitting via `NSWorkspace.didTerminateApplicationNotification`.
3. **Calendar end time** (fallback) — uses the event's scheduled `endDate` as a backstop.
4. **Manual override** — **"End meeting"** button in the menu bar dropdown. Also required when the Minutes pre-release integration is recording (the mic is held by the external recorder, so silence detection is suppressed).

### Notion Integration (primary recording path)
Meeting Reminder's default story for recording and summarisation is to delegate to Notion. When you join a meeting, the app creates a new page in your configured Notion meeting database and opens it in the Notion desktop app — Notion's own AI Meeting Notes block then handles recording + transcription + summarisation.

- **Database connection** — paste an internal integration token (stored in Keychain) + your database ID in Settings → Notion. Click **Save & Test** to verify. The test step surfaces HTTP status + Notion's response body inline if anything's wrong (usually the database hasn't been shared with the integration yet — in Notion, open the database → `…` → Connections → add yours).
- **Auto-create meeting page** — fires the moment `currentMeetingInProgress` becomes non-nil, which covers both calendar-joined meetings and ad-hoc meetings started from the menu bar
- **Open in Notion desktop app** — uses `NSWorkspace.shared.open(url, withApplicationAt:)` with bundle id `notion.id` so pages open in the desktop app instead of the browser
- **Schema** — the target database needs `Title` (title), `Start` (date), `End` (date), and optionally `Attendees Name` (rich text). Video link (if any) is attached as a bookmark block; the calendar event's notes are added as a "Calendar notes" heading + paragraph.
- **Feature-flagged** — off by default. Toggle "Enable Notion integration" in Settings → Notion once you've entered credentials.
- **Known limitation** — Notion's API explicitly blocks creating `meeting_notes` (AI Meeting Notes transcription) blocks. You need to click "Apply template" once after the page opens to add the AI block. There is no workaround.

---

## Pre-release integrations (Minutes + Obsidian)

> **Status: pre-release, off by default.** These integrations exist in the codebase but are hidden behind feature flags in Settings → Integrations because they were unreliable in day-to-day use. I tried running Minutes as my daily meeting recorder for ~24 hours and hit enough rough edges to shelve it in favour of Notion's AI Meeting Notes (see below). They're preserved here because the plumbing works when it works, and someone with a different setup may get more mileage out of them.
>
> **Why I stopped using Minutes as the default:**
> - Recording silently failed more than once with no user-visible error — the UI showed "Recording" but `~/meetings/` never produced a file. The spawn-failure detection catches some cases but not all (things like whisper model mid-run crashes, or the recording sidecar deciding to skip live transcription because of config drift).
> - The app's Core Audio silence detection can't run while `minutes record` holds the mic, so automatic "meeting ended" detection falls back to either clicking **End meeting** manually or waiting for the calendar `endDate`. In practice I kept forgetting to click End and ended up with 2-hour recordings of nothing.
> - `config.toml` drift — stale device names, empty `[live_transcript].model`, duplicate `[calendar]` sections after running `minutes health` — produced cryptic errors that required digging around in `~/.config/minutes/` to fix.
> - Post-meeting markdown parsing and the Obsidian auto-open flow depended on all of the above working end-to-end. When any link in the chain broke, the post-meeting nudge either never fired or showed "Transcribing…" forever.
>
> If you want to try them anyway: Settings → Integrations → flip the **Minutes** and/or **Obsidian** switches. The existing UI (status checks, binary picker, health check, dashboard installer, etc.) lives inside the collapsible cards and becomes active the moment you toggle them on.

### State Recovery & Reconnect *(pre-release)*
- **Status polling** — the app polls `minutes status` every 3 seconds and surfaces it in the menu bar
- **Reconnect to active recording** — when the app is relaunched mid-call (or a recording was started from the CLI), the menu bar shows "External recording detected" with a **Reconnect** button that adopts the existing session into the app's state.
- **"Stop external recording"** fallback for when you want to kill a stray recording cleanly without adopting it.
- **Processing view** — shows the current Minutes processing stage (Transcribing → Generating summary → Saving) when a recording has stopped but is still being finalised.

### Minutes Integration — local transcription *(pre-release)*
Uses the [`silverstein/minutes`](https://github.com/silverstein/minutes) Rust CLI for fully local transcription with whisper.cpp. No cloud, no API keys.

- **Auto-record** when a meeting becomes in-progress (calendar-joined or ad-hoc) — spawns `minutes record --title "<title>"` in the background
- **Live transcript pane** — a floating, movable panel that tails `~/.minutes/live-transcript.jsonl` and displays rolling whisper transcription while the meeting is in progress
- **In-call coach** — lightweight heuristics over the live transcript surface three kinds of hints:
  - **Question detected** (line ends with `?` or starts with a classic question word)
  - **You were mentioned** (word-boundary match against your name — plays a Tink chime)
  - **Commitment** (matches `"i'll send"`, `"i'll follow up"`, `"by friday"`, `"by eod"`, etc. — ~19 patterns)
- **Pre-meeting AI prep brief** — when the context panel opens, runs `minutes research <title>` and `minutes person <attendee>` for each of the first three attendees, and displays the joined output as a "Prep brief" section
- **Post-meeting parsed summary** — after the recording is stopped and transcribed, polls for the `~/meetings/<slug>.md` markdown file, parses its YAML frontmatter, and surfaces action items (with assignees and due dates) + decisions in the post-meeting nudge
- **Live transcript config health check** — if `[live_transcript].model` is empty in `~/.config/minutes/config.toml`, Settings → Integrations → Minutes shows a warning and offers one-click buttons to write any installed whisper model as the active one. Without this, Minutes silently skips live transcription.
- **Spawn failure detection** — when `minutes record` crashes immediately on start (stale device name in config, missing whisper model, audio I/O failure), the app captures stderr, rolls back the "Recording" UI state, and shows an NSAlert with the real error plus a "Copy error details" button for bug reports. Does not catch failures that happen after the spawn succeeds, which is the bulk of the reliability problem.

### Obsidian Integration *(pre-release — depends on Minutes)*
Opens the Minutes-generated meeting note in the Obsidian desktop app after a meeting ends. Pointless without the Minutes integration enabled, since there's no note to open.

- **Vault detection** — reads `~/Library/Application Support/obsidian/obsidian.json` to enumerate all vaults registered with the Obsidian desktop app
- **Auto-open meeting note** — builds an `obsidian://open?vault=<name>&file=<relative-path>` URL and opens the note directly in the Obsidian desktop app (not the browser)
- **Symlink-aware vault resolution** — Minutes uses a symlink strategy by default (`<vault>/<subdir>/meetings` → `~/meetings`). The app walks the vault looking for any symlink whose target matches the meeting file, so it works transparently with this layout.
- **"Open in Obsidian"** button in the post-meeting nudge
- **Vault-not-registered fallback** — if a meeting file can't be mapped to any known vault, the app launches Obsidian standalone so the user can open the note manually
- **Dataview Meetings Dashboard** — one-click installer drops a pre-built `Meetings Dashboard.md` into your vault (next to your meetings folder). It queries Minutes' YAML frontmatter with Dataview and renders live tables for: this week, today, open action items, recent decisions, people you're meeting most, **people you're losing touch with** (no contact in 30+ days), and monthly stats. Requires the Dataview and Tasks community plugins.

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

| Tool | Install | Used for | Status |
|---|---|---|---|
| [Notion](https://www.notion.so) (desktop app + API integration token) | Download from notion.so + create an internal integration at notion.so/my-integrations | Creating meeting pages on join; Notion's AI Meeting Notes handles recording + summarisation | **Supported** (primary integration) |
| [Minutes](https://github.com/silverstein/minutes) | `brew tap silverstein/tap && brew install minutes` | Local transcription, live transcript pane, post-meeting action items | **Pre-release** — feature-flagged off, see notes above |
| [Obsidian](https://obsidian.md) | `brew install --cask obsidian` | Auto-opening Minutes-generated meeting notes | **Pre-release** — feature-flagged off, depends on Minutes |

All three are optional — the app works without any of them.

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
6. When you click Join (or start an ad-hoc meeting), the context panel opens with attendees + notes, and — if the Notion integration is configured — a new page is created in your meeting database and opened in the Notion desktop app
7. Notion's AI Meeting Notes block handles recording, transcription, and the post-meeting summary from there

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
| **Notion** | API token (Keychain), database ID, Save & Test button, enable toggle |
| **Integrations** | Pre-release: master toggles for **Minutes** (CLI status, binary picker, auto-record, prep brief, live transcript, in-call coach, config health check) and **Obsidian** (vault list, auto-open, Dataview dashboard installer) |

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
│   ├── ObsidianService.swift             # Vault detection, symlink-aware file resolution, obsidian:// URLs (pre-release)
│   └── NotionService.swift               # Notion API client — primary recording integration
├── Views/
│   ├── MenuBarView.swift                 # Dropdown: event list, meeting load, recording/reconnect/ad-hoc, previews
│   ├── OverlayWindow.swift               # NSPanel wrappers for meeting + break overlays
│   ├── OverlayView.swift                 # Full-screen overlay UI (Join/Snooze/Dismiss, attendees)
│   ├── SettingsView.swift                # 8-tab preferences (General, Alerts, Display, Appearance, Checklist, Calendars, Notion, Integrations)
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
