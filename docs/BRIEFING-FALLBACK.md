# Apple Intelligence briefing fallback

When Claude hits its usage limit, the app produces the pre-call briefing itself
using Apple Intelligence — and upgrades it in place once Claude recovers.

Companion to [docs/INTRADAY-BRIEFINGS.md](INTRADAY-BRIEFINGS.md), which covers the
normal Claude-driven path. This document covers only what happens when that path
cannot run.

**Off by default.** With `briefingFallbackEnabled` unset, nothing here happens and
behaviour is identical to before the feature existed.

---

## When it fires

Only on a **confirmed quota or credit error** in Claude's result envelope.

Deliberately *not* treated as exhaustion, because each has its own cause and a
thin briefing is worse than a late one:

| Not a trigger | Why |
|---|---|
| A source tool returning HTTP 429 | Notion/Teams rate limits, nothing to do with Claude's allowance |
| Authentication failure | A broken token needs fixing, not routing around |
| A malformed result envelope | Unknown state; do not assume the worst |
| A timeout | The run may have partially succeeded |

So the fallback cannot be triggered on demand — it needs Claude to genuinely be out
of credit. There is no manual trigger (see [Known gaps](#known-gaps)).

---

## What happens

1. **Retrieve** — the app gathers its own context: Notion mapping rules, prior
   meeting notes, prior briefings, Teams via one fixed read-only MCP call, and the
   calendar event. No step depends on Claude.
2. **Generate** — via a Shortcut you choose (Apple cloud) or the on-device model.
3. **Write** — a `Fallback briefing` toggle block on the meeting's Pre-Call
   Briefings page, creating the page if it does not exist.
4. **Deliver** — a Slack post, and open action items synced to Todoist.
5. **Enrich** — the job stays queued. Once Claude recovers it re-reads that page
   plus fresh context and **appends** a `Claude enrichment` block, with a
   **threaded** Slack reply so recovery never reads as a second new-meeting alert.

Enrichment *appends*; it does not replace the Apple summary. That is the same rule
that protects your own edits and meeting notes from being overwritten, so a
recovered page reads as the Apple summary followed by Claude's additions.

---

## Setup

### 1. Prerequisites

| Requirement | Why |
|---|---|
| macOS 26.4+ | `SystemLanguageModel` token accounting. Below this the toggle is hidden |
| Notion token in the Keychain (`notionAPIToken`) | Retrieval and the page write. Shared with Cal Sync |
| The Notion databases | Pre-Call Briefings, Meeting Notes, Mapping Rules, Skip List. See [NOTION-SETUP.md](NOTION-SETUP.md) |
| Slack bot token | Optional. Without it the briefing is saved but not announced |
| Todoist API token | Optional. Without it action items are not synced |
| A Shortcut | Optional. Without one, generation stays on-device |

> **Not yet self-service.** Guided Notion setup does not create Mapping Rules, and
> `Stage` / `Prior Meetings` are missing from a freshly-provisioned Pre-Call
> Briefings database — which makes page creation fail *intermittently*. Several
> data-source IDs are still hardcoded. This works today for an install whose Notion
> matches the author's; productionising it is tracked separately.

### 2. Settings → Briefings

Everything lives in one tab, in four sections:

- **Intraday** — the auto-brief toggle (must be on; the fallback toggle is disabled
  otherwise), last run, and the review queue.
- **Claude** — CLI path and skill path, each showing the **resolved** path with a
  ✓/✗ existence check, plus the minimum gap between runs.
- **Apple Intelligence fallback** — the enable toggle, the on-device/cloud choice,
  and the queue and cooldown.
- **Delivery** — Slack and Todoist tokens (stored in the Keychain, never in
  preferences), channel and project, and a read-only **Save & test**.

### 3. On-device or cloud

An explicit choice, not an implied one:

- **On-device model** — nothing leaves the Mac. Much smaller context window
  (8,192 tokens on current hardware), so evidence is reduced more aggressively.
- **Apple cloud (via a Shortcut)** — pick one of your Shortcuts from the dropdown.
  Faster and far more context, but **the meeting context is sent to Apple**.

Choosing cloud without picking a Shortcut warns you and stays on-device. A Shortcut
that is later renamed or deleted is reported on refresh.

---

## The Shortcut contract

The app runs `shortcuts run <name> --input-path … --output-path …`.

**Input** — one UTF-8 text file, received as **Shortcut Input**. Not JSON:

```
<generation instructions>
MEETING
- Title: …
- When (Europe/London): …
ATTENDEES
- …
COVERAGE
<what was and was not retrieved>
EVIDENCE
[notes-1] Prior meeting notes (Completed)
<page text>
[truncated]

[teams] Teams context_for_meeting (last 14 days)
<transcript>
```

The evidence budget is 24,000 characters **split evenly across sources**, so each
is capped and cut with a literal `[truncated]` marker. It is a flat per-source cap,
not relevance ranking.

**Output** — the Shortcut must return **only** a JSON object:

```json
{ "summary": "…", "preparation": ["…", "…"] }
```

`summary` ≤ 1800 characters; `preparation` ≤ 5 items of ≤ 300 characters. The app
caps the output file at 20,000 bytes and validates the schema before writing
anything; invalid output is discarded and the job retries.

**The Shortcut must generate only.** Disable Follow Up and avoid anything
interactive — the CLI is killed after 90 seconds, but terminating it cannot
guarantee cancellation inside the Shortcuts service. It must not create Notion
pages or send messages; the app owns every write.

**The app cannot tell which model a Shortcut uses.** If you switch it from Cloud Pro
to something else, nothing in the app or on the page will say so.

---

## Coordination: three writers, one lock

Three independent things can create a briefing page for one occurrence:

| Writer | When |
|---|---|
| Co Work cloud routine | Weekday mornings, 02:04 UTC |
| Intraday catcher skill | A new meeting during 09:00–17:00 |
| This app's fallback | Claude exhausted |

They share an advisory lock: a `Briefing Lock` rich-text property on the
occurrence's **Calendar Events** row (migration `004-add-briefing-lock-column`),
holding `owner|id|expiry` with the expiry in ISO 8601 UTC. Owners are `co-work`,
`intraday` and `meeting-reminder`.

Notion has no compare-and-swap, so the protocol is **claim → settle → re-read**,
treating a changed value as a lost race. That narrows the window from a whole
generation run to the settle delay; it does not eliminate it. Every failure mode —
missing column, missing row, malformed value, Notion error — degrades to *unlocked,
brief anyway*, because each writer still has its own duplicate guard and a missed
briefing is worse than a duplicate.

The other two writers live outside this repo (a cloud routine and a gitignored
skill file). If the lock is not honoured there, the race is narrowed, not closed.

---

## Delivery and idempotency

Everything must be safe to run twice — crash recovery and enrichment both re-enter it.

- **Slack** posts **once** per occurrence; the recorded message `ts` is the
  idempotency key. Enrichment replies **in that thread**. With no parent `ts`,
  nothing is posted rather than risking a stray top-level alert.
- **Todoist** creates are guarded by the ledger *and* a live `#AI-XXXXXX` query
  (Co Work may have created the same task already), and carry `X-Request-Id`.
  Nothing is ever completed, rescheduled or deleted.
- Only carried-forward `- [ ]` items become tasks. The model's *suggested
  preparation* is explicitly not agreed work and is never assigned.
- Only items that already carry an `#AI` hash are taken. The hash is the join key;
  minting a new one risks disagreeing with Co Work's and duplicating the task.

---

## Review queue

A write whose outcome could not be confirmed parks the job instead of repeating it.
Parked jobs appear in **Settings → Briefings → Intraday** with the reason and a link
to the recorded page.

- **Try again** restores the phase the job was parked from, so the run re-enters
  **marker reconciliation, not regeneration** — the uncertain write may have landed.
- **Dismiss** stops the retries only. Notion, Slack and Todoist are untouched.

Check the linked page before retrying.

---

## Inspecting a briefing without writing one

The dry run executes the real retrieval and generation path against a real meeting
and prints what *would* be written — reads plus one model call, no writes:

```sh
TEST_RUNNER_BRIEFING_DRY_RUN=1 \
TEST_RUNNER_DRY_TITLE="SCC FY27 Office Hours" \
TEST_RUNNER_DRY_START="2026-09-16T09:30:00Z" \
TEST_RUNNER_DRY_APPLE_ID="<iCal UID>" \
TEST_RUNNER_DRY_SHORTCUT="Meeting Briefing PCC Probe" \
TEST_RUNNER_DRY_ATTENDEES="Name <a@b.com>|Other <c@d.com>" \
xcodebuild -project MeetingReminder.xcodeproj -scheme MeetingReminder \
  -destination 'platform=macOS' \
  -only-testing:MeetingReminderTests/BriefingDryRunTests test
```

The `TEST_RUNNER_` prefix is required — Xcode strips it when passing the variable
to the test process. Plain environment variables do not reach it and the test
silently skips.

Writes two files: the rendered report to `/tmp/pcc-dry-run.txt`, and the exact
Shortcut payload to `/tmp/pcc-shortcut-input.txt`. **Both contain real content** —
attendee addresses, Notion page text, Teams transcripts — so delete them when done.

---

## Files and logs

| Path | What |
|---|---|
| `~/Library/Logs/MeetingReminder/precall-brief-intraday.log` | Trigger + fallback results |
| `~/Library/Logs/MeetingReminder/calendar-notion-sync.log` | Migrations, including the lock column |
| `~/Library/Application Support/MeetingReminder/briefing-fallback.json` | The durable job ledger (0600) |

The ledger is the durability guarantee. A corrupt one is an **error**, never
silently replaced with an empty queue — that would re-create pages that already
exist. If it cannot be read the fallback pauses and says so.

---

## Troubleshooting

**Nothing ever fires.** Expected unless Claude is genuinely out of credit. Check
`precall-brief-intraday.log` for `INTRADAY_RESULT` lines: a normal Claude run means
the fallback was never needed.

**Briefings stopped entirely.** Check the ✗ next to the Claude CLI path in Settings
→ Briefings. The CLI moving between npm and Homebrew locations has silently stopped
intraday briefings before.

**Fallback ran but nothing appeared in Slack.** Look at the source-coverage line on
the Notion page; a failed send is recorded there and in the job, never reported as
delivered. Re-test the token with **Save & test**.

**Partner resolves to the wrong organisation.** The source-coverage line states
which rule and tier matched. `Partner was inferred, not rule-matched` means no rule
fired and the convener/internal fallback was used — usually a missing Mapping Rule.

**A job is stuck in review.** Open the linked page and check whether the write
landed before choosing Try again or Dismiss.

---

## Known gaps

- **No manual trigger.** The fallback cannot be exercised on demand, so it can only
  be observed during real exhaustion.
- **Prior *briefings* retrieval filters on `Customer / Partner`**, which returns the
  partner's other engagements rather than prior occurrences of the same meeting. The
  notes rung finds the right history; the briefings rung does not — and all
  carried-forward actions come from the briefings rung.
- **Teams context is unreliable run to run** and degrades quietly as "cached".
- **Notes are never status-filtered.** The skill specifies
  `Status in [Completed, Completed Ad Hoc]`, but in practice every recent note is
  `Scheduled`, so that filter would return nothing.
- **Notion image URLs leak into evidence** via `blockText`, spending context budget
  on CDN links.
- **Evidence budget is split evenly**, not weighted by relevance or recency.
