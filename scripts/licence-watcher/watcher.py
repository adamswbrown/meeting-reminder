#!/usr/bin/env python3
"""EMEA Licence Request Watcher.

Polls Salesforce for newly-created licence requests, filters to EMEA, and fans
each new one out to a Slack feed (+ loud watchlist ping + optional Todoist task).
The Slack feed doubles as the dedupe store and the reference index (each message
embeds sfid/guid).

Design: docs/plans/2026-08-11-emea-licence-request-watcher-design.md

Modes:
  run      one polling cycle (default). Use --dry-run to print without posting.
  digest   post the morning overnight summary.
  selftest SF + EMEA classification only (no Slack/Notion/Todoist needed).

Config (env):
  SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET, SF_API_VERSION   Salesforce client-creds
  SLACK_BOT_TOKEN                                                Slack bot token
  LICENCE_FEED_CHANNEL_ID   (default C0BP0TZTAG7)                #emea-licence-requests
  LICENCE_PING_USER_ID      (default U0BLN3B8TCZ)                loud-ping DM target
  NOTION_TOKEN                                                   Notion integration token
  LICENCE_WATCHLIST_DS_ID   (default 1d72ac2d-...)               watchlist data source
  TODOIST_API_TOKEN                                             Todoist token (/api/v1)
  LICENCE_WINDOW_MINUTES    (default 30)                         run lookback window
  LICENCE_DIGEST_HOURS      (default 15)                         digest lookback window
  LICENCE_STATE_DIR         (default ~/.local/state/licence-watcher)  logs + heartbeat
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

# --- Salesforce fields we pull ------------------------------------------------
SF_FIELDS = [
    "Id", "Name", "CreatedDate", "Status__c", "Country__c", "Region__c",
    "CusomerAccount__r.Name", "AMM_Partner_Account__r.Name",
    "Partner_Domains__c", "Customer_Segment__c", "Licence_GUID__c",
]

# --- EMEA: country -> Microsoft Area (authoritative; see altra-licence-emea.md) -
COUNTRY_ALIASES = {
    "United Kingdom": "UK", "Turkey": "Turkiye", "Czech Republic": "Czechia",
    "Iraq/Afghanistan/Palestine": "Iraq-Afghanistan-Palestine",
    "UAE": "United Arab Emirates", "Ivory Coast": "Côte d'Ivoire",
}
AREA_TO_COUNTRIES = {
    "France": ["France"],
    "Switzerland": ["Switzerland"],
    "Netherlands": ["Netherlands"],
    "Germany & Austria": ["Germany", "Austria"],
    "UK & Ireland": ["UK", "Ireland"],
    "MEA": ["Egypt", "Kenya", "Morocco", "Nigeria", "South Africa", "Angola",
            "Algeria", "Côte d'Ivoire", "Botswana", "Cameroon", "Libya",
            "Mauritius", "MEA EMCC Scale", "Senegal", "Tunisia", "Uganda",
            "Zambia", "United Arab Emirates", "Saudi Arabia", "Qatar", "Kuwait",
            "Bahrain", "Oman", "Iran", "Iraq-Afghanistan-Palestine", "Jordan",
            "Lebanon", "Ghana", "Seychelles"],
    "Europe North": ["Sweden", "Denmark", "Belgium", "Norway", "Finland",
                     "Poland", "Estonia", "Latvia", "Lithuania", "Armenia",
                     "Azerbaijan", "Central Asia", "Georgia", "Kazakhstan",
                     "Pakistan", "Turkmenistan", "Hungary", "Romania", "Moldova",
                     "Slovakia", "Czechia", "Ukraine", "Luxembourg"],
    "Europe South": ["Italy", "Spain", "Israel", "Portugal", "Turkiye", "Greece",
                     "Cyprus", "Malta", "Albania", "Bosnia and Herzegovina",
                     "Bulgaria", "Croatia", "Kosovo", "Montenegro",
                     "North Macedonia", "Serbia", "Slovenia"],
}
COUNTRY_TO_AREA = {c: area for area, cs in AREA_TO_COUNTRIES.items() for c in cs}
# Azure regions that imply an EMEA datacentre (used only when Country__c is null).
EMEA_REGION_HINTS = {"westeurope", "uksouth", "ukwest", "northeurope",
                     "francecentral", "germanywestcentral", "switzerlandnorth",
                     "norwayeast", "swedencentral", "uaenorth", "southafricanorth"}


def country_to_area(country: str | None) -> str | None:
    if not country:
        return None
    c = COUNTRY_ALIASES.get(country.strip(), country.strip())
    return COUNTRY_TO_AREA.get(c)


class EmeaResult:
    """Classification of a request: emea | review | skip, plus the Area."""
    def __init__(self, kind: str, area: str | None, reason: str):
        self.kind, self.area, self.reason = kind, area, reason


def classify(rec: dict) -> EmeaResult:
    country = rec.get("Country__c")
    area = country_to_area(country)
    if area:
        return EmeaResult("emea", area, f"country={country}")
    if country:  # known country, not EMEA
        return EmeaResult("skip", None, f"non-EMEA country={country}")
    # Country is null — don't silently drop. Use region as a hint.
    region = (rec.get("Region__c") or "").replace(" ", "").lower()
    if region and region in EMEA_REGION_HINTS:
        return EmeaResult("review", None, f"no country, EMEA region={rec.get('Region__c')}")
    if not region:
        return EmeaResult("review", None, "no country, no region")
    return EmeaResult("skip", None, f"no country, non-EMEA region={rec.get('Region__c')}")


# --- small HTTP helper --------------------------------------------------------
def _http(method: str, url: str, headers: dict, data: bytes | None = None) -> dict:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:500]
        raise RuntimeError(f"HTTP {e.code} {method} {url}: {detail}") from None


# --- Salesforce ---------------------------------------------------------------
def sf_token() -> tuple[str, str]:
    login = os.environ["SF_LOGIN_URL"].rstrip("/")
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": os.environ["SF_CLIENT_ID"],
        "client_secret": os.environ["SF_CLIENT_SECRET"],
    }).encode()
    res = _http("POST", f"{login}/services/oauth2/token",
                {"Content-Type": "application/x-www-form-urlencoded"}, data)
    return res["access_token"], res["instance_url"].rstrip("/")


def sf_query_since(cutoff_iso: str) -> list[dict]:
    token, instance = sf_token()
    api = os.environ.get("SF_API_VERSION", "v61.0")
    soql = (f"SELECT {', '.join(SF_FIELDS)} FROM Licence_Requests__c "
            f"WHERE CreatedDate >= {cutoff_iso} ORDER BY CreatedDate ASC")
    url = f"{instance}/services/data/{api}/query?q={urllib.parse.quote(soql)}"
    headers = {"Authorization": f"Bearer {token}"}
    records: list[dict] = []
    while True:
        res = _http("GET", url, headers)
        records.extend(res.get("records", []))
        nxt = res.get("nextRecordsUrl")
        if not nxt:
            break
        url = f"{instance}{nxt}"
    return records


def sf_link(instance_hint: str, rec_id: str) -> str:
    return f"https://altra.my.salesforce.com/{rec_id}"


# --- Slack --------------------------------------------------------------------
SLACK = "https://slack.com/api"


def slack_call(method: str, payload: dict) -> dict:
    token = os.environ["SLACK_BOT_TOKEN"]
    res = _http("POST", f"{SLACK}/{method}",
                {"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json; charset=utf-8"},
                json.dumps(payload).encode())
    if not res.get("ok"):
        raise RuntimeError(f"slack {method} failed: {res.get('error')}")
    return res


def slack_seen_sfids(channel_id: str, limit: int = 300) -> set[str]:
    """Read recent feed messages; the dedupe store lives in the channel itself."""
    token = os.environ["SLACK_BOT_TOKEN"]
    url = f"{SLACK}/conversations.history?channel={channel_id}&limit={min(limit,200)}"
    res = _http("GET", url, {"Authorization": f"Bearer {token}"})
    if not res.get("ok"):
        raise RuntimeError(f"slack history failed: {res.get('error')}")
    seen: set[str] = set()
    for m in res.get("messages", []):
        for sfid in re.findall(r"sfid:([a-zA-Z0-9]{15,18})", m.get("text", "")):
            seen.add(sfid)
    return seen


def slack_post(channel_id: str, text: str) -> dict:
    return slack_call("chat.postMessage",
                      {"channel": channel_id, "text": text, "unfurl_links": False})


def slack_permalink(channel_id: str, ts: str) -> str:
    token = os.environ["SLACK_BOT_TOKEN"]
    url = f"{SLACK}/chat.getPermalink?channel={channel_id}&message_ts={ts}"
    res = _http("GET", url, {"Authorization": f"Bearer {token}"})
    return res.get("permalink", "") if res.get("ok") else ""


def slack_dm_channel(user_id: str) -> str:
    return slack_call("conversations.open", {"users": user_id})["channel"]["id"]


# --- Notion watchlist ---------------------------------------------------------
def notion_watchlist() -> list[dict]:
    token = os.environ.get("NOTION_TOKEN") or os.environ["NOTION_API_TOKEN"]
    ds = os.environ.get("LICENCE_WATCHLIST_DS_ID", "1d72ac2d-853f-43ad-b7dc-a505a210c534")
    url = f"https://api.notion.com/v1/data_sources/{ds}/query"
    headers = {"Authorization": f"Bearer {token}",
               "Notion-Version": "2025-09-03",
               "Content-Type": "application/json"}
    body = {"filter": {"property": "Active", "checkbox": {"equals": True}}}
    res = _http("POST", url, headers, json.dumps(body).encode())
    rules = []
    for row in res.get("results", []):
        p = row.get("properties", {})
        title = "".join(t.get("plain_text", "") for t in p.get("Match", {}).get("title", []))
        mtype = (p.get("Match Type", {}).get("select") or {}).get("name", "Customer Contains")
        todoist = p.get("Create Todoist", {}).get("checkbox", False)
        if title.strip():
            rules.append({"match": title.strip(), "type": mtype, "todoist": todoist})
    return rules


def match_watchlist(rec: dict, area: str | None, rules: list[dict]) -> dict | None:
    customer = ((rec.get("CusomerAccount__r") or {}).get("Name") or "")
    partner = ((rec.get("AMM_Partner_Account__r") or {}).get("Name") or "")
    country = rec.get("Country__c") or ""
    for r in rules:
        term = r["match"].lower()
        t = r["type"]
        hit = ((t == "Customer Contains" and term in customer.lower()) or
               (t == "Exact Customer" and term == customer.lower()) or
               (t == "Country" and term == country.lower()) or
               (t == "Partner" and term in partner.lower()))
        if hit:
            return r
    return None


# --- Todoist ------------------------------------------------------------------
def todoist_task(content: str, description: str) -> None:
    token = os.environ["TODOIST_API_TOKEN"]
    body = {"content": content, "description": description,
            "due_string": "today", "priority": 3, "labels": ["licence"]}
    _http("POST", "https://api.todoist.com/api/v1/tasks",
          {"Authorization": f"Bearer {token}",
           "Content-Type": "application/json"}, json.dumps(body).encode())


# --- formatting ---------------------------------------------------------------
FLAG = {"UK & Ireland": "🇬🇧", "France": "🇫🇷", "Germany & Austria": "🇩🇪",
        "Netherlands": "🇳🇱", "Switzerland": "🇨🇭", "Europe North": "🇪🇺",
        "Europe South": "🇪🇺", "MEA": "🌍"}


def feed_line(rec: dict, cls: EmeaResult, instance: str) -> str:
    customer = (rec.get("CusomerAccount__r") or {}).get("Name") or "—"
    country = rec.get("Country__c") or "?"
    status = rec.get("Status__c") or "?"
    area = cls.area or ("⚠️ REVIEW" if cls.kind == "review" else "?")
    icon = FLAG.get(cls.area or "", "🗂️" if cls.kind == "review" else "•")
    link = sf_link(instance, rec["Id"])
    human = f"{icon} *{customer}* · {country} / {area} · {status} · <{link}|Salesforce ↗>"
    footer = (f"\n`sfid:{rec['Id']}  guid:{rec.get('Licence_GUID__c') or '-'}  "
              f"acct:{customer}`")
    return human + footer


# --- state / logging ----------------------------------------------------------
def state_dir() -> Path:
    d = Path(os.environ.get("LICENCE_STATE_DIR",
                            str(Path.home() / ".local/state/licence-watcher")))
    d.mkdir(parents=True, exist_ok=True)
    return d


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"{ts} {msg}"
    print(line, flush=True)
    try:
        with open(state_dir() / "watcher.log", "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def heartbeat(ok: bool, detail: str) -> None:
    try:
        (state_dir() / "heartbeat.json").write_text(json.dumps({
            "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "ok": ok, "detail": detail}))
    except OSError:
        pass


def alert_failure(err: str) -> None:
    """Cron monitoring: on failure, DM the ping user so a broken run is visible."""
    heartbeat(False, err)
    log(f"ERROR {err}")
    try:
        user = os.environ.get("LICENCE_PING_USER_ID", "U0BLN3B8TCZ")
        dm = slack_dm_channel(user)
        slack_post(dm, f"⚠️ *Licence watcher run failed* — {err}")
    except Exception as e:  # noqa: BLE001 - never mask the original error
        log(f"(could not send failure alert: {e})")


# --- modes --------------------------------------------------------------------
def do_run(dry: bool) -> int:
    window = int(os.environ.get("LICENCE_WINDOW_MINUTES", "30"))
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=window)) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    channel = os.environ.get("LICENCE_FEED_CHANNEL_ID", "C0BP0TZTAG7")
    ping_user = os.environ.get("LICENCE_PING_USER_ID", "U0BLN3B8TCZ")

    recs = sf_query_since(cutoff)
    log(f"fetched {len(recs)} requests since {cutoff} (window {window}m)")

    seen = set() if dry else slack_seen_sfids(channel)
    rules = [] if dry and not os.environ.get("NOTION_TOKEN") else notion_watchlist()
    posted = skipped = pinged = tasks = 0

    for rec in recs:
        cls = classify(rec)
        if cls.kind == "skip":
            skipped += 1
            continue
        if rec["Id"] in seen:
            continue
        line = feed_line(rec, cls, "")
        rule = match_watchlist(rec, cls.area, rules)
        if dry:
            tag = f"  [watchlist:{rule['match']}]" if rule else ""
            log(f"WOULD POST ({cls.kind}){tag}: {line.splitlines()[0]}")
            posted += 1
            continue
        msg = slack_post(channel, line)
        posted += 1
        permalink = slack_permalink(channel, msg["ts"])
        if rule:
            customer = (rec.get("CusomerAccount__r") or {}).get("Name") or "—"
            dm = slack_dm_channel(ping_user)
            slack_post(dm, f"🎯 *Watchlist hit — {rule['match']}*\n"
                           f"{customer} licence request just landed.\n{permalink}")
            pinged += 1
            if rule.get("todoist") and os.environ.get("TODOIST_API_TOKEN"):
                todoist_task(
                    f"Licence request in: {customer} — {cls.area or 'review'}",
                    f"Status {rec.get('Status__c')} · {rec.get('Country__c')}\n"
                    f"Salesforce: {sf_link('', rec['Id'])}\nSlack: {permalink}")
                tasks += 1

    summary = f"run done: posted={posted} skipped_non_emea={skipped} pinged={pinged} todoist={tasks} dry={dry}"
    log(summary)
    heartbeat(True, summary)
    return posted


def do_digest(dry: bool) -> None:
    hours = int(os.environ.get("LICENCE_DIGEST_HOURS", "15"))
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    channel = os.environ.get("LICENCE_FEED_CHANNEL_ID", "C0BP0TZTAG7")
    ping_user = os.environ.get("LICENCE_PING_USER_ID", "U0BLN3B8TCZ")

    recs = sf_query_since(cutoff)
    rules = notion_watchlist() if os.environ.get("NOTION_TOKEN") else []
    emea = []
    for rec in recs:
        cls = classify(rec)
        if cls.kind == "skip":
            continue
        emea.append((rec, cls, match_watchlist(rec, cls.area, rules)))

    hits = [e for e in emea if e[2]]
    lines = [f"*Overnight EMEA licence requests* — {len(emea)} in the last {hours}h"]
    hb = json.loads((state_dir() / "heartbeat.json").read_text()) \
        if (state_dir() / "heartbeat.json").exists() else {}
    lines.append(f"_watcher last ran: {hb.get('at','?')} (ok={hb.get('ok','?')})_")
    if hits:
        lines.append(f"\n🎯 *Watchlist ({len(hits)}):*")
        for rec, cls, rule in hits:
            cust = (rec.get("CusomerAccount__r") or {}).get("Name") or "—"
            lines.append(f"• *{rule['match']}* → {cust} ({cls.area or 'review'})")
    lines.append("\n*All:*")
    for rec, cls, _ in emea:
        cust = (rec.get("CusomerAccount__r") or {}).get("Name") or "—"
        lines.append(f"• {cust} · {rec.get('Country__c') or '?'} / "
                     f"{cls.area or '⚠️ review'} · {rec.get('Status__c')}")
    text = "\n".join(lines)
    if dry:
        log("WOULD POST DIGEST:\n" + text)
    else:
        dm = slack_dm_channel(ping_user)
        slack_post(dm, text)
        log(f"digest posted: {len(emea)} emea, {len(hits)} watchlist hits")


def do_selftest() -> None:
    """SF + EMEA classification only — no Slack/Notion/Todoist needed."""
    hours = int(os.environ.get("LICENCE_DIGEST_HOURS", "24"))
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    recs = sf_query_since(cutoff)
    buckets = {"emea": 0, "review": 0, "skip": 0}
    log(f"selftest: {len(recs)} requests in last {hours}h")
    for rec in recs:
        cls = classify(rec)
        buckets[cls.kind] += 1
        cust = (rec.get("CusomerAccount__r") or {}).get("Name") or "—"
        mark = {"emea": "✅", "review": "⚠️", "skip": "  "}[cls.kind]
        print(f" {mark} {cls.kind:6} {cls.area or '':18} {rec.get('Country__c') or '(none)':18} "
              f"{rec.get('Status__c'):26} {cust}  [{cls.reason}]")
    print(f"\n totals: {buckets}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", nargs="?", default="run",
                    choices=["run", "digest", "selftest"])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    try:
        if args.mode == "selftest":
            do_selftest()
        elif args.mode == "digest":
            do_digest(args.dry_run)
        else:
            do_run(args.dry_run)
        return 0
    except KeyError as e:
        msg = f"missing required env var: {e}"
        (alert_failure(msg) if not args.dry_run and os.environ.get("SLACK_BOT_TOKEN")
         else log(f"ERROR {msg}"))
        return 2
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"
        (alert_failure(msg) if not args.dry_run and os.environ.get("SLACK_BOT_TOKEN")
         else log(f"ERROR {msg}"))
        return 1


if __name__ == "__main__":
    sys.exit(main())
