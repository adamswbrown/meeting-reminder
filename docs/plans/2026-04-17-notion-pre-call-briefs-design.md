# Notion Pre-Call Briefs in Meeting Reminder

**Date:** 2026-04-17
**Status:** Design approved, ready for implementation plan

## Problem

Pre-call briefs live in a Notion database (`Pre-Call Briefings`). Notion also hosts the meeting recording/notes on a different page. Without surfacing the brief inside Meeting Reminder, Adam has to flip between Notion tabs during a call to reference it — which he won't remember to do. The information is effectively lost at the moment it's most useful.

## Goal

Surface the matching pre-call brief inside the Meeting Reminder app at the 5-minute reminder, keep it visible during the meeting, dismissible and re-openable on demand. Built initially for Adam's personal workflow against the `Pre-Call Briefings` DB, but structured so the same pipeline can later point at other Notion content.

## Non-goals (v1)

- Real-time sync / webhooks — briefs are static per-meeting
- Editing briefs from the app — "Open in Notion" is the edit path
- Rendering embedded databases, images, or synced Notion blocks
- OAuth — reuses the existing personal integration token
- Multi-user support

## Source of truth

**Database:** `Pre-Call Briefings`
**Data source ID:** `656b2eff-7ea3-4730-91fe-104ff647f4e3`
**URL:** https://www.notion.so/c2a1ea4e2c58470ea77608a635756d00

**Schema (relevant properties):**

| Property | Type | Used for |
|---|---|---|
| `Meeting Title` | title | Fuzzy match against calendar event title |
| `Date & Time` | date (datetime) | Primary match filter (±12h window) |
| `Attendees` | text | Tiebreaker when multiple candidates |
| `Customer / Partner` | select | Display chip |
| `Briefing Status` | select (Auto / Reviewed / Skipped) | Display only |

## Architecture

### New service: `PreCallBriefService`

Separate from the existing `NotionService` to keep concerns clean. Reuses `NotionService`'s Keychain token (`notionAPIToken`) and HTTP patterns — no new secrets.

**Responsibilities:**
- Query the briefs data source, filtered on `Date & Time` within ±12h of a calendar event
- Fuzzy-score `Meeting Title` against the event title; use `Attendees` overlap as tiebreaker
- Fetch page content via `GET /v1/blocks/{pageID}/children`, convert to markdown in-process (paragraphs, headings, bullets, numbered lists, callouts, toggles → `<details>`)
- Cache the `eventID → pageID` mapping; refuse to re-query once attached
- In-memory cache of page *content* for the life of a meeting

### Match algorithm

1. Query data source with filter on `Date & Time` within ±12h of `event.startDate`
2. Score each candidate: Levenshtein ratio of lowercased titles, threshold ~0.6
3. Tiebreak by `Attendees` substring overlap
4. ≥1 candidate above threshold → auto-attach top pick
5. 0 candidates → widen date window to ±7 days, fuzzy title only
6. Still 0 → "No brief found" state; user can manually attach

### Data model

```swift
struct BriefMatch: Codable {
    let pageID: String
    let pageURL: String
    let matchedAt: Date
    let userAttached: Bool  // true = manual, false = auto-matched
}
// Stored as [eventID: BriefMatch] JSON in UserDefaults under `preCallBriefMatches`
```

User-attached matches are never overwritten by auto-matching. Auto-matches can be re-run via a "Re-match" button if the user thinks the wrong one was picked.

### Auth

Reuses the existing Notion internal integration token stored in Keychain at `notionAPIToken`. The integration must be shared with the `Pre-Call Briefings` DB (and any sub-pages that brief content links to). No code changes required — this is a Notion UI action Adam performs once.

## UI surfaces

### `BriefPanelView` + `BriefPanelWindowController`

**New SwiftUI view:** `Views/BriefPanelView.swift`
- Header row: meeting title, `Customer / Partner` chip, "Open in Notion" button, close button
- Scrollable body: markdown rendered with `AttributedString(markdown:)`; code blocks and callouts as `GroupBox`; toggles as `DisclosureGroup`
- Footer: "Re-match" and "Attach different brief…"

