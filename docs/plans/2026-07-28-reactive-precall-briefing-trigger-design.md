# Reactive pre-call briefing trigger (new meeting → briefing)

**Date:** 2026-07-28
**Status:** Design approved — **Hybrid chosen** (keep cloud runs as backstop + add a Mac
app reactive trigger). Headless parity **validated** (delivery + Reminders gaps closed via
`imessage-tools` + `remctl` CLIs over Bash). Not yet implemented. Next: ruleset CLI edits,
then `PreCallBriefTriggerService`.

## Problem

Pre-call briefings are produced by the **Daily Pre-Call Briefing Agent** — a Claude
skill whose canonical ruleset lives at `breifingskill.txt` in this repo (~1560 lines).
It is a full pipeline, not just a page-writer: it loads Notion settings + skip list,
resolves Customer/Partner via mapping rules, detects White Glove meetings and
looks-up/creates PSCI Jira issues, pulls prior history, enriches new contacts, writes
the 🎯 Pre-Call Briefings page, syncs action items to Apple Reminders (with `#AI-xxxxxx`
hash join keys), sends an iMessage digest, raises config Suggestions, and writes a Run
Log row.

Adam wants: **when a new meeting lands, a briefing is created automatically — following
this exact ruleset — without him remembering to run anything.**

## Key finding — the ruleset is already built for this

The gap is smaller than it first appeared. `breifingskill.txt` is explicitly designed to
be fired frequently and reactively:

- **Header:** *"This task fires every ~15 min on weekdays, so MOST runs have nothing to
  do."*
- **Step 0.0 — fast early-exit gate:** a no-op tick costs ~3 Notion queries + 1 Run Log
  write. It only runs the full workflow on the day's first run, or on a re-run where
  "work exists" (a Calendar Events row with an empty `Pre-Call Briefing` relation, a
  cancellation, a reschedule, or an orphaned brief).
- **Step 1C:** names the Mac app's **📅 Calendar Events** DB
  (`collection://1d605620-3b70-47f1-96d8-465e57fd0bdd`), kept fresh by the app's reactive
  sync (~2 min), as *"the primary trigger source for auto-briefing"* — *"this is what
  makes a meeting that lands mid-day get a brief + alert within one poll."*
- **Step 2B — incremental gate:** the expensive per-meeting steps (partner resolution, WG
  Jira, history, enrichment, page create, Reminders) run **only** over `meetings_to_brief[]`
  (net-new). A re-run with nothing new creates no pages.

So **the idle-token-cost objection is already handled by Step 0.0** — the ruleset was
written to be run often and bail cheaply. The only open question is *what fires it*.

### ROOT CAUSE (Run Log evidence, 2026-07-28)

The ruleset is *written* for ~15-min cadence but is **not actually firing that often.**
The Run Log (`collection://e3037433-231b-4ee5-af0e-81fcddefd6a6`) shows only **two runs
on 2026-07-28**: `03:07 BST` (morning full run) and `09:52 BST` (real-work re-run) —
~6 hours apart. It fires ~3×/day (matching the three installed scheduled tasks
`pre-call-briefings{,-midday,-afternoon}`), not every 15 min.

Worked example of the miss: "Customer Assessment / Discovery – Walkers" reached the
Calendar Events DB at **10:57** (empty briefing relation = "work exists" per Step 0.0(a)),
but there was **no run between 09:52 and ~14:30**, so it sat un-briefed until created by
hand. The engine is correct; the **trigger cadence is the bug.**

Corollary: **do not build a simplified single-meeting variant.** "Follow the same
ruleset" means invoke `breifingskill.txt` itself and let its own gates scope the work.
(The 2026-07-28 Walkers test brief was a simplified proof only — it lacked WG detection,
`#AI-` hashes, Reminders, iMessage and the Run Log. It is not ruleset-compliant.)

## What fires it — two options

### Option 1 — 15-minute cloud cron (no app code)
Schedule `breifingskill.txt` every ~15 min on weekdays via the cloud scheduler
("Co-Work"). This is literally what the ruleset's header assumes. Step 0.0 keeps no-op
ticks cheap. **Zero Swift.** Costs: a small per-tick overhead (the gate's ~3 queries +
the model reasoning to run it) across ~30–40 weekday ticks, and it fires even when the
Mac is asleep (harmless — it just finds no work).

This is likely the *intended* deployment that isn't fully wired up yet: the only tasks
installed locally are the older, simpler 3×/day skills
(`~/.claude/scheduled-tasks/pre-call-briefings{,-midday,-afternoon}/SKILL.md`), not this
15-min ruleset.

