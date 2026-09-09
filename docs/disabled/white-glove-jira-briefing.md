# DISABLED — White Glove / Jira handling in the intraday pre-call briefing

**Status:** removed from the live skill on 2026-09-09.
**Reason:** the White Glove engagement process itself is being retired. This is a
process decision, not a technical one — the automation worked as designed.
**Source:** `automation/pre-call-briefing-intraday.md` (gitignored — it carries the
private Outlook ICS feed URL, so the live skill is never committed).
**Restore:** paste each block back at the anchor named in its heading. Nothing in
the Swift app changed, so reinstating the prompt text is the whole job.

> Historical note: this instruction set never actually created a Jira issue in
> production. The app runs `claude --print --dangerously-skip-permissions` headless,
> where the interactively-authenticated Atlassian MCP server is not loaded — so the
> Step 1.4 JQL query failed, `wg_jira_ok` fell to `False`, and the create branch was
> never reached. A JQL sweep of `PSCI` for issues whose description contains
> "Auto-created by Intraday Pre-Call Briefing" returned zero results. If this is ever
> restored, that MCP-availability problem must be solved first or the whole path stays
> dormant.

---

## 1. Run-log counters

**Anchor:** the "Track counters for the run log:" line, immediately before STEP 1.
**Removed from that list:**

```
`wg_detected`, `wg_jira_matched`, `wg_jira_created`
```

## 2. STEP 1 — LOAD CONTEXT, item 4

**Anchor:** appended as item 4 after "3. **Mapping Rules**".

```markdown
4. **Active WG engagements** — `searchJiraIssuesUsingJql`, cloudId `altra.atlassian.net`, jql `project = PSCI AND issuetype = "White Gloves Session" AND statusCategory != Done ORDER BY updated DESC`, fields `["summary","status","assignee","updated"]`, maxResults 100. Build `wg_engagements` with `summary_normalised` (lowercase, whitespace-collapsed, trailing `ltd|inc|corp|plc` stripped). On failure set `wg_jira_ok=False`, `wg_engagements=[]`, continue.
```

## 3. STEP 4 heading

**Was:**

```
STEP 4 — RESOLVE CUSTOMER / PARTNER + WG (same ladder as Co Work)
```

## 4. STEP 4 — detection + issue lookup/create

**Anchor:** the two paragraphs after the "**Google Colab rule:**" paragraph.

```markdown
**White Glove detection** (stop at first hit): (1) a `cal.com`/`book.askadam.cloud` URL whose slug contains `white-glove` in LOCATION/DESCRIPTION; (2) `\b(wg|white\s*glove)\b` in the title; (3) after partner resolution, `customer_partner` normalised matches a `wg_engagements` entry. On hit set `is_wg=True` + `wg_source`.

**WG issue lookup/create** (only if `is_wg`): match `customer_partner` against `wg_engagements` (most-recently-updated on ties) → `resolution:"matched"`, `wg_jira_matched++`. If none and `wg_jira_ok` → `createJiraIssue` (cloudId `altra.atlassian.net`, projectKey `PSCI`, issueTypeName `White Gloves Session`, summary = canonical `customer_partner`, description = `Auto-created by Intraday Pre-Call Briefing on <date> for "<summary>" at <start London>. Add post-meeting notes as comments.`), `web_url = https://altra.atlassian.net/browse/<KEY>`, `resolution:"created"`, `wg_jira_created++`. Blank partner edge cases: parse Cal.com "Who:" for the invitee org, or strip the WG tag from the title; log if unresolved.
```

## 5. STEP 6 — Jira comment trail

**Anchor:** final sentence of the "**Prior history**" paragraph.

```markdown
For a **matched** (not newly-created) WG issue, `getJiraIssue` (`fields:["comment"]`, markdown), flatten last 2 comments, extract `[ ]`/`[x]` items + "Next Session/Steps".
```

## 6. STEP 7 — Notion page properties

**Anchor:** the "Create a page in …. Properties:" sentence.

Stage clause, removed from the middle of the Stage rules:

```
WG → `WG — <Jira status>`;
```

Trailing property, removed from the end of the properties list:

```
; WG Jira (`wg_issue.web_url` if set)
```

## 7. STEP 7 — briefing body

**Anchor:** the "Body (same template as Co Work):" paragraph.

Opening clause, removed:

```
a `## 🤝 White Glove Engagement` block when `is_wg` (matched/created/Jira-down variants), then
```

Trailing sentence, removed:

```
For WG append the anti-pitch reminder line.
```

## 8. STEP 7 — Generation Log

**Anchor:** the "**Decisions**" bullet of the Generation Log block.

**Was:**

```markdown
- **Decisions** — how Customer/Partner resolved (which rule / tier / inference), WG detection + Jira outcome, and any Suggestion raised.
```

## 9. STEP 9 — Slack Template C

**Anchor:** inside the Template C fenced block, after the `🆕 [HH:MM] …` pair.

```
🤝🆕 [HH:MM] — [WG Meeting] ([Partner]) → ✅ PSCI-XXX (linked) / 🆕 PSCI-XXX (created)
   [one-line WG cue]
```

## 10. STEP 10 — run log

**Anchor:** the `Errors` audit-lines fenced block.

```
WG: detected=<n> matched=<n> created=<n>
```

**Anchor:** the final Run Log properties bullet, which read:

```markdown
- `Duration (s)`, `WG Meetings Detected`, `WG Jira Matched`, `WG Jira Created`.
```

---

## Notion side (left in place, now unwritten)

These columns still exist and are simply never populated. No schema change was made,
so restoring the prompt text above is sufficient to bring the whole path back:

- Pre-Call Briefings DB — `WG Jira` (URL), and the `WG — <status>` values of `Stage`.
- Run Log DB — `WG Meetings Detected`, `WG Jira Matched`, `WG Jira Created`.

## Also disabled: the `altra-white-glove` Claude skill

The prompt was not the only route to a PSCI ticket. Adam's user-level skill
`~/.claude/skills/altra-white-glove/` created a **White Gloves Session** issue (type id
`10499`) plus five linked Tasks. User-level skills load into *any* Claude run regardless
of working directory, and this app runs the briefing headless with
`--dangerously-skip-permissions` — so a meeting merely *titled* "White Glove Working
Session" could have caused that skill to fire, entirely independently of the briefing
prompt.

Two things closed it:

1. The live skill's DISABLED paragraph now also says: *Do NOT invoke the
   `altra-white-glove` skill, or any other skill or tool that writes to Jira, regardless
   of the meeting title.*
2. The skill itself was moved out of the skill-load path, to
   `~/.claude/templates/disabled-skills/altra-white-glove/` in the `adamswbrown/claude-config`
   repo (commit `189eb82`). `git mv` it back to `skills/` to reinstate. Both
   `ALTRA-SKILLS.md` indexes mark the row retired.

**Restoring WG therefore takes both halves** — paste the prompt blocks above back *and*
move the skill back. Doing only the first leaves the process half-wired.

## Not touched

- `breifingskill.txt` — a stale reference document, not executing code. Its own header
  already records that the live cloud "Co Work" routine does **not** do White Glove
  Jira detection, so the scheduled morning briefing needed no change.
- `MeetingReminder/Views/SettingsView.swift` — the on-device generator's help text
  mentions Jira only to say that path skips it. Still accurate.
