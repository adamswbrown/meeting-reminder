# EMEA Licence Request Watcher — Design

**Date:** 2026-08-11
**Status:** Design agreed, not yet built
**Author:** Adam + Claude (brainstormed)

## Problem

When a new Microsoft Assessment Desk **licence request** is submitted, Adam finds out via a
Teams "New Microsoft Assessment Desk License Request Submitted" notification he **can't
action**, or a licence-provisioning email he **might miss**. If he's waiting on a specific
one (e.g. *"waiting for the ADC licence request to come in"*), there's no reliable heads-up.

Graph is not available (no permissions, can't get them), so reading Teams directly is out.
But the licence request **also lands in Salesforce** as a `Licence_Requests__c` record — a
queryable, read-only source we already have access to. So we watch Salesforce, not Teams.

## Intent (what this is and isn't)

- **It is** an *awareness signal* — "the thing you were waiting for just landed" — plus a
  durable **handle** so Adam can later say *"email the partner on the ADC request"* and
  Claude can resolve it back to live Salesforce data.
- **It is not** a report or a Notion mirror of Salesforce. We do **not** duplicate the
  licence data. Salesforce stays the source of truth; lookups always pull *fresh*.

## Runtime

A **cloud scheduled routine** (Mac-independent — must survive Adam walking away overnight),
running every **~15 min, 24/7**. Salesforce is reached via the read-only integration user
(`svc-ai-mcp-readonly@altra.cloud.prod`, OAuth client-credentials — non-interactive, works
headless) or the `sf` CLI as `monitor`; see the `altra-salesforce-query` skill.

## Each run

1. **Query** `Licence_Requests__c` created since a short lookback window
   (`CreatedDate >= LAST_N_MINUTES:30` — 2× the cadence, so nothing slips between runs).
   Fields: `Id, Name, CreatedDate, Status__c, Country__c, Region__c,
   CusomerAccount__r.Name, AMM_Partner_Account__r.Name, Partner_Domains__c,
   Customer_Segment__c, Licence_GUID__c`.
2. **Filter to EMEA** by mapping `Country__c` → Microsoft Area using the authoritative
   table in `altra-salesforce-query/references/altra-licence-emea.md` (apply the country
   aliases + agreed extra rules first). Drop non-EMEA countries.
3. **Dedupe with no database** — each Slack feed message embeds the request's SF `Id`. The
   run reads the recent feed messages and skips any `Id` already posted. **Slack is the
   "already seen" store** — idempotent across restarts and overlap windows, no state file.
4. **Load the watchlist** (active rows) from Notion and match each new request.
5. **Fan out** to Slack (always), a loud watchlist ping (on match), and Todoist (only if the
   matched watchlist row opted in).

## Notion — the watchlist DB (only Notion object; mirrors the Skip List pattern)

A small DB Adam edits by hand, read live at runtime (like `CalendarSyncNotionQueries.fetchSkipRules`).
**No request data is written to Notion.**

| Property | Type | Purpose |
|---|---|---|
| **Match** (title) | Title | Customer name / keyword / partner, e.g. `ADC` |
| **Match Type** | Select | `Customer Contains` / `Exact Customer` / `Country` / `Partner` |
| **Active** | Checkbox | Toggle a rule off without deleting |
| **Create Todoist** | Checkbox | If ticked, a match also spawns a Todoist follow-up task |
| **Notes** | Text | Why he's waiting (free-text context) |

## Slack delivery — three lanes

- **Feed** `#emea-licence-requests` (Adam **mutes** it): every new EMEA request, one line.
  Silent overnight pile-up he scrolls in the morning — no banner storm.
  - Human line: `🇬🇧 ADC · UK & Ireland · Validating · [Salesforce ↗]`
  - Machine footer (for reference/dedupe): `sfid:<Id>  guid:<Licence_GUID__c>  acct:<Customer>`
- **Watchlist hit** (loud): a DM / @mention — `🎯 ADC licence request just landed` — so the
  awaited one cuts through the ambient feed.
- **Morning digest** ~08:00 weekdays: one message — `12 EMEA requests overnight` + list,
  watchlist hits pinned at the top. This is the no-storm "what happened while I was away."

## Todoist — opt-in per watchlist row

Only a request matching an active watchlist row whose **Create Todoist** is ticked creates a
task (in a `Licence Requests` project):

- **Content:** `Licence request in: <Customer> — <EMEA Area>`
- **Description:** Status, Country, Partner, links to Salesforce + the Slack message permalink
- **Due:** today · **Priority:** P2 (it's a watched item) · **Label:** `licence`

No blanket Todoist tasks — the general feed never spawns tasks.

## Reference — "resolve and act" protocol

The Slack feed **is** the reference index. To turn *"the ADC licence request"* into an action,
a future Claude session:

1. **Searches** `#emea-licence-requests` for the term → reads the message → extracts
   `sfid` / `guid` from the footer.
2. **Live-queries Salesforce** off those keys (never stored copies):
   - **Email the partner:** `AMM_Partner_Account__r.Name`, `Partner_Domains__c`, and the
     partner contact email (exclude `microsoft.com`) → draft the email.
   - **Deployment detail:** join `Deployment__c` on `Licence_GUID__c` (case-insensitive) →
     `License_Tier__c`, `AutomapVMCount__c`, `AutomapAppCount__c`,
     `Discovered/Assessed/InScopeMachines__c`, `Estimated_Total_License_Cost__c`,
     `Deployment_Status__c`. Progress via latest `Deployment_Snapshot__c` for that GUID.
3. Acts on it (draft email, summarise deployment) using fresh data.

This protocol is saved to Claude memory so the capability persists across sessions.

## Deliberately does NOT do

- No Notion mirror of licence requests (no report duplication).
- No blanket Todoist tasks (opt-in per watchlist row only).
- No native macOS banner (Slack solves the overnight-storm problem; a muted channel +
  morning digest beats 30 dismissable banners).
- No writes to Salesforce — read-only throughout.

## Build status (2026-08-11)

Done and committed:
- ✅ Notion **watchlist DB** created under Operations — data source `1d72ac2d-853f-43ad-b7dc-a505a210c534`. Seeded with an `ADC` example row (Active, Create Todoist on).
- ✅ Slack channel `#emea-licence-requests` — `C0BP0TZTAG7`. Loud-ping/digest/failure-alert target = DM to `U0BLN3B8TCZ`. Setup notice + a sample feed line posted.
- ✅ Watcher script `scripts/licence-watcher/watcher.py` (+ README). `selftest` validated live: 8 EMEA / 1 review / 5 skip.
- ✅ Salesforce client-credentials path proven end-to-end (token + query).

## DEPLOYMENT BLOCKER — Salesforce access from the cloud

The clean "cloud routine polls Salesforce" plan hits a wall: **cloud routines can't reach Salesforce as-is.**
- No Salesforce MCP connector is connected at claude.ai (only Slack/Notion/Todoist/Supabase/Gmail/Drive/Atlassian).
- Cloud agents can't read local files/env, so the SF client-creds in `~/Developer/Tools/salesforce-readonly-mcp-PROD/.env` aren't available.
- Cloud cron minimum interval is **1 hour** (so cadence is hourly, not 15 min).

Everything downstream (Slack/Notion/Todoist) is cloud-ready. Deployment options (undecided):
1. **Cloud routine + secrets on the environment** — routine clones this repo, runs `watcher.py run` hourly; Adam adds SF + Slack/Notion/Todoist secrets to the routine environment via claude.ai/code. Mac-independent.
2. **Local launchd** — deliverable immediately (SF creds already local; drop Slack/Notion/Todoist tokens in a local env file). Every 15 min while awake; on-wake catch-up sweeps overnight into the muted feed + digest. Not independent if Mac is off all day.
3. **Bridge via Supabase** — Mac pushes new SF requests to Supabase (already used for availability); cloud routine reads Supabase + posts. Mac-independent reads, SF→Supabase push still needs the Mac.

Status: **deployment on hold pending Adam's runtime choice.** Everything else is built and tested.