### Option 2 — Mac app reactive trigger (Swift, zero idle ticks)
The always-on app fires the ruleset **only when reactive sync detects a real calendar
change**, so there are *no* idle ticks at all — strictly more token-efficient than the
cron. Aligns with Step 1C's stated intent (the app's Calendar Events write is the trigger).

**The app does not need to classify the change** — it just runs the ruleset and lets
Step 0.0 decide if work exists. The service is thin:

- Observe reactive sync completing with ≥1 created/changed upcoming row (or, more simply,
  any `runReactive()` that wrote anything). Debounce.
- Background-spawn `claude --print` pointed at the `breifingskill.txt` skill.
- Serialize: never start a run while one is in flight (the ruleset assumes one run at a
  time — concurrent runs would race the dedupe).
- Skip firing during the 06:00 full-window backfill (let the cloud "first run of the day"
  own the morning digest), and outside working hours.

### Decision — divergent-delivery Hybrid (2026-07-28, confirmed by Adam)
Two independent runners that share Notion state and never edit each other:

| | **Co Work (cloud) — unchanged** | **App reactive catcher — NEW** |
|---|---|---|
| Owner | Claude Co Work | this Mac app |
| Trigger | 3am schedule (+ its existing runs) | a new meeting landing, **09:00–17:00** working day |
| Ruleset | `breifingskill.txt` verbatim | **same rules**, own local artifact |
| Delivery | its MCP servers (iMessage/Reminders) | **CLIs** (`imessage-tools` + `remctl`) |
| Scope | morning digest (Template A/B) + backstop | **Template C change alerts only** (net-new / reschedule / cancellation intraday) |

**Divergent delivery is explicitly fine** (Adam): Co Work keeps its MCP delivery; the app
uses CLIs. They interoperate purely through shared state — same Pre-Call Briefings DB, same
Run Log, same "Daily Briefing" Reminders list, same `#AI-` hashes — so Step 2B/4 dedup
means neither double-briefs. **No Co Work edits by anyone.** The app run is *always* a
"re-run" in ruleset terms (`is_first_run_today=False`, since Co Work ran at 3am) → it only
ever emits Template C, never the full digest.

The app artifact is a **derived skill**: identical rules to `breifingskill.txt`, differing
only in (a) delivery via CLIs, (b) Template-C-only intraday scope, (c) the working-hours
gate is the app's 09:00–17:00 firing window. I author this; it does not modify the Co Work
ruleset.

### Build sequence
1. ~~**Validate headless parity (make-or-break).**~~ ✅ DONE 2026-07-28. `imessage-tools` +
   `remctl` both work from a headless spawn (`HEADLESS_RESULT: imessage=ok reminder=ok`).
2. **Author the derived intraday skill** — same rules, CLI delivery, Template-C-only.
   (Co Work ruleset untouched.)
3. **Confirm the trigger signal.** Reconcile `calendarNotionSyncReactiveEnabled` (reads
   unset, yet rows update intraday) and that a new meeting reliably lands in the Calendar
   Events DB within ~2 min — the signal the catcher keys on.
4. **Validate app-spawned TCC.** The headless proof used a terminal-launched `claude`
   (which holds FDA/Automation/Reminders). Confirm the grants hold when **MeetingReminder.app**
   is the responsible process (likely a one-time per-binary System Settings grant).
5. **Build `PreCallBriefTriggerService`** per the design below.
6. **Ship behind `preCallBriefTriggerEnabled` (default off);** Co Work stays the backstop.

## Headless capability matrix (resolved 2026-07-28)

What a **headless `claude --print`** run needs, and how each is met:

| Capability | Mechanism | Headless status |
|---|---|---|
| Notion (read + write briefings) | claude.ai Notion MCP | ✅ proven |
| Web search (contact enrichment) | built-in | ✅ proven |
| Jira PSCI (WG lookup/create) | claude.ai Atlassian Rovo MCP | ✅ proven (lookup ran in the 15:42 full run) |
| ICS recurrence expansion | Python (`icalendar`) over Bash | ✅ proven |
| iMessage delivery | **`imessage-tools` CLI over Bash** | ✅ proven from a headless spawn |
| Apple Reminders sync | **`remctl` CLI over Bash** | ✅ proven from a headless spawn |

The lesson: **interactively-authenticated MCP servers (Reminders/iMessage/Mail) are absent
in a background spawn; local CLIs over Bash are not.** Preferring CLIs removes the only
real headless risk. TCC (FDA / Automation / Reminders) was confirmed to propagate through
app → `claude` → `bun`/`remctl`.

## Feasibility validation (2026-07-28)

Two headless `claude --print --dangerously-skip-permissions` runs were done.

