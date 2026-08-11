# EMEA Licence Request Watcher

Polls Salesforce for newly-created **EMEA** licence requests and fans each new one to a
Slack feed (+ loud watchlist ping + optional Todoist task). The Slack feed is both the
dedupe store and the reference index (each message embeds `sfid`/`guid`).

Design + rationale: [`docs/plans/2026-08-11-emea-licence-request-watcher-design.md`](../../docs/plans/2026-08-11-emea-licence-request-watcher-design.md)

## Modes

```bash
python3 watcher.py selftest      # SF + EMEA classification only (no Slack/Notion needed)
python3 watcher.py run           # one polling cycle (posts). --dry-run to preview
python3 watcher.py digest        # morning overnight summary DM. --dry-run to preview
```

## Environment

| Var | Purpose | Default |
|---|---|---|
| `SF_LOGIN_URL` `SF_CLIENT_ID` `SF_CLIENT_SECRET` `SF_API_VERSION` | Salesforce client-credentials (read-only integration user) | — / — / — / `v61.0` |
| `SLACK_BOT_TOKEN` | Slack bot token (`chat.postMessage`, `conversations.history/open`, `chat.getPermalink`) | — |
| `LICENCE_FEED_CHANNEL_ID` | `#emea-licence-requests` | `C0BP0TZTAG7` |
| `LICENCE_PING_USER_ID` | loud-ping / digest / failure-alert DM target | `U0BLN3B8TCZ` |
| `NOTION_TOKEN` | Notion integration token (reads the watchlist) | — |
| `LICENCE_WATCHLIST_DS_ID` | watchlist data source | `1d72ac2d-853f-43ad-b7dc-a505a210c534` |
| `TODOIST_API_TOKEN` | Todoist token (`/api/v1`) — only used for watchlist rows with *Create Todoist* | — |
| `LICENCE_WINDOW_MINUTES` | `run` lookback (2× the cron cadence) | `30` |
| `LICENCE_DIGEST_HOURS` | `digest` lookback | `15` |
| `LICENCE_STATE_DIR` | logs + heartbeat | `~/.local/state/licence-watcher` |

Salesforce client-credentials env lives in `~/Developer/Tools/salesforce-readonly-mcp-PROD/.env`.

## Scheduling (cloud)

- `run` every ~15 min, 24/7 (`LICENCE_WINDOW_MINUTES=30`).
- `digest` once at ~08:00 on weekdays.

## Monitoring

Every run writes `heartbeat.json` (`{at, ok, detail}`) and appends to `watcher.log` in
`LICENCE_STATE_DIR`. On any failure the run DMs `LICENCE_PING_USER_ID` a
`⚠️ Licence watcher run failed` message, and the morning digest echoes the last heartbeat
so a silently-dead cron is visible.

## Dedupe & idempotency

No state DB. Each cycle reads recent feed messages, extracts posted `sfid:` values, and
skips them — so overlap windows, restarts, and re-runs never double-post.
