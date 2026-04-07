# MeetingReminder ADHD Feature Roadmap

A refined feature plan for making MeetingReminder a genuinely useful tool for users with ADHD, with Notion integration as the primary meeting notes platform.

---

## 1. Time Blindness

These features keep time visible and ambient so the user never has to actively check.

### 1.1 Persistent Menu Bar Countdown
Show the next meeting countdown directly in the menu bar text: `"Standup in 12m"`. Updates every minute (every 10s under 5 minutes). No clicking required — time is always visible.

### 1.2 Progressive Alerts (Escalating Urgency)
Instead of a single reminder, layer multiple nudges with increasing intensity:

| Time Before | Alert Type | Behaviour |
|-------------|-----------|-----------|
| 15 min | Menu bar text turns yellow | Ambient only |
| 10 min | Gentle banner notification | "Start wrapping up — Standup in 10 min" |
| 5 min | Menu bar turns orange, optional chime | Harder to ignore |
| 2-3 min | Full-screen overlay (current behaviour) | Blocking, must interact |
| 0 min (start) | Overlay re-fires if not dismissed | Last chance |

Each tier is independently configurable so the user can dial in what works for them.

### 1.3 Colour-Coded Menu Bar Icon
The menu bar icon shifts colour based on proximity to the next meeting:
- **Green** — >30 min or no meetings
- **Yellow** — 15-30 min
- **Orange** — 5-15 min
- **Red** — <5 min or in progress

Provides at-a-glance awareness without reading any text.

---

## 2. Hyperfocus Interruption

These features are designed to break through deep focus without being harmful.

### 2.1 Aggressive Snooze Option
Add a "micro-snooze" (30 seconds) alongside the existing 1-minute snooze. If snoozed, the overlay returns quickly — making it genuinely difficult to forget and fall back into hyperfocus.

### 2.2 Gentle Screen Dimming
Gradually reduce screen brightness starting ~5 minutes before a meeting. This creates a subtle environmental cue that something is changing.

**Safety considerations (epilepsy):**
- Dimming is slow and gradual (linear over 5 minutes), never sudden or flickering
- No strobing, flashing, or rapid transitions
- Maximum dim to ~70% brightness (never fully dark)
- User can disable entirely in settings
- Respects system accessibility settings (Reduce Motion)

### 2.3 Forced Context-Switch Prompt
A non-blocking but persistent floating message: *"Save your work — you need to switch in 3 minutes."* Stays on screen but doesn't block interaction. Designed to give the executive function system a head start on the transition.

---

## 3. Transition Support

### 3.1 "Wrap Up" Menu Bar Nudge
A gentle pre-reminder that lives **in the menu bar only** (not an overlay or notification). At 10-15 minutes before a meeting, the menu bar text changes to something like `"Wrap up - Standup in 12m"`. This is screen-share safe — nothing pops up on the display that others would see.

### 3.2 Pre-Meeting Checklist
A small, movable checklist window that appears alongside the overlay. Configurable items such as:
- Close unnecessary tabs
- Get water/coffee
- Open meeting notes
- Review agenda
- Check action items from last meeting

Could support both a **global default checklist** and **per-calendar overrides** (e.g. different prep for 1:1s vs all-hands).

### 3.3 Notion Meeting Prep Integration
When the reminder fires, automatically:
1. Open the user's Notion Meeting Notes database
2. Pre-create a new page for this meeting with:
   - Meeting title
   - Date/time
   - Attendees (from calendar invite)
   - Agenda (from calendar description)
   - Link to video call
3. Open the new page in the browser so the user lands ready to take notes

This removes the friction of "where do I put my notes?" and "let me find the right database" — the page is just there, ready.

---

## 4. Working Memory

### 4.1 Meeting Context Panel
A **movable, semi-transparent overlay window** (not full-screen) that shows:
- Meeting title and time
- Attendees list
- Agenda / description from the calendar invite
- Video link (clickable)
- Attached documents or links

This floats on screen and can be repositioned. The user can glance at it mid-meeting to remember context without switching apps. Think of it as a persistent "what is this meeting about?" card.

### 4.2 "What Was I Doing?" Bookmark
When the user clicks **Join** on the overlay, capture their current context:
- The **frontmost application** (not just a URL — could be Xcode, Figma, Terminal, etc.)
- The **window title** if accessible (gives hints like the file or project)
- Optionally the current **browser URL** if the frontmost app is a browser

