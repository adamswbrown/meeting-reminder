# Intraday Pre-Call Briefings

The local, working-hours counterpart to the cloud **"Co Work" Daily Pre-Call Briefing**
task. When a genuinely-new meeting lands on the monitored work calendar **during the day
(09:00–17:00, Mon–Fri)**, the app fires a headless `claude` run that briefs it within
~2 minutes — following the *same rules* as Co Work, delivering the alert to **Slack**
(Apple Reminders still sync via the local `remctl` CLI).

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
| Delivery | **Slack** `chat.postMessage` | **Slack** `chat.postMessage` + `remctl` (Reminders) |
| Scope | morning digest + reconcile | Template C change alerts only |

Both runners now deliver messaging to the **same Slack channel** (`#daily-breifings`,
`C0BMEG01M1N`) via a plain `chat.postMessage` HTTPS call — the bot token lives in the
Keychain (`com.meetingreminder.app` / `slackBotToken`). This is a stateless HTTPS call, so
it works identically from the headless spawn; the old "MCP servers absent in a headless
run" divergence is gone. The only local-CLI dependency left in the intraday catcher is
`remctl` for Apple Reminders. The two runners still interoperate purely through shared
state — same Notion Pre-Call Briefings DB, same "Daily Briefing" Reminders list, same
`#AI-` action-item hashes — so neither double-briefs.

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
three deltas: Slack delivery + `remctl` Reminders, Template-C-only, intraday scope.

### Working-hours gate (imminent exemption + started grace)

`IntradayBriefGate` decides, per meeting, whether to **fire now**, **wait**, or **drop**,
replacing the old "blanket-defer everything outside 09:00–17:00" check. It closes a
dead-zone where a meeting starting *at* the 09:00 boundary was un-briefable — deferred to
09:00, then discarded by the "already-started" drop the instant it arrived:

- **Imminent exemption (A):** a meeting that starts *before* the next working-window opens
  fires now even outside hours (the only chance to brief before it starts). One that starts
  *at/after* the open waits for the window — so an evening/early-morning booking for a 09:00
  meeting doesn't ping Slack the night before.
- **Started grace (C):** the "already-started" drop tolerates 5 minutes, so a boundary
  meeting isn't lost in the detection → 30s debounce → drain race, and a brief for a
  just-started meeting still lands.

### Removal & reschedule detection (REMOVED mode)

The same service also watches for meetings that **disappear** from the diary during the
day and fires the skill in **REMOVED mode** so you get a Slack update:

- A candidate is a meeting that was present on the previous emission, is **absent now**, and
  **still starts in the future** — a meeting that merely *started* (its time passed) is
  never treated as a removal.
- A move usually surfaces as a same-title event vanishing at one time and reappearing at
  another. `IntradayDiffClassifier` pairs those into a **single reschedule**, so a moved
  meeting fires one `🔁 moved` post rather than a `❌ cancelled` *and* a `🆕 new meeting`.
  Unpaired disappearances are cancellations.