**Run 1 — simplified single-meeting prompt** (proved the mechanism):

| Assumption | Result |
|---|---|
| Headless `claude -p` runs a briefing prompt | ✅ |
| Notion MCP works headless (read + write) | ✅ |
| Dedup / idempotency | ✅ "HMC DC Assessment" correctly **skipped** (already briefed 09:02) |
| Create path | ✅ a page was created and independently re-fetched from Notion |

**Run 2 — the FULL `breifingskill.txt` ruleset headless** (the make-or-break, 15:42 BST).
Result: the run completed (exit 0, ~450s), correctly ran Step 0.0/2B, created 1 brief
(BiotechUSA), linked both duplicate Calendar Events rows, raised a mapping suggestion, and
wrote a Run Log row. **Clean split on MCP parity:**

| Capability | Headless result |
|---|---|
| Notion (brief + suggestion + run log + link-back) | ✅ works |
| Jira PSCI (WG lookup) | ✅ works |
| ICS recurrence expansion (Python) | ✅ works |
| Web enrichment | ✅ works |
| **Apple Reminders sync** | ❌ backend absent → `reminders_ok=false`, run logs `Partial` |
| **iMessage delivery** | ❌ server absent (confirmed via `select:` ToolSearch) |
| **Apple Mail fallback** | ❌ absent |

**Conclusion:** the **content pipeline works fully headless; the delivery + Reminders
channels do not** — they are interactively-authenticated/local MCP servers that a
background `claude --print` spawn does not load. The ruleset degraded exactly as designed
(Partial, alert preserved in the Run Log). Nothing was lost; the brief is durable in Notion.

### Resolution — CLI-over-Bash closes BOTH headless gaps (validated 2026-07-28)
Rather than accept degraded delivery, we close both gaps by replacing the
interactively-auth'd MCP servers with **local CLIs invoked over Bash** — which the ruleset
already does for Python/ICS, and which do not depend on any MCP server loading in a
headless spawn:

