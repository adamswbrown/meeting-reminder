# Intraday Pre-Call Briefings

The local, working-hours counterpart to the cloud **"Co Work" Daily Pre-Call Briefing**
task. When a genuinely-new meeting lands on the monitored work calendar **during the day
(09:00–17:00, Mon–Fri)**, the app fires a headless `claude` run that briefs it within
~2 minutes — following the *same rules* as Co Work, but delivering through local CLIs.

Design + full validation trail:
[docs/plans/2026-07-28-reactive-precall-briefing-trigger-design.md](plans/2026-07-28-reactive-precall-briefing-trigger-design.md).

---

## Why this exists

Co Work runs on a schedule (~3×/day). A meeting booked *between* runs goes un-briefed
until the next run or a manual trigger. This catcher closes that same-day gap with **zero
idle spawns** — it only runs when a new meeting actually appears.

## Architecture (two independent runners)

| | **Co Work (cloud)** | **App intraday catcher** |
|---|---|---|
| Trigger | ~03:00 schedule | a new meeting, 09:00–17:00 |
| Ruleset | `breifingskill.txt` | derived skill, **same rules** |
| Delivery | its MCP servers | **`imessage-tools` + `remctl` CLIs** |
| Scope | morning digest + reconcile | Template C change alerts only |

Delivery **diverges by design** (the interactively-authenticated MCP servers are absent in
a headless spawn; local CLIs over Bash are not). The two runners interoperate purely
through shared state — same Notion Pre-Call Briefings DB, same "Daily Briefing" Reminders
list, same `#AI-` action-item hashes — so neither double-briefs.

## How it works

- **`PreCallBriefTriggerService`** subscribes to `CalendarService.$events` (EventKit —
  always live, independent of the Notion sync toggle). It baseline-seeds the current diary
  on launch (no launch storm), then on a genuinely-new, non-all-day meeting starting later
  today it debounces 30s, floors runs at 120s, runs serially, and persists fired IDs.
- On fire it background-spawns `claude --print` with the **derived skill** and substitutes
  the target meeting. The skill re-derives everything from the Outlook ICS feed + Notion,
  so no Notion Calendar Events row needs to pre-exist.
- It parses the skill's final `INTRADAY_RESULT: …` line and logs to
  `~/Library/Logs/MeetingReminder/precall-brief-intraday.log`.
- Only meetings on the app's **monitored calendars** (`enabledCalendarIDs`) qualify — i.e.
  your work calendar, not personal ones.

The derived skill lives at `automation/pre-call-briefing-intraday.md` — **gitignored**
because it embeds the private Outlook ICS feed URL. It is `breifingskill.txt`'s rules with
three deltas: CLI delivery, Template-C-only, intraday scope.

---

## Setup

### 1. Prerequisites (CLIs)

| Tool | Purpose | Install |
|------|---------|---------|
| `claude` | runs the briefing skill headless | Claude Code CLI (`/usr/local/bin/claude`) |
| `imessage-tools` | sends the Template C iMessage | `git clone https://github.com/benelser/imessage-tools && cd imessage-tools && bun install && bun link` → `~/.bun/bin/imessage-tools` |
| `remctl` | syncs action items to Reminders | [viticci/remctl](https://github.com/viticci/remctl) `./install.sh --bootstrap` → `~/bin/remctl` |

Requires **Bun** (`brew install oven-sh/bun/bun`) and **Node ≥ 22**.

### 2. The skill file

Place the derived skill at `automation/pre-call-briefing-intraday.md` (already present on
Adam's machine; gitignored). The service reads it from
`~/Developer/meeting-reminder/automation/pre-call-briefing-intraday.md` by default
(override via the `preCallBriefSkillPath` UserDefault).

### 3. Enable + grant permissions

**Settings → Notion → Calendar Sync → Intraday Pre-Call Briefings:**

1. Toggle **"Auto-brief new meetings during the day (09:00–17:00)"** on.
2. Click **"Grant permissions…"** — approve the two prompts:
   - *"MeetingReminder wants to control Messages"* → **OK** (Automation → Messages)
   - Reminders access → **Allow**

   > These two System Settings panes have **no `+` button** — an app can only appear there
   > after it programmatically requests access, which this button does. macOS may only show
   > each prompt once.

3. **Full Disk Access** (this pane *does* have a `+`): System Settings → Privacy & Security
   → Full Disk Access → **+** → add **MeetingReminder**. (Needed because `imessage-tools`
   and `remctl` read `~/Library/Messages/chat.db` and the Reminders store.)

The spawned `imessage-tools` / `remctl` inherit **MeetingReminder.app** as the
TCC-responsible process, so granting the app covers them.

---

## Testing

Create a calendar event on the **monitored work calendar** for a **future time today**
(any time — the gate only checks that *now* is within 09:00–17:00), then:

```bash
tail -f ~/Library/Logs/MeetingReminder/precall-brief-intraday.log
```

Expect: `firing intraday brief for: <title>` → `result: INTRADAY_RESULT: created=1 …`,
a new page in the Notion Pre-Call Briefings DB, and a Template C iMessage.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Nothing fires | Event not on a monitored calendar (`enabledCalendarIDs`), all-day, in the past, or outside 09:00–17:00. Baseline is seeded at launch, so only meetings appearing *after* launch fire. |
| `INTRADAY_RESULT: … imessage=failed` | App lacks **Automation → Messages**. Click **Grant permissions**. |
| `remctl` errors in the log | App lacks **Reminders** access or **Full Disk Access**. |
| `result: … brief=-` and errors | Check the Notion **Run Log** row (`intraday`) — the skill preserves the exact error and the undelivered alert verbatim there. |
| Duplicate briefs | Shouldn't happen — the skill's Step 3 property-filter dedup is authoritative against the shared DB. |

## Settings (UserDefaults)

| Key | Default | Description |
|-----|---------|-------------|
| `preCallBriefTriggerEnabled` | false | Master toggle |
| `preCallBriefCLIPath` | `/usr/local/bin/claude` | Path to the `claude` binary |
| `preCallBriefSkillPath` | `~/Developer/meeting-reminder/automation/pre-call-briefing-intraday.md` | The derived skill |
| `preCallBriefMinIntervalSeconds` | 120 | Floor between runs |
| `preCallBriefFiredIDs` | [] | Apple Event IDs already triggered (dedup) |
