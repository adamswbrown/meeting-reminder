# Licence Expiry Follow-up — design

**Date:** 2026-08-20
**Component:** `scripts/licence-watcher/watcher.py`
**Extends:** [2026-08-11 EMEA Licence Request Watcher](2026-08-11-emea-licence-request-watcher-design.md)

## Problem

The watcher tells us about *new* licence requests and *new* deployments. It says
nothing about existing engagements whose licences are **about to expire or have
just expired** — the trigger for renewal / follow-up conversations. We want that
surfaced, EMEA-only, without repeating the same rows every morning and without
duplicating records already shown elsewhere in the digest.

## Data source

support-central `license_info` — one record per deployment:

```json
{ "DeploymentId": "...", "CurrentLicence": "Fixed Annual", "RenewalLicence": "...",
  "RenewalDate": "2026-09-08T...Z", "InstallDate": "...", "LicenceGuid": "...",
  "CustomerName": "..." }
```

~4,283 records. **No country/region** on the record — the EMEA constraint requires
a join back to Salesforce on `LicenceGuid`.

Observed distribution (2026-08-20): 2,281 are `Cancel License`, 1,269 `Microsoft
Funded`; 3,457 have a past `RenewalDate` (long tail to 2023). A naive "expired"
list is useless — hence the filters below.

## Pipeline (new mode: `expiry`)

1. **Fetch** `license_info` from support-central.
2. **Scope filter:** drop `CurrentLicence` in {`Cancel License`, null}. Keep all
   other types (Microsoft Funded, Fixed Annual, Monthly PAYG, Demo, etc.).
3. **Window filter** on `RenewalDate`:
   - `expiring`  — within the next `LICENCE_EXPIRY_AHEAD_DAYS` (default **30**)
   - `expired`   — within the last `LICENCE_EXPIRY_BEHIND_DAYS` (default **30**)
   - everything else dropped. (~4,283 → ~300)
4. **EMEA regional constraint:** batch surviving `LicenceGuid`s into a SOQL `IN`
   query against `Licence_Requests__c` for `Country__c` / `Region__c`, then run
   the existing `classify()`. Keep `emea` + `review` (unknown region); drop
   non-EMEA `skip`. The same join yields the SF link + follow-up contacts.

## Output & placement

Appended as a **"Licence renewals" section to the existing daily digest**
(`do_digest`) — Slack DM + HTML/plaintext email. No new launchd job; rides the
existing 08:00 Mon–Fri run.

Two groups, empty groups omitted, whole section skipped if both empty:

- `⏳ Expiring (next 30d)` — customer · type · `renews in Nd` · SF link · ✉ contact
- `🔴 Expired (last 30d)`  — customer · type · `expired Nd ago` · SF link · ✉ contact

## Changes-only dedup

Local state file `~/.local/state/licence-watcher/expiry-seen.json`:
`{ LicenceGuid: bucket }` already reported. A row shows only when its
**(guid, bucket)** pair is new since the last run.

- No repetition of a licence sitting in `expiring` day after day.
- A licence crossing `expiring → expired` changes bucket, so it **re-surfaces
  once** as newly expired — the desired follow-up trigger.
- Consistent with the watcher's dedup philosophy (local state, since the digest
  is a DM/email with no feed channel).

## Non-duplication with the rest of the digest

Suppress any licence whose `LicenceGuid` already appears in that morning's new
Licence-Requests or Deployments sections, so nothing shows twice in one email.

## On-demand full snapshot

`./run-local.sh expiry --full --dry-run` prints the complete current EMEA
expiring/expired list, ignoring seen-state — for the whole standing picture
rather than the daily delta. `expiry` as its own mode also allows a live manual
run if ever needed.

## Config (new env, all optional)

| Var | Default | Meaning |
|---|---|---|
| `LICENCE_EXPIRY_AHEAD_DAYS` | 30 | "expiring" lookahead |
| `LICENCE_EXPIRY_BEHIND_DAYS` | 30 | "expired" lookback |
| `SUPPORT_CENTRAL_*` | (existing) | how `license_info` is reached (see below) |

## Open implementation note

`license_info` was read here via the support-central MCP. The watcher is a
standalone Python script (no MCP client). Implementation must reach the same
data over whatever HTTP/CLI the support-central server wraps, or a cached export.
Resolve the concrete access path during implementation before wiring the mode in.