| Gap | CLI | Path | Headless test |
|---|---|---|---|
| iMessage delivery | `imessage-tools` ([benelser/imessage-tools](https://github.com/benelser/imessage-tools)) | `~/.bun/bin/imessage-tools` | ✅ `send "adamswbrown@gmail.com" …` sent via iMessage from a background `claude --print` |
| Reminders sync | `remctl` ([viticci/remctl](https://github.com/viticci/remctl)) | `~/bin/remctl` | ✅ `add … -l "Daily Briefing"` created from a background `claude --print` |

Validation chain: read (FDA / Reminders) ✅ → write from *this* context (Automation for
Messages, EventKit for Reminders) ✅ → **write from a headless `claude --print` background
spawn** ✅ (`HEADLESS_RESULT: imessage=ok reminder=ok`). So **TCC propagates through
app → `claude` → `bun`/`remctl`** — the sole make-or-break. The email handle
`adamswbrown@gmail.com` resolves directly (no Step 8 recipient rework); `remctl` already
sees the existing **"Daily Briefing"** list (id 15).

**Consequence:** the app-triggered reactive run gets **full parity** — brief + iMessage
digest + Reminders sync — so the earlier native-notify compromise is **dropped**. The run
is the complete ruleset.

**Bonus:** adopting these CLIs also **stabilises the existing cloud scheduled runs**, which
have been logging `Partial` because Macuse (Reminders) and the iMessage server are
flaky/absent. Moving Step 4B/7B/8 to `remctl` + `imessage-tools` makes *every* run
(cloud + app) deliver reliably; Macuse can be retired.

### Delivery spec for the DERIVED intraday skill (not Co Work)
The derived skill implements Steps 8 / 4B / 7B against the CLIs instead of MCP servers.
Co Work's own `breifingskill.txt` is unchanged.
- **Step 8 (iMessage):** `~/.bun/bin/imessage-tools send "adamswbrown@gmail.com" "<Template C>"`.
  Intraday emits **Template C only**. Keep the Run-Log-verbatim fallback if the CLI errors.
- **Step 4B / 7B (Reminders):** `remctl show "Daily Briefing"` (pull open), `remctl add …
  -l "Daily Briefing"` (create), `remctl done <id>` (complete), `remctl delete <id>
  --force` (non-interactive). `#AI-xxxxxx` hash tags stay in the reminder title/notes as the
  join key — **shared with Co Work's MCP-written reminders**, so completions propagate both
  ways across the two runners.

## Design

### Invoked skill
The app invokes the **derived intraday skill** (own artifact, same rules, CLI delivery,
Template-C-only — see "Delivery spec"). Installed under `~/.claude/` (or passed via stdin).
The skill re-derives today's meetings from the **ICS feed + Pre-Call Briefings DB itself**,
so it does not depend on the Calendar Events row pre-existing.

### `PreCallBriefTriggerService` (Mac app)
`Services/PreCallBriefTriggerService.swift`:
- **Signal — EventKit directly, NOT the Notion reactive sync.** Key off
  `CalendarService`'s existing `.EKEventStoreChanged` + wake observers (already `object:nil`,
  already reliable). Rationale: the Calendar→Notion sync reads *disabled* on this machine
  (`calendarNotionSyncEnabled`/`…ReactiveEnabled` both unset ⇒ false), so its "created row"
  is not a trustworthy signal — but EventKit change detection is always live and the derived
  skill re-derives from ICS anyway. This decouples the catcher from the Notion-sync toggle.
- **New-meeting detection:** on each EventKit change, diff the fetched upcoming events against
  a persisted `preCallBriefFiredIDs` set (keyed on `EKEvent.calendarItemExternalIdentifier`);
  a genuinely-new event that **starts within the working day and after now** is a candidate.
- **Working-day gate:** only fire **09:00–17:00** Mon–Fri (Adam's window; the derived skill
  re-checks the ⚙️ Daily Briefing Settings hours too). Outside that, do nothing — the 3am
  Co Work run + its schedule own everything else.
- **Debounce + serialize:** coalesce bursts (30s), a single in-flight `claude` run, a floor
  (~2 min) between runs.
- **Invoke:** background `Process` → `claude --print` with the derived skill. Off the main
  actor. Parse the final `BRIEFING_CREATED`/`SKIPPED` line + Run Log outcome; log locally.
- **Guards:** record fired IDs so a meeting never re-fires; the skill's own Step 4 dedup is
  the second line of defence (and what keeps it from colliding with Co Work's briefs).

### Settings (UserDefaults)
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `preCallBriefTriggerEnabled` | Bool | false | Master toggle for the app-driven intraday catcher |
| `preCallBriefCLIPath` | String | "/usr/local/bin/claude" | Path to the `claude` binary |
| `preCallBriefSkillPath` | String | (derived skill path) | The intraday skill the run executes |
| `preCallBriefMinIntervalSeconds` | Int | 120 | Floor between app-triggered runs |
| `preCallBriefFiredIDs` | [String] | [] | Apple Event IDs already triggered (dedup) |

**No dependency on `calendarNotionSyncReactiveEnabled`** — the catcher keys on EventKit.
Surfaced in **Settings → Notion → Calendar Sync**, near the reactive-sync toggle.

## Data flow

```
new meeting booked 09:00–17:00 (after Co Work's 3am run)
  → EKEventStoreChanged (CalendarService, always live) → fetchEvents()
  → PreCallBriefTriggerService: new event id? starts today & future? working hours?
    not already fired? no run in flight?
  → background `claude --print` runs the DERIVED intraday skill
     → same rules: Step 0.0/2B/4 dedup against Pre-Call Briefings DB (shared with Co Work)
     → partner/WG/history/enrich/page + link-back
     → delivery via CLIs: remctl (Reminders) + imessage-tools (Template C alert)
     → Run Log row
  → app records fired id + logs BRIEFING_CREATED/SKIPPED
```

Idle cost = zero (no new meeting → no EventKit-new-id → no spawn). Co Work's 3am run and
its schedule are untouched and own everything outside this path.

## Out of scope
- Any change to Co Work's `breifingskill.txt` (source of truth; the app runs a *derived*
  skill that follows the same rules with CLI delivery).
- Briefings outside 09:00–17:00 (owned by Co Work's schedule).
- Ad-hoc / uninvited meetings with no EventKit event.
- Reproducing briefing logic in Swift (it stays in the skill/`claude`).

## Open questions
1. ~~**Deployment reality**~~ — RESOLVED: Co Work runs ~3×/day (Run Log); this catcher
   owns the 09:00–17:00 intraday gap. Co Work stays as-is.
2. **Headless parity:** ✅ RESOLVED (2026-07-28) via `remctl` + `imessage-tools` CLIs,
   proven from a headless spawn. Divergent delivery from Co Work is intentional and fine.
3. **`--allowedTools` vs `--dangerously-skip-permissions`** for the app's `claude` spawn —
   the CLIs run through Bash, so the spawn mainly needs Notion + Jira MCP + Bash allowed.
4. **CLAUDE.md correction:** the "Co-Work pre-call-brief webhook fired by a Notion
   automation" line is inaccurate — there is no webhook; the trigger is the scheduled
   run reading the Calendar Events DB. Update it.
```
