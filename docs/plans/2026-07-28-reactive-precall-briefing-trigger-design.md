# Reactive pre-call briefing trigger (new meeting → briefing)

**Date:** 2026-07-28
**Status:** Design approved — **Hybrid chosen** (keep 3×/day cloud runs as backstop +
add a Mac app reactive trigger). Not yet implemented. Gated on headless-MCP parity
validation (see Open Question #2).

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

### Decision — Hybrid (2026-07-28)
Keep the existing cloud schedule as the **backstop** (morning digest + a few daily
reconciles), and add the **Mac app reactive trigger** (Option 2) to close the same-day
gap with zero idle spawns. This matches the literal ask ("when a new meeting comes in, a
briefing gets created") and respects the idle-cost constraint. **Gated on headless-MCP
parity validation** before any Swift is written.

### Build sequence
1. ~~**Validate headless-MCP parity (make-or-break).**~~ ✅ DONE 2026-07-28. Content
   pipeline (Notion/Jira/ICS/web) works headless; delivery (iMessage/Mail) + Reminders do
   not. Resolution baked into the design: **app owns delivery** (native
   `NotificationService`), app-triggered run is **content-only**, Reminders heal on the
   next scheduled run.
2. **Confirm the trigger signal.** Verify `calendarNotionSyncReactiveEnabled` real state
   and that `runReactive()` reliably writes new mid-day meetings to the Calendar Events DB
   (the varied morning `Last Synced` stamps suggest it does, but the default reads unset —
   reconcile this).
3. **Build `PreCallBriefTriggerService`** per the design below.
4. **Ship behind `preCallBriefTriggerEnabled` (default off);** keep cloud runs as backstop.

## Hard dependency — headless MCP availability

The full ruleset needs many MCP servers available in a **headless `claude --print`** run.
Validated / to-validate as of 2026-07-28 (`claude mcp list`):

| Capability | Server | Headless status |
|---|---|---|
| Notion (read + write briefings) | claude.ai Notion | ✅ proven 2026-07-28 |
| Web search (contact enrichment) | built-in | ✅ proven |
| Jira PSCI (WG lookup/create) | claude.ai Atlassian Rovo | ✅ connected — verify write headless |
| Apple Reminders (action-item sync) | *(none found)* | ⚠️ ruleset self-heals: `reminders_ok=False` → run logs `Partial`, iMessage carries items |
| iMessage delivery | "Read and Send iMessages" | ⚠️ not in current `mcp list` — ruleset falls back to Apple Mail then Run Log |
| Apple Mail fallback | `mcp__apple-mail__*` | ✘ currently "Failed to connect" |

The ruleset degrades gracefully (Partial runs, delivery fallbacks), but **for a
reactive app-triggered run to deliver like the scheduled run, the same servers must be
reachable in the app's `claude` invocation environment.** This is the main risk for
Option 2 and must be checked before building — a background app spawn may not inherit the
same MCP auth/session as an interactive or cloud run.

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

### Design implication — the app owns delivery, not the ruleset
This is a simplification, not a blocker. For an **app-triggered** reactive run we do NOT
need iMessage/Reminders headless, because the Mac app already has native delivery:
- **Notification:** use the app's existing `NotificationService` (and optionally a
  `FloatingPromptView`/overlay) to surface "🆕 briefed: <meeting>" — replacing the
  ruleset's iMessage for the same-day case.
- **Reminders backlog:** leave to the next **scheduled** run, whose interactive context
  can reach Macuse and heal the backlog (the ruleset's Step 4B heal path already does this
  robustly — verified in the 09:52 cloud run).
- The app-triggered run should therefore be treated as **content-only by design**; a
  `Partial` status from missing delivery channels is expected and must NOT be surfaced as
  an error. Consider passing a flag / using a content-only variant invocation so the run
  doesn't spend time probing iMessage/Mail it knows won't be there.

## Design (Option 2 specifics, if pursued)

### Invoked skill
Install `breifingskill.txt` as the skill the app runs (e.g. copy/symlink into
`~/.claude/` as a named skill, or pass its content via stdin). **No app-side variant** —
the app substitutes nothing; the ruleset re-derives today's meetings from the Calendar
Events DB + ICS itself.

### `PreCallBriefTriggerService` (Mac app)
`Services/PreCallBriefTriggerService.swift`:
- **Signal:** hook the completion of `CalendarNotionSyncService.runReactive()` when it
  wrote ≥1 row. (Surface a "wrote something" bool out of the reactive run.)
- **Debounce + serialize:** coalesce bursts; a single in-flight run; a floor between runs
  (mirror the reactive sync's 2-min floor).
- **Invoke:** background `Process` → `claude --print --allowedTools <…> ` (prefer an
  allow-list over `--dangerously-skip-permissions`) running the ruleset. Off the main
  actor. Capture the Run Log outcome / final line; log locally.
- **Guards:** don't fire during the 06:00 backfill; respect working hours (cheap check
  before spawning, so we don't even start `claude` out of hours); leave the 3 scheduled
  tasks / 15-min cron as backstop.

### Settings (UserDefaults)
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `preCallBriefTriggerEnabled` | Bool | false | Master toggle for app-driven reactive briefing |
| `preCallBriefCLIPath` | String | "/usr/local/bin/claude" | Path to the `claude` binary |
| `preCallBriefMinIntervalSeconds` | Int | 120 | Floor between app-triggered runs |

Depends on `calendarNotionSyncReactiveEnabled` (the trigger signal source).
Surfaced in **Settings → Notion → Calendar Sync**, near the reactive-sync toggle.

## Data flow (Option 2)

```
new meeting booked mid-day
  → EKEventStoreChanged → reactive sync (30s debounce, 2-min floor) writes the
    Calendar Events row (empty Pre-Call Briefing relation)
  → PreCallBriefTriggerService: wrote-something? working hours? not backfill? no run in flight?
  → background `claude --print` runs breifingskill.txt
     → Step 0.0 sees work exists → Step 2B scopes to the net-new meeting only
     → full pipeline: partner/WG/history/enrich/page + link-back + Reminders + iMessage + Run Log
  → app logs the outcome
```

Idle cost with Option 2 = zero (no change → reactive sync writes nothing → no trigger).

## Out of scope
- Any change to `breifingskill.txt`'s logic (it is the source of truth; the app only
  *triggers* it).
- A simplified single-meeting briefing variant (rejected — violates "same ruleset").
- Briefing meetings that never reach the Calendar Events DB (needs reactive sync on).
- Reproducing any briefing logic in Swift.

## Open questions
1. **Deployment reality:** is `breifingskill.txt` currently deployed as a 15-min cloud
   task, or only the older 3×/day simple skills? Determines whether Option 1 is "turn it
   on" or "already on but too slow."
2. **Headless MCP parity:** ✅ RESOLVED (2026-07-28 full-ruleset headless run). Notion +
   Jira + ICS + web work headless; Reminders + iMessage + Apple Mail do **not** (absent in
   the background spawn). Resolution: the app owns delivery via `NotificationService`;
   Reminders backlog heals on the next scheduled run. App-triggered run = content-only.
3. **`--allowedTools` identifiers** for the full server set, to avoid
   `--dangerously-skip-permissions` in the app.
4. **CLAUDE.md correction:** the "Co-Work pre-call-brief webhook fired by a Notion
   automation" line is inaccurate — there is no webhook; the trigger is the scheduled
   run reading the Calendar Events DB. Update it.
```
