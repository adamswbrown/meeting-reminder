# Notion setup

Meeting Reminder uses Notion for two things:

1. **Meeting notes** — a page is created the moment you join a meeting, then opened in the Notion desktop app (Notion's own AI Meeting Notes block handles recording/summary).
2. **Calendar → Notion sync** — a scheduled push of your calendar into a *Calendar Events* ledger, with optional auto-linking to Meeting Notes and Pre-Call Briefings.

Both share **one** Notion integration token.

---

## Guided setup (recommended)

**Settings → Notion → "Set up Notion automatically…"** (also offered as an optional step in first-launch onboarding).

You do two things by hand; the app does the rest:

1. Create an internal integration at [notion.so/my-integrations](https://www.notion.so/my-integrations) and copy its **Internal Integration Secret**.
2. Share **one** Notion page with that integration (open the page → ••• → Connections → add the integration) and paste the page's URL.

The app then creates all five databases below **under that page**, with the schemas it expects, and connects itself to them automatically — no manual ID copying. When it finishes, the wizard offers links to open each new database in Notion.

> Running the wizard while Notion is already connected creates a **new, empty** set of databases and switches the app to them. Your existing Notion pages stay in place, but the app stops writing to them. Only do this for a fresh workspace.

---

## What gets created

Meeting Notes and Pre-Call Briefings are created first because Calendar Events links to them (a two-way relation, so the inverse link appears on both sides automatically).

### 1. Meeting Notes
A page per meeting you join; also a link target for the calendar sync.

| Property | Type |
|---|---|
| Title | title |
| Start | date |
| End | date |
| Attendees Name | rich_text |

### 2. Pre-Call Briefings
Prep notes surfaced in the floating pre-call brief panel; also a link target for the sync.

| Property | Type |
|---|---|
| Meeting Title | title |
| Date & Time | date |
| Customer / Partner | select |
| Attendees | rich_text |
| Briefing Status | select (Draft / Ready) |

### 3. Calendar Events
The synced ledger of your calendar.

| Property | Type | Notes |
|---|---|---|
| Title | title | |
| Date | date | |
| All Day | checkbox | |
| Status | select | Cancelled / Today / Upcoming / Past |
| Availability | select | Busy / Free / Tentative / OOO / Unknown |
| Calendar | select | source calendar label |
| Source Calendar | select | source calendar label (multi-calendar) |
| Organiser | rich_text | |
| Attendees | rich_text | |
| Attendee Count | number | |
| Has External Attendees | checkbox | |
| Location | rich_text | |
| Conference URL | url | |
| Description | rich_text | |
| Recurring | checkbox | |
| Series Master | checkbox | |
| Apple Event ID | rich_text | upsert key |
| iCal UID | rich_text | |
| Sync State | select | Active / Stale / Orphaned |
| Last Synced | date | |
| Meeting Notes | relation → Meeting Notes | two-way |
| Pre-Call Briefing | relation → Pre-Call Briefings | two-way |

### 4. Cal Sync Skip List
Add rows here to exclude meetings from the calendar sync.

| Property | Type |
|---|---|
| Meeting Title | title |
| Match Type | select (Exact Title / Title Contains) |
| Active | checkbox |

### 5. Cal Sync Migrations
Append-only log of schema changes. App-managed — don't edit.

| Property | Type |
|---|---|
| Migration ID | title |
| Applied At | date |
| Description | rich_text |

---

## Advanced / manual setup

**Settings → Notion → "Advanced — enter IDs manually"** exposes the raw token and database ID fields, for anyone who already has compatible databases and wants to point the app at them directly instead of creating new ones.
