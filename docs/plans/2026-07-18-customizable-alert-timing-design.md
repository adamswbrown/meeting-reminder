# Customizable overlay timing & snooze-until — design

**Issue:** [#13](https://github.com/adamswbrown/meeting-reminder/issues/13) — "Customizable times for full screen overlay and snooze durations"
**Branch:** `feature/issue-13-alert-timing`
**Date:** 2026-07-18

## The ask (verbatim)

> I want a full screen alert 10 minutes before, and the ability to customize the
> snooze durations, so I can snooze first until 2 minutes before the meeting, and
> then snooze until the meeting starts.

Two requests:

1. **Configurable full-screen overlay lead time** — trigger the overlay up to 10 (or more) minutes before start.
2. **Customizable snooze**, specifically a *snooze-until-a-point-relative-to-start* model: "until 2 min before", then "until start".

## What already exists

- **Overlay lead time already works.** `reminderMinutes` (`SettingsView.swift`, General tab) drives the blocking overlay in `MeetingMonitor.checkMeetings()` and already offers a 10-minute option. It's just labelled "Remind me before meetings" and lives in **General**, not **Alerts** — so it's undiscoverable as an "alert" setting.
- **Snooze is fixed-duration only.** Overlay buttons are hardcoded `30s` / `1 min` (`OverlayView.swift`, `MinimalAlertView.swift`), calling `MeetingMonitor.snooze(seconds:)` which sets `snoozedEvents[id] = now + seconds`, clears fired tiers, drops the id from `shownEventIDs`, and dismisses — so the overlay re-fires when the snooze expires.

## Decisions (from brainstorming)

- **Snooze model:** snooze-*until*-before-start (moving target relative to meeting start), **hybrid** with the existing fixed-duration quick-snooze (30s/1min stay).
- **Snooze config:** fixed preset ladder **10 / 5 / 2 / 0 min before start**, each gated by a per-threshold toggle (mirrors the existing `AlertTier` toggle pattern). Defaults: 5, 2, 0 enabled; 10 off. These defaults give the user's exact described flow out of the box.
- **Overlay lead time:** move the `reminderMinutes` picker into the **Alerts** tab and broaden options (add 15 min). Same key/semantics — no migration.

## Design

### New model: `SnoozeUntilThreshold`

`MeetingReminder/Services/SnoozeUntilThreshold.swift` — a pure enum mirroring `AlertTier`:

```
enum SnoozeUntilThreshold: Int, CaseIterable, Identifiable {
    case tenMin = 10, fiveMin = 5, twoMin = 2, start = 0
    var minutesBeforeStart: Int { rawValue }
    var settingsKey: String            // "snoozeUntil{10,5,2,0}Enabled"
    var defaultEnabled: Bool           // 10 → false; 5/2/0 → true
    var isEnabled: Bool                // reads UserDefaults, falls back to defaultEnabled
    var displayName: String            // "10 min before" / "Until start" (Settings)
    var buttonLabel: String            // "10 min" / "Start" (overlay)

    // Seconds to snooze given time remaining until start; nil if target already passed.
    func snoozeSeconds(secondsUntilStart: Double, minLead: Double = 20) -> Int?

    // Enabled AND still-in-the-future thresholds for a meeting `secondsUntilStart` away.
    static func available(secondsUntilStart: Double) -> [SnoozeUntilThreshold]
}
```

`snoozeSeconds` = `secondsUntilStart − minutesBeforeStart·60`, returning `nil` when that
target is under `minLead` (20s) away — this prevents a snooze that would instantly
re-fire, and naturally hides thresholds the meeting has already passed.

### Runtime — no new monitor code

Because the overlay views already hold `event` and already call `onSnooze(Int)` in
**seconds**, a snooze-until is simply `onSnooze(threshold.snoozeSeconds(...)!)`. The
existing `MeetingMonitor.snooze(seconds:)` handles the absolute target, tier reset, and
re-fire. **No changes to `MeetingMonitor`, `OverlayWindow`, `MinimalAlertWindowController`,
or `MeetingReminderApp` wiring.**

### Overlay UI (`OverlayView` + `MinimalAlertView`)

- Existing quick-snooze `30s` / `1 min` — unchanged.
- New: one button per `SnoozeUntilThreshold.available(secondsUntilStart:)`, labelled
  `10 min` / `5 min` / `2 min` / `Start`, each calling `onSnooze(seconds)`.
- The available list is recomputed from `event.startDate.timeIntervalSinceNow` on each
  body render (the 1 s countdown timer already re-renders the view), so buttons drop off
  as their thresholds pass. When none are available the row is omitted.

### Settings (Alerts tab)

- **Move** the `reminderMinutes` picker from General → Alerts, relabel "Full-screen overlay:",
  add a 15-minute option (1/2/3/5/10/15).
- **New "Snooze" section:** a `ForEach(SnoozeUntilThreshold.allCases)` of toggles bound to
  each threshold's `settingsKey`, plus a caption explaining the quick-snooze buttons stay.

### New UserDefaults keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `snoozeUntil10Enabled` | Bool | false | Show "10 min before" snooze-until button |
| `snoozeUntil5Enabled`  | Bool | true  | Show "5 min before" button |
| `snoozeUntil2Enabled`  | Bool | true  | Show "2 min before" button |
| `snoozeUntil0Enabled`  | Bool | true  | Show "Until start" button |

`reminderMinutes` is unchanged (relabelled + relocated only).

## Testing

`MeetingReminderTests/SnoozeUntilThresholdTests.swift` (pure, no EventKit):

- `snoozeSeconds` maths for each threshold at representative `secondsUntilStart`.
- `nil` when target within `minLead` / already passed.
- `available(secondsUntilStart:)` filters by both enable-state and future-ness (drive via
  UserDefaults, restore after).
- default-enabled map (10 off; 5/2/0 on), raw-value round-trip, non-empty labels.

## Out of scope (YAGNI)

- Editable/arbitrary snooze values — preset ladder only.
- Per-meeting or per-calendar overrides.
- Changing the progressive `AlertTier` ladder.
- Any change to fixed-duration quick-snooze behaviour.