**New window controller:** `BriefPanelWindowController`
- `NSPanel` at `.floating` level
- Resizable, default ~420×640
- Remembers last position/size via `NSWindow.setFrameAutosaveName("BriefPanel")`

### Trigger points (all wired through `OverlayCoordinator`)

| Moment | Behavior |
|---|---|
| 5-min reminder overlay fires | Kick off match in background. If found, open panel. Overlay (`.screenSaver`) covers it until dismissed/joined; brief reappears after. |
| Meeting joined | If not already open and a brief is attached, open it. |
| Meeting ended | Close panel (same lifecycle as the context panel). |
| User clicks "Brief" button | Reopens if dismissed. |

### Entry points

- **ContextPanelView** — new row: "📄 Pre-Call Brief: *[title]*" with Open/Dismissed state, or "Attach brief…" if no match
- **MenuBarView** — small doc icon next to each event's Join button. Greyed out if no brief; active if one is attached.

### No-match state

Compact card inside `BriefPanelView` with:
- Meeting title
- "Search Notion…" button — opens a searchable picker (last 30 days of briefs)
- "Create new brief in Notion" — deep-links to a new page in the DB with title pre-filled

## Settings

New **Notion Briefs** section in `SettingsView` (either a new tab or a section under the existing Notion tab — decide at implementation).

| Key | Type | Default | Purpose |
|---|---|---|---|
| `preCallBriefsEnabled` | Bool | true | Master toggle |
| `preCallBriefsDataSourceID` | String | `656b2eff-7ea3-4730-91fe-104ff647f4e3` | Editable for future generalisation |
| `preCallBriefAutoOpen` | Bool | true | Auto-open at 5-min reminder vs. hint-only |
| `preCallBriefFuzzyThreshold` | Double | 0.6 | Hidden under "Advanced" disclosure |
| `preCallBriefMatches` | Data (JSON) | `{}` | `[eventID: BriefMatch]` persistence |

## Error handling

All errors surface inline in the panel header as a warning — never as a blocking modal.

| Condition | Behavior |
|---|---|
| No token configured | "Connect Notion in Settings" + button that opens Settings → Notion |
| 401 / 403 | "Notion token invalid or DB not shared with integration" + link to integrations page |
| Network failure | "Couldn't reach Notion — retry" button; cached content stays visible if present |
| Rate limit (429) | Exponential backoff; shown as "Retrying…" pill |
| Ambiguous match (multiple high scores) | Opens on top candidate; subtle "2 possible matches — change" link |

## Testing

Project has no test target; verification is manual per CLAUDE.md patterns.

1. **Preview button** in menu bar dropdown — `overlayCoordinator.previewBriefPanel()` with a hardcoded sample pageID (mirrors `previewContextPanel()`)
2. **Real meeting test** — throwaway calendar event titled to match an existing brief; verify auto-match at 5-min mark
3. **Manual attach** — attach a brief to an unrelated meeting; verify persistence across app restart
4. **No-match state** — nonsense-titled event; verify "No brief found" card renders
5. **Ad-hoc meeting** — `startAdHocMeeting`; verify it skips auto-match (no calendar title) and shows "Attach brief…"
6. **Token missing** — clear Keychain token; verify graceful error state

## Files

| File | Change |
|---|---|
| `Services/PreCallBriefService.swift` | NEW — match, fetch, markdown conversion |
| `Models/PreCallBrief.swift` | NEW — `PreCallBrief`, `BriefMatch` |
| `Views/BriefPanelView.swift` | NEW — view + `BriefPanelWindowController` |
| `MeetingReminderApp.swift` | Wire `BriefPanelWindowController` into `OverlayCoordinator` |
| `Views/MenuBarView.swift` | Brief icon on event rows |
| `Views/ContextPanelView.swift` | New "Pre-Call Brief" row |
| `Views/SettingsView.swift` | New Notion Briefs settings |
| `MeetingReminder.xcodeproj/project.pbxproj` | Register the 3 new files |

## Future generalisation

The data source ID is user-editable in Settings. Expanding to other Notion content later becomes "point at a different DB, reuse the matching pipeline". The abstraction over "what kind of Notion content gets surfaced when" is deferred until there's a second use case to shape it — YAGNI.
