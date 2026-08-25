<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Meeting Reminder icon">
</p>

<h1 align="center">Meeting Reminder for Mac</h1>

<p align="center"><strong>The meeting reminder for people who lose track of time.</strong></p>

<p align="center">
  <a href="https://github.com/adamswbrown/meeting-reminder/releases/latest"><strong>Download for macOS</strong></a>
  ·
  <a href="CHANGELOG.md">See what’s new</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Swift-native-orange" alt="Native Swift app">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

![A full-screen meeting reminder with countdown and one-click join](docs/screenshots/lock-screen.png)

## Why Meeting Reminder?

Calendar notifications are easy to miss when you are focused. Meeting Reminder gives you a clearer sense of time and makes the transition into your next call harder to ignore.

- **See what is next without clicking** — a live countdown stays in the menu bar and becomes more urgent as the meeting approaches.
- **Get reminders that build gradually** — start with a quiet colour change, then a notification, sound, and finally a full-screen overlay.
- **Join in one click** — meeting links are detected automatically in event URLs, notes, and locations.
- **Stay focused without being surprised** — wrap-up nudges, short snoozes, and an optional pre-meeting checklist give you time to switch context.
- **Avoid disrupting a call already in progress** — when your microphone is active, Meeting Reminder can use a compact, screen-share-safe alert instead of the full-screen overlay.
- **Keep the core experience private** — calendars are read through macOS and reminder data stays on your Mac. There are no analytics or tracking.

## Made for time blindness

Meeting Reminder is designed for people who can become absorbed in their work and lose track of the clock. Its urgency is communicated with text, colour, and distinct icon shapes, including a colour-blind-friendly mode.

You can tailor the interruption to suit how you work:

- Choose a full-screen lead time from 1 to 15 minutes.
- Enable only the alert stages you find useful.
- Snooze briefly or until a specific point before the meeting.
- Show the overlay on one display or every display.
- Add a personal transition checklist.
- Dim the screen gradually or show a non-blocking context-switch prompt.
- Get a break reminder between back-to-back meetings.

Meeting Reminder works with calendars synced to macOS, including iCloud, Google, and Exchange. It detects links for Zoom, Google Meet, Microsoft Teams, Webex, and Slack Huddles.

## Optional integrations

The reminder app works without any external services. If you want to extend it, the following integrations are available and disabled by default:

| Integration | What it adds | Setup |
|---|---|---|
| Notion | Create a meeting page when you join and sync selected calendar events | [Notion setup](docs/NOTION-SETUP.md) |
| Pre-call briefings | Generate briefings for newly added meetings using local command-line tools | [Briefing setup](docs/INTRADAY-BRIEFINGS.md) |
| Availability page | Publish a sanitised free/busy view without exposing event titles or attendees | [Availability setup](docs/AVAILABILITY-PAGE.md) |
| Busy light | Drive a HomeKit accessory—or another automation—with Apple Shortcuts | [Busy light setup](docs/BUSY-LIGHT.md) |
| Cal.com | Sync bookings and meeting links into the local calendar workflow | [Booking setup](docs/BOOKING.md) |

Optional integrations may send data to the service you connect. The core calendar reminder, countdown, alerts, and meeting-link detection remain local.

## Install

* Download and install the [latest release](https://github.com/adamswbrown/meeting-reminder/releases/latest).
* Follow the setup assistant to grant required access.
* Requires **macOS 13 Ventura or later**.

## Build from source

Building requires a recent Xcode (Xcode 26 is used for development; CI builds with the latest stable Xcode). The code uses Swift 6.x region-based concurrency, so older Xcode versions such as 15.4 will not compile it.

```bash
git clone https://github.com/adamswbrown/meeting-reminder.git
cd meeting-reminder
open MeetingReminder.xcodeproj
```

Press **Cmd+R** in Xcode to build and run.

## Credits

Meeting Reminder was inspired by [In Your Face](https://www.inyourface.app), which pioneered the full-screen meeting reminder on Mac. If you prefer a polished commercial alternative focused on that experience, it is well worth supporting.

## License

[MIT](LICENSE)