After the meeting ends, display a small nudge: *"Before the meeting you were in: Xcode — MeetingMonitor.swift"* with a button to reopen/refocus that app.

**Implementation note:** This requires accessibility permissions (to read window titles) and investigation into what macOS APIs expose for frontmost app state. Worth a spike to determine feasibility and permission scope.

### 4.3 Post-Meeting Nudge with Notion Integration
5 minutes after a meeting ends, show a non-blocking prompt:
- *"Capture action items from Standup?"*
- Button to open the Notion meeting notes page (the one pre-created in 3.3)
- If Notion AI has already generated meeting notes/action items, surface a summary

This fights the ADHD tendency to think "I'll write that down later" and then forget entirely.

---

## 5. Meeting Fatigue & Overload

### 5.1 Daily Meeting Load Indicator
Show meeting density in the menu bar dropdown:
- *"6 meetings today (4.5 hours of meetings)"*
- *"3 back-to-back blocks"*
- *"Next break: 2:30 PM"*

Gives the user awareness of their day's cognitive load at a glance.

### 5.2 Break Enforcement
When back-to-back meetings are detected (< 5 min gap), automatically insert a **5-minute "decompress" overlay** between them:
- *"Take a breather before your next meeting"*
- Countdown timer
- Suggestions: stretch, get water, breathe
- Option to skip if not needed

Prevents the burnout of jumping straight from one meeting to the next.

### 5.3 Decline Assist
Flag meetings that are likely optional and make declining frictionless:
- Detect "optional" in invite text, large attendee lists, or FYI-style meetings
- Surface a **"Decline with template"** button in the menu bar event list
- Pre-written templates:
  - *"Protecting focus time today — please share notes/recording"*
  - *"Won't be able to join — happy to async on action items"*
  - *"Declining to avoid back-to-back overload — will review notes"*

Reduces the executive function cost of saying no.

---

## 6. Notion Integration (Core)

Notion is the primary meeting notes platform. Integration should cover:

### 6.1 Meeting Notes Database Connection
- Configure the Notion Meeting Notes database ID in settings
- Authenticate via Notion API (internal integration token)
- Auto-detect database properties (Title, Date, Attendees, etc.)

### 6.2 Auto-Create Meeting Page
Triggered when the meeting reminder fires:
- Creates a new page in the configured database
- Populates: title, date/time, attendees, agenda, video link
- Opens the page in the browser
- Stores the page ID so post-meeting features can reference it

### 6.3 Post-Meeting Action Item Pull
After a meeting ends:
- Query the Notion page for content (especially if Notion AI has generated a summary)
- Surface action items in the post-meeting nudge
- Optionally create linked tasks in a separate Notion database

---

## Implementation Priority

Suggested order based on impact vs effort:

### Phase 1 — Quick Wins (Current Architecture)
1. Persistent menu bar countdown (1.1)
2. Colour-coded menu bar icon (1.3)
3. Aggressive snooze / micro-snooze (2.1)
4. Wrap-up menu bar nudge (3.1)
5. Daily meeting load indicator (5.1)

### Phase 2 — Enhanced Overlay
6. Progressive alerts (1.2)
7. Meeting context panel (4.1)
8. Pre-meeting checklist (3.2)
9. Break enforcement (5.2)
10. Gentle screen dimming (2.2)

### Phase 3 — Notion Integration
11. Notion database connection (6.1)
12. Auto-create meeting page (6.2)
13. Post-meeting nudge (4.3)
14. Post-meeting action item pull (6.3)
15. Notion meeting prep integration (3.3)

### Phase 4 — Advanced
16. "What was I doing?" bookmark (4.2)
17. Decline assist (5.3)
18. Forced context-switch prompt (2.3)

---

## Technical Considerations

- **Notion API:** Requires an internal integration token. The Notion MCP server is available in the current toolchain and could be leveraged for development/testing.
- **Accessibility permissions:** The "What Was I Doing?" bookmark needs accessibility access to read window titles. This adds a permission prompt the user must accept.
- **Screen dimming:** Uses `IODisplaySetBrightness` or `CoreDisplay` APIs. Must be tested thoroughly for safety. Should be off by default.
- **Menu bar text updates:** `MenuBarExtra` with `.window` style supports dynamic labels. Timer-driven updates at appropriate intervals.
- **Entitlements:** Calendar access is already granted. Notion integration adds network access (already available in sandbox with appropriate entitlement). Accessibility would need `com.apple.security.temporary-exception.apple-events` or similar.