- On fire, the app spawns the skill with `{{TRIGGER_MODE}} = REMOVED`. The skill
  **re-derives cancel-vs-moved authoritatively** from the ICS + Notion Calendar Events
  (never trusting the app's guess) and posts one Template C line — `🔁 [old→new]` or
  `❌ [cancelled]` — while marking the Notion row/brief (`Meeting Outcome = Cancelled`, or
  updating the brief's `Date & Time`). It never briefs or creates a page in this mode.
- Removals share the brief queue's drain, floor, gate, and single-in-flight guard (only one
  `claude` ever runs), and have their own persisted fired-ID set
  (`preCallBriefRemovalFiredIDs`) so a briefed meeting that later cancels can still notify.
- **Note:** a cancelled meeting only *leaves* `CalendarService.events` because cancelled
  (`EKEventStatus.canceled`) events are now filtered out at fetch time — otherwise an
  Exchange cancellation lingers as a struck-through event and never disappears. That filter
  is also what stops a cancelled meeting from lingering in the **menu bar**.

---

## Setup

### 1. Prerequisites (CLIs)

| Tool | Purpose | Install |
|------|---------|---------|
| `claude` | runs the briefing skill headless | Claude Code CLI (`/usr/local/bin/claude`) |
| Slack bot token | sends the Template C alert to `#daily-breifings` via `chat.postMessage` | Create a bot app at api.slack.com/apps with `chat:write` + `chat:write.public`; store the `xoxb-…` token in Keychain: `security add-generic-password -U -s com.meetingreminder.app -a slackBotToken -w '<token>'`. No install, no daemon. |
| `remctl` | syncs action items to Reminders | [viticci/remctl](https://github.com/viticci/remctl) `./install.sh --bootstrap` → `~/bin/remctl` |

`remctl` requires **Node ≥ 22**. Slack delivery needs only `curl` + `python3` (both preinstalled).

### 2. The skill file

Place the derived skill at `automation/pre-call-briefing-intraday.md` (already present on
Adam's machine; gitignored). The service reads it from
`~/Developer/meeting-reminder/automation/pre-call-briefing-intraday.md` by default
(override via the `preCallBriefSkillPath` UserDefault).

### 3. Enable + grant permissions

**Settings → Notion → Calendar Sync → Intraday Pre-Call Briefings:**

1. Toggle **"Auto-brief new meetings during the day (09:00–17:00)"** on.
2. Click **"Grant permissions…"** — approve the **Reminders access → Allow** prompt.

   > Slack delivery needs **no** macOS permission — it's an outbound HTTPS call, not a
   > local app being automated. The old *"MeetingReminder wants to control Messages"*
   > Automation prompt is no longer required now that iMessage is gone.
   >
   > This Reminders pane has **no `+` button** — an app can only appear there after it
   > programmatically requests access, which this button does. macOS may only show the
   > prompt once.

3. **Full Disk Access** (this pane *does* have a `+`): System Settings → Privacy & Security
   → Full Disk Access → **+** → add **MeetingReminder**. (Needed because `remctl` reads the
   Reminders store. `chat.db` / Messages access is no longer needed.)

The spawned `remctl` inherits **MeetingReminder.app** as the TCC-responsible process, so
granting the app covers it. Slack delivery just reads the bot token from Keychain.

---

## Testing

Create a calendar event on the **monitored work calendar** for a **future time today**
(any time — the gate only checks that *now* is within 09:00–17:00), then:

```bash
tail -f ~/Library/Logs/MeetingReminder/precall-brief-intraday.log
```

Expect: `firing intraday brief for: <title>` → `result: INTRADAY_RESULT: created=1 …`,
a new page in the Notion Pre-Call Briefings DB, and a Template C alert in the
`#daily-breifings` Slack channel.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Nothing fires | Event not on a monitored calendar (`enabledCalendarIDs`), all-day, in the past, or outside 09:00–17:00. Baseline is seeded at launch, so only meetings appearing *after* launch fire. A meeting starting *at* the 09:00 boundary is handled by the gate's imminent exemption + started grace. |
| A cancelled meeting fires no update | A removal is only detected when the event *leaves* `CalendarService.events`. Exchange deletions can lag a couple of minutes to sync locally; cancelled (`.canceled`) events are filtered at fetch. If the meeting merely *started* (its time passed) it's intentionally not treated as a removal. |
| Reschedule sent a "cancelled" + a "new meeting" instead of one "moved" | Same-emission moves are paired into one reschedule; a move split across emissions (remove seen, add seen minutes later, after the removal already fired) can double-post. The skill's Notion dedup mitigates the second post. |
| `INTRADAY_RESULT: … imessage=failed` | Slack post failed. Check the bot token in Keychain (`slackBotToken`), that the token has `chat:write`+`chat:write.public`, and network. (The `imessage=` token is a legacy machine name — it now reports the **Slack** send; the app still parses it to raise the failure notification.) |
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
| `preCallBriefFiredIDs` | [] | Apple Event IDs already briefed (NEW-mode dedup) |
| `preCallBriefRemovalFiredIDs` | [] | Apple Event IDs already notified as removed/moved (REMOVED-mode dedup) |
