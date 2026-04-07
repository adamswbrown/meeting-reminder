# Meeting Reminder for Mac

Native macOS menu bar app (Swift + SwiftUI) with ADHD-focused features. Reads the user's calendar, shows progressive alerts, displays a full-screen blocking overlay before meetings, integrates with Notion for meeting notes, and detects meeting end via Core Audio.

Target: macOS 13+ (Ventura). Swift 5. No external dependencies.

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
│   └── ChecklistItem.swift               # Pre-meeting checklist data model (Codable)
├── Services/
│   ├── CalendarService.swift             # EventKit: access, fetch, filter, meeting stats
│   ├── MeetingMonitor.swift              # Core orchestrator: timers, alerts, end detection
│   ├── VideoLinkDetector.swift           # Regex detection: Zoom, Meet, Teams, Webex, Slack
│   ├── AlertTier.swift                   # Progressive alert tier enum + MenuBarUrgency enum
│   ├── NotificationService.swift         # UNUserNotificationCenter wrapper for banners
│   ├── ScreenDimmer.swift                # IOKit brightness control (gradual dimming)
│   └── NotionService.swift               # Notion API client + Keychain token storage
├── Views/
│   ├── MenuBarView.swift                 # Window-style popover (event list, meeting load, previews)
│   ├── OverlayWindow.swift               # NSPanel wrappers for meeting + break overlays
│   ├── OverlayView.swift                 # Full-screen overlay UI (Join/Snooze/Dismiss)
│   ├── SettingsView.swift                # 6-tab preferences
│   ├── OnboardingView.swift              # First-launch setup (standalone NSWindow)
│   ├── ContextPanelView.swift            # Floating meeting context panel (attendees, notes)
│   ├── ChecklistView.swift               # Pre-meeting checklist panel
│   ├── BreakOverlayView.swift            # Soft full-screen break overlay
│   ├── FloatingPromptView.swift          # Non-blocking context-switch prompt
│   └── PostMeetingNudgeView.swift        # Post-meeting action item nudge
├── Resources/Assets.xcassets             # App icon
├── Info.plist                            # LSUIElement=true, calendar usage descriptions
└── MeetingReminder.entitlements          # Sandbox + calendar + network client
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
- `currentMeetingInProgress` — currently active meeting (set on join)

**OverlayCoordinator** (in `MeetingReminderApp.swift`) — owns all NSPanel window controllers and observes `MeetingMonitor` published state via Combine. Listens for `NSApplication.willTerminateNotification` to close all panels on quit.

**Window controllers** — each floating UI element has its own controller class wrapping an `NSPanel`:
- `OverlayWindowController` — meeting overlay (`.screenSaver` level, all screens)
- `BreakOverlayWindowController` — break enforcement overlay
- `ChecklistWindowController` — checklist panel (`.screenSaver - 1` level)
- `ContextPanelWindowController` — meeting context panel (`.floating`)
- `FloatingPromptWindowController` — context-switch nudge (`.floating`)
- `PostMeetingNudgeWindowController` — post-meeting capture nudge
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
1. **Core Audio monitoring** (primary) — `kAudioDevicePropertyDeviceIsRunningSomewhere` polled every 5s. Detects when the mic goes idle.
2. **30-second debounce** — audio must be inactive for 30+ continuous seconds before triggering "meeting ended". Prevents false positives during screen-share transitions or brief mic drops.
3. **Video app lifecycle** (secondary) — `NSWorkspace.didTerminateApplicationNotification` for known video bundle IDs (Zoom, Teams, Webex, Slack)
4. **Calendar end time** (fallback) — `event.endDate` as backstop
5. **Manual override** — "Done with meeting" button in menu bar dropdown

### Notion Integration
- **API token in Keychain** — never UserDefaults. `KeychainHelper` in `NotionService.swift` uses `kSecClassGenericPassword`
- **Property mapping** — Adam's database uses `Title` (title), `Start`/`End` (date), `Attendees Name` (rich_text). The `createMeetingPage` method is hardcoded for this schema.
- **Cannot create transcription/meeting_notes blocks via API** — Notion's API explicitly blocks `meeting_notes` block creation. The user must click "Apply template" once after the page opens to add the AI Meeting Notes block. There is no workaround.
- **Open in Notion desktop app** — `NotionService.openInNotionApp(url)` uses `NSWorkspace.shared.open([url], withApplicationAt: ...)` with bundle ID `notion.id` to open URLs in the desktop app instead of the browser. Falls back to default browser if Notion.app is not installed.

### Settings & Persistence
- **`@AppStorage`** for simple preferences
- **JSON-encoded UserDefaults** for `defaultChecklist` (array of `ChecklistItem`)
- **Keychain** for `notionAPIToken`
- **OverlayBackground enum** — stores background choice as string in `@AppStorage("overlayBackground")`, returns `AnyShapeStyle` for use in overlay

---

## Settings (UserDefaults keys)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hasCompletedOnboarding` | Bool | false | Onboarding finished — skip on next launch |
| `reminderMinutes` | Int | 5 | Minutes before meeting to show overlay |
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
| `screenDimmingEnabled` | Bool | false | Gradual brightness reduction (off by default) |
| `breakEnforcementEnabled` | Bool | true | Break overlay between back-to-back meetings |
| `contextSwitchPromptMinutes` | Int | 3 | Minutes before meeting for context-switch nudge |
| `defaultChecklist` | Data (JSON) | defaults | Pre-meeting checklist items |
| `notionDatabaseID` | String | "" | Notion Meeting Notes database ID |

### Keychain keys

| Service | Account | Description |
|---------|---------|-------------|
| `com.meetingreminder.app` | `notionAPIToken` | Notion integration secret |

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

The menu bar dropdown has a Preview section with three buttons:
- **Meeting Overlay** — calls `meetingMonitor.testOverlay()` with a fake event
- **Pre-Meeting Checklist** — `overlayCoordinator.previewChecklist()`
- **Context Panel** — `overlayCoordinator.previewContextPanel()`

### Testing onboarding

```bash
defaults write com.meetingreminder.app hasCompletedOnboarding -bool false
```

Then click the menu bar icon — onboarding will appear in a standalone window.

### Notion debugging

Test the API directly with curl:

```bash
# Test connection
curl -s "https://api.notion.com/v1/databases/<DATABASE_ID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Notion-Version: 2022-06-28"
```

Common issues:
- **404** — database not shared with the integration. User must add the integration via Notion's "Connections" menu on the database page
- **400 on `meeting_notes` block** — known limitation, cannot create AI Meeting Notes block via API

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
