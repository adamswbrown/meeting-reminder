# Busy Light

Drive a physical "on a call" light (or anything else scriptable) automatically
from your meeting + microphone state. The app runs a macOS **Shortcut** when you
go busy and another when you go free.

## How it works

`BusyLightService` (`Services/BusyLightService.swift`) watches two signals:

1. **In a meeting** — `MeetingMonitor.currentMeetingInProgress` is non-nil.
2. **Mic is hot** — `MeetingMonitor.micActive` is `true`.

When either becomes true it runs your **Busy** Shortcut; when both fall back to
false it runs your **Free** Shortcut, after a **30-second debounce on the falling
edge** so a brief mic drop (screen-share handoff, mute/unmute) doesn't flicker
the light.

The Shortcut is whatever you want — a HomeKit "Set <bulb> to red", a Hue scene,
a webhook to a smart plug, a Slack status update. The app only calls
`shortcuts run "<name>"`; the automation lives in Shortcuts.app.

## Setup

1. **Settings → Busy Light tab.**
2. Pick your **Busy** and **Free** Shortcuts from the dropdowns (populated from
   `shortcuts list`). Toggles let you enable just one side if you prefer.
3. Don't have Shortcuts yet? Use the bundled **one-click starters** — *Meeting
   Busy* and *Meeting Free* `.shortcut` files ship in the app. The Install
   buttons hand them to Shortcuts.app; bind your bulb/scene on first open.

### Settings keys (UserDefaults)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `busyLightBusyEnabled` | Bool | true | Run the Busy shortcut on the rising edge |
| `busyLightFreeEnabled` | Bool | true | Run the Free shortcut on the falling edge |
| `busyLightBusyShortcut` | String | "" | Name of the Shortcut to run when busy |
| `busyLightFreeShortcut` | String | "" | Name of the Shortcut to run when free |
| `busyLightIgnoredAudioBundleIDs` | [String] | [] | Extra bundle IDs to ignore for mic detection (see below) |

## Process-aware mic detection (v3.0.0)

The naive way to ask "is the mic in use" is the device-level
`kAudioDevicePropertyDeviceIsRunningSomewhere`, but it returns `true` whenever
**any** process holds the input device open. Always-on listeners —
**Superwhisper**, Apple's dictation/speech-recognition daemons — keep the mic
open continuously, which pinned the busy light to **Busy forever**.

`AudioProcessMonitor` (`Services/AudioProcessMonitor.swift`) fixes this by
enumerating **per-process** audio input via the macOS 14+
`kAudioHardwarePropertyProcessObjectList` API. The mic only counts as "hot" when
a process **outside the ignore set** (and outside our own PID) is actually
consuming input.

- **Default ignore set:** Superwhisper + Apple speech/dictation daemons.
- **Extend it:** add bundle IDs to the `busyLightIgnoredAudioBundleIDs`
  UserDefaults array, e.g.
  ```bash
  defaults write com.meetingreminder.app busyLightIgnoredAudioBundleIDs -array \
    com.example.somelistener com.example.another
  ```
- **macOS 13 fallback:** the per-process API doesn't exist on Ventura, so there
  the service falls back to the old device-level check.

## Troubleshooting

- **Light stuck on Busy** — a background app is holding the mic. Find it and add
  its bundle ID to `busyLightIgnoredAudioBundleIDs`. Confirm the culprit with
  the per-process list in Console, or temporarily quit suspect apps.
- **Shortcut not in the dropdown** — the list comes from `shortcuts list`. If you
  just created it, reopen Settings to refresh.
- **Nothing happens on the edge** — check the matching `…Enabled` toggle is on
  and a Shortcut name is selected. Test the Shortcut directly in Shortcuts.app
  first to rule out the automation itself.
