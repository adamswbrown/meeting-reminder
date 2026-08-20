#!/usr/bin/env python3
"""EMEA Licence Request Watcher.

Polls Salesforce for newly-created licence requests, filters to EMEA, and fans
each new one out to a Slack feed (+ loud watchlist ping + optional Todoist task).
The Slack feed doubles as the dedupe store and the reference index (each message
embeds sfid/guid).

Design: docs/plans/2026-08-11-emea-licence-request-watcher-design.md

Modes:
  run      one polling cycle (default). Use --dry-run to print without posting.
  digest   post the morning overnight summary (now includes a licence-renewals
           section: EMEA licences expiring soon / recently expired, changes-only).
  expiry   standalone renewal view. --full prints the whole current EMEA
           expiring/expired list (ignores changes-only state); otherwise the delta.
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
  LICENCE_SMTP_HOST, LICENCE_SMTP_PORT (587), LICENCE_SMTP_USER, LICENCE_SMTP_PASS
  LICENCE_EMAIL_TO (default adam@askadam.cloud), LICENCE_EMAIL_FROM (default SMTP_USER)
                          digest emails the overnight action list when SMTP is configured
  SUPPORT_CENTRAL_API_KEY / SUPC_KEY_FILE   Support Central key for licence expiry
  SUPC_BASE_URL             (default prod)   Support Central API base URL
  LICENCE_EXPIRY_AHEAD_DAYS (default 30)     "expiring" lookahead window
  LICENCE_EXPIRY_BEHIND_DAYS(default 30)     "expired" lookback window
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import smtplib
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path

# --- Salesforce fields we pull ------------------------------------------------
SF_FIELDS = [
    "Id", "Name", "CreatedDate", "Status__c", "Country__c", "Region__c",
    "CusomerAccount__r.Name", "AMM_Partner_Account__r.Name",
    "Partner_Domains__c", "Customer_Segment__c", "Licence_GUID__c",
    # Contacts for easy emailing (Customer_Contact__c is the customer's email).
    "Customer_Name__c", "Customer_Contact__c", "Requestor__c",
    "Email_contact_at_Assessment_Partner__c",
    "Partner_First_Name__c", "Partner_Last_Name__c",
]

# --- Deployment__c fields for the overnight deployments section ----------------
SF_DEPLOY_FIELDS = [
    "Id", "Customer_Name__c", "Deployment_Type__c", "Licence_Management_Type__c",
    "Plan__c", "Licence_GUID__c", "Deployment_Status__c", "Provisioning_Status__c",
    "CreatedDate",
    # Contact for easy emailing — resolved via the linked Lead.
    "Lead__r.Name", "Lead__r.Email",
]
# Channel split (see design 2026-08-12): Assessment Desk = deployment's Licence_GUID
# matches a Licence_Requests__c row; Partner = Licence_Management_Type__c 'Partner
# Managed'; everything else = Public plan (Direct / MarketPlace self-service).
DEPLOY_CHANNELS = [("desk", "🏛️  ASSESSMENT DESK"),
                   ("partner", "🤝  PARTNER"),
                   ("public", "🌐  PUBLIC PLAN")]

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


def sf_deployments_since(cutoff_iso: str) -> list[dict]:
    token, instance = sf_token()
    api = os.environ.get("SF_API_VERSION", "v61.0")
    soql = (f"SELECT {', '.join(SF_DEPLOY_FIELDS)} FROM Deployment__c "
            f"WHERE CreatedDate >= {cutoff_iso} ORDER BY CreatedDate DESC")
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


def sf_licence_names_for_guids(guids: list[str]) -> dict[str, dict]:
    """Map deployment Licence_GUIDs to their Licence_Requests__c row (name + id),
    so a deployment can be tagged Assessment Desk even if its request is older than
    the digest window. Returns {guid: {"name": ..., "id": ...}}."""
    guids = [g for g in {g for g in guids if g}]
    if not guids:
        return {}
    token, instance = sf_token()
    api = os.environ.get("SF_API_VERSION", "v61.0")
    quoted = ", ".join("'" + g.replace("'", "") + "'" for g in guids)
    soql = (f"SELECT Id, Name, Licence_GUID__c FROM Licence_Requests__c "
            f"WHERE Licence_GUID__c IN ({quoted})")
    url = f"{instance}/services/data/{api}/query?q={urllib.parse.quote(soql)}"
    res = _http("GET", url, {"Authorization": f"Bearer {token}"})
    out: dict[str, dict] = {}
    for r in res.get("records", []):
        out[r["Licence_GUID__c"]] = {"name": r.get("Name"), "id": r["Id"]}
    return out


def deploy_channel(dep: dict, lr_by_guid: dict) -> str:
    guid = dep.get("Licence_GUID__c")
    if guid and guid in lr_by_guid:
        return "desk"
    if (dep.get("Licence_Management_Type__c") or "") == "Partner Managed":
        return "partner"
    return "public"


def deploy_status(dep: dict) -> str:
    return (dep.get("Deployment_Status__c") or dep.get("Provisioning_Status__c")
            or "new")


def bucket_deployments(deps: list[dict], lr_by_guid: dict) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = {"desk": [], "partner": [], "public": []}
    for dep in deps:
        groups[deploy_channel(dep, lr_by_guid)].append(dep)
    return groups


# --- contacts (for easy emailing) ---------------------------------------------
def _dedupe_name(first: str | None, last: str | None) -> str:
    parts = [p for p in [(first or "").strip(), (last or "").strip()] if p]
    if len(parts) == 2 and parts[0].lower() == parts[1].lower():
        return parts[0]  # SF often stores first==last (e.g. "Teemu"/"Teemu")
    return " ".join(parts)


def customer_display(rec: dict) -> str:
    """Org name if the account is linked, else the contact person, else em dash."""
    return ((rec.get("CusomerAccount__r") or {}).get("Name")
            or (rec.get("Customer_Name__c") or "").strip() or "—")


def licence_contacts(rec: dict) -> list[tuple[str, str]]:
    """(name, email) pairs to email about a licence request: customer, then partner."""
    out: list[tuple[str, str]] = []
    ce = (rec.get("Customer_Contact__c") or "").strip()
    if "@" in ce:
        out.append(((rec.get("Customer_Name__c") or "").strip() or ce, ce))
    pe = (rec.get("Email_contact_at_Assessment_Partner__c")
          or rec.get("Requestor__c") or "").strip()
    if "@" in pe and pe.lower() != ce.lower():
        pname = _dedupe_name(rec.get("Partner_First_Name__c"),
                             rec.get("Partner_Last_Name__c"))
        out.append((pname or pe, pe))
    return out


def deploy_contacts(dep: dict) -> list[tuple[str, str]]:
    lead = dep.get("Lead__r") or {}
    email = (lead.get("Email") or "").strip()
    return [((lead.get("Name") or "").strip() or email, email)] if "@" in email else []


def contacts_text(contacts: list[tuple[str, str]]) -> str:
    return " · ".join((f"✉ {e}" if n == e else f"✉ {n} <{e}>") for n, e in contacts)


def contacts_slack(contacts: list[tuple[str, str]]) -> str:
    return " · ".join(f"✉ <mailto:{e}|{n}>" for n, e in contacts)


def contacts_html(contacts: list[tuple[str, str]]) -> str:
    if not contacts:
        return ""
    inner = " · ".join(
        f'✉&nbsp;<a href="mailto:{html.escape(e)}" '
        f'style="color:#0f766e;text-decoration:none;">{_esc(n)}</a>'
        for n, e in contacts)
    return f'<div style="font-size:12px;margin-top:3px;color:#0f766e;">{inner}</div>'


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


# --- Support Central: licence expiry ------------------------------------------
# license_info (bare list, one row per deployment) is the authoritative renewal
# source. It carries no country — the EMEA constraint is applied by joining
# LicenceGuid back to Licence_Requests__c (same classify() as the daily watcher).
SUPC_BASE_URL = os.environ.get(
    "SUPC_BASE_URL", "https://app-drm-prd-ase-supc-api.azurewebsites.net")
# Licence types that are dead / not worth a renewal conversation.
EXPIRY_EXCLUDE_LICENCES = {"Cancel License"}
_KEY_TAG_RE = re.compile(r"<[^>]+>")


def supc_api_key() -> str:
    """Resolve the Support Central key: env var, else SUPC_KEY_FILE (may be an
    HTML page wrapping the token — mirrors supc_mcp.key_loader.extract_key)."""
    direct = os.environ.get("SUPPORT_CENTRAL_API_KEY")
    if direct:
        return direct.strip()
    key_file = os.environ.get(
        "SUPC_KEY_FILE",
        str(Path.home() / "Developer/Altra/drm-support-central/key.txt.html"))
    if key_file and os.path.isfile(key_file):
        with open(key_file, encoding="utf-8", errors="replace") as fh:
            text = html.unescape(_KEY_TAG_RE.sub(" ", fh.read()))
        for tok in text.split():
            if len(tok) >= 16:
                return tok
    raise RuntimeError("No Support Central API key: set SUPPORT_CENTRAL_API_KEY "
                       "or point SUPC_KEY_FILE at the key file.")


def supc_license_info() -> list[dict]:
    """GET /api/license-information — every licence row (bare list)."""
    url = f"{SUPC_BASE_URL.rstrip('/')}/api/license-information?limit=200&page=1"
    body = _http("GET", url, {"X-API-Key": supc_api_key(),
                              "Accept": "application/json"})
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        data = body.get("data") or body.get("metrics")
        if isinstance(data, list):
            return data
    return []


def _parse_iso_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(value[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def expiry_window(lic: list[dict], now: datetime, ahead: int, behind: int) -> list[dict]:
    """Filter licences to the chase-worthy renewal window. Returns rows augmented
    with bucket ('expiring' | 'expired') and days (+ = ahead, - = elapsed)."""
    out: list[dict] = []
    for row in lic:
        ctype = row.get("CurrentLicence")
        if not ctype or ctype in EXPIRY_EXCLUDE_LICENCES:
            continue
        rd = _parse_iso_date(row.get("RenewalDate"))
        if rd is None:
            continue
        days = (rd - now).days
        if 0 <= days <= ahead:
            bucket = "expiring"
        elif -behind <= days < 0:
            bucket = "expired"
        else:
            continue
        out.append({**row, "_bucket": bucket, "_days": days, "_renewal": rd})
    # license_info can carry the same LicenceGuid twice — collapse to the soonest
    # renewal per guid so a licence is chased once. Rows with no guid are dropped:
    # they can't join to Salesforce (no region filter) nor dedupe (would repeat).
    by_guid: dict[str, dict] = {}
    for r in out:
        guid = r.get("LicenceGuid")
        if not guid:
            continue
        prev = by_guid.get(guid)
        if prev is None or r["_days"] < prev["_days"]:
            by_guid[guid] = r
    return list(by_guid.values())


def sf_licence_rows_for_guids(guids: list[str]) -> dict[str, dict]:
    """Map LicenceGuid -> a Licence_Requests__c record (country/region/contacts)
    for EMEA classification and follow-up. Newest row wins per guid. Chunked to
    keep the SOQL/URL within limits."""
    guids = [g for g in {g for g in guids if g}]
    if not guids:
        return {}
    token, instance = sf_token()
    api = os.environ.get("SF_API_VERSION", "v61.0")
    fields = ["Id", "Name", "Licence_GUID__c", "CreatedDate", "Status__c",
              "Country__c", "Region__c", "CusomerAccount__r.Name",
              "Customer_Name__c", "Customer_Contact__c", "Requestor__c",
              "Email_contact_at_Assessment_Partner__c",
              "Partner_First_Name__c", "Partner_Last_Name__c"]
    out: dict[str, dict] = {}
    for i in range(0, len(guids), 150):
        chunk = guids[i:i + 150]
        quoted = ", ".join("'" + g.replace("'", "") + "'" for g in chunk)
        soql = (f"SELECT {', '.join(fields)} FROM Licence_Requests__c "
                f"WHERE Licence_GUID__c IN ({quoted}) ORDER BY CreatedDate DESC")
        url = f"{instance}/services/data/{api}/query?q={urllib.parse.quote(soql)}"
        res = _http("GET", url, {"Authorization": f"Bearer {token}"})
        for r in res.get("records", []):
            out.setdefault(r["Licence_GUID__c"], r)  # newest first, keep it
    return out


def sf_deploy_geo_for_guids(guids: list[str]) -> dict[str, dict]:
    """Fallback geo for licences with no Licence_Requests__c row: map LicenceGuid ->
    a classify()-shaped dict {Country__c, Region__c} from Deployment__c's linked
    Account (Country__c) and Lead (Location__c, an Azure region hint). Rows with a
    country win; chunked to keep the SOQL/URL within limits."""
    guids = [g for g in {g for g in guids if g}]
    if not guids:
        return {}
    token, instance = sf_token()
    api = os.environ.get("SF_API_VERSION", "v61.0")
    out: dict[str, dict] = {}
    for i in range(0, len(guids), 150):
        chunk = guids[i:i + 150]
        quoted = ", ".join("'" + g.replace("'", "") + "'" for g in chunk)
        soql = ("SELECT Licence_GUID__c, Account__r.Country__c, Lead__r.Location__c "
                f"FROM Deployment__c WHERE Licence_GUID__c IN ({quoted})")
        url = f"{instance}/services/data/{api}/query?q={urllib.parse.quote(soql)}"
        res = _http("GET", url, {"Authorization": f"Bearer {token}"})
        for r in res.get("records", []):
            guid = r["Licence_GUID__c"]
            country = (r.get("Account__r") or {}).get("Country__c")
            region = (r.get("Lead__r") or {}).get("Location__c")
            prev = out.get(guid)
            # Keep the first row, but let a later row with a country override a blank.
            if prev is None or (not prev.get("Country__c") and country):
                out[guid] = {"Country__c": country, "Region__c": region}
    return out


def expiry_rows(now: datetime, ahead: int, behind: int,
                suppress_guids: set[str] | None = None) -> list[dict]:
    """Full pipeline: fetch, window-filter, EMEA-classify, enrich. Returns rows
    (both buckets) that are EMEA or region-unknown, sorted expiring-soonest first.
    suppress_guids drops licences already shown elsewhere in the digest.

    Region is resolved first from Licence_Requests__c (also gives link + contacts),
    then falling back to Deployment__c's Account/Lead geo, then 'region unknown'.
    Non-EMEA licences are dropped at whichever stage resolves their country."""
    suppress = suppress_guids or set()
    windowed = [r for r in expiry_window(supc_license_info(), now, ahead, behind)
                if (r.get("LicenceGuid") or "") not in suppress]
    lr_by_guid = sf_licence_rows_for_guids([r.get("LicenceGuid") for r in windowed])
    unmatched = [r.get("LicenceGuid") for r in windowed
                 if (r.get("LicenceGuid") or "") not in lr_by_guid]
    geo_by_guid = sf_deploy_geo_for_guids(unmatched)
    rows: list[dict] = []
    for r in windowed:
        guid = r.get("LicenceGuid") or ""
        lr = lr_by_guid.get(guid)
        if lr:
            cls = classify(lr)
        elif geo_by_guid.get(guid):
            cls = classify(geo_by_guid[guid])
        else:
            cls = EmeaResult("review", None, "no SF record")
        if cls.kind == "skip":  # resolved to a non-EMEA country — drop it
            continue
        rows.append({**r, "_lr": lr, "_cls": cls})
    rows.sort(key=lambda x: x["_days"])
    return rows


def expiry_state_path() -> Path:
    return state_dir() / "expiry-seen.json"


def expiry_load_seen() -> dict[str, str]:
    p = expiry_state_path()
    if p.exists():
        try:
            return json.loads(p.read_text())
        except (OSError, ValueError):
            return {}
    return {}


def expiry_new_only(rows: list[dict], seen: dict[str, str]) -> list[dict]:
    """Changes-only: keep rows whose (guid, bucket) pair differs from last run."""
    fresh = []
    for r in rows:
        guid = r.get("LicenceGuid") or ""
        if not guid or seen.get(guid) != r["_bucket"]:
            fresh.append(r)
    return fresh


def expiry_save_seen(rows: list[dict]) -> None:
    """Persist the current in-window map (guid -> bucket). Rewriting to the live
    set both dedupes and prunes rows that have left the window."""
    try:
        expiry_state_path().write_text(json.dumps(
            {r["LicenceGuid"]: r["_bucket"] for r in rows if r.get("LicenceGuid")}))
    except OSError:
        pass


def expiry_customer(r: dict) -> str:
    lr = r.get("_lr")
    if lr:
        return customer_display(lr)
    return (r.get("CustomerName") or "").strip() or "—"


def expiry_when(r: dict) -> str:
    d = r["_days"]
    if d > 0:
        return f"renews in {d}d"
    if d == 0:
        return "renews today"
    return f"expired {-d}d ago"


EXPIRY_GROUPS = [("expiring", "⏳ EXPIRING (next {ahead}d)"),
                 ("expired", "🔴 EXPIRED (last {behind}d)")]


def _expiry_grouped(rows: list[dict]) -> dict[str, list[dict]]:
    g: dict[str, list[dict]] = {"expiring": [], "expired": []}
    for r in rows:
        g[r["_bucket"]].append(r)
    return g


def expiry_slack_lines(rows: list[dict], ahead: int, behind: int) -> list[str]:
    if not rows:
        return []
    g = _expiry_grouped(rows)
    lines = [f"\n*Licence renewals ({len(rows)}):*"]
    for key, label in EXPIRY_GROUPS:
        grp = g[key]
        if not grp:
            continue
        lines.append(label.format(ahead=ahead, behind=behind) + f" ({len(grp)}):")
        for r in grp:
            cls = r["_cls"]
            area = cls.area or "⚠️ region unknown"
            lr = r.get("_lr")
            name = expiry_customer(r)
            title = (f"<{sf_link('', lr['Id'])}|{name}>" if lr else name)
            lines.append(f"• {title} · {r.get('CurrentLicence')} · "
                         f"{expiry_when(r)} · {area}")
            cts = contacts_slack(licence_contacts(lr)) if lr else ""
            if cts:
                lines.append(f"    {cts}")
    return lines


def expiry_email_lines(rows: list[dict], ahead: int, behind: int) -> list[str]:
    if not rows:
        return []
    g = _expiry_grouped(rows)
    lines = ["", f"LICENCE RENEWALS ({len(rows)}):"]
    for key, label in EXPIRY_GROUPS:
        grp = g[key]
        if not grp:
            continue
        lines.append(f"\n  {label.format(ahead=ahead, behind=behind)} ({len(grp)}):")
        for r in grp:
            cls = r["_cls"]
            area = cls.area or "region unknown"
            lines.append(f"    • {expiry_customer(r)} · {r.get('CurrentLicence')} · "
                         f"{expiry_when(r)} · {area}")
            lr = r.get("_lr")
            if lr:
                lines.append(f"      {sf_link('', lr['Id'])}   "
                             f"guid:{r.get('LicenceGuid') or '-'}")
                cts = contacts_text(licence_contacts(lr))
                if cts:
                    lines.append(f"      {cts}")
            else:
                lines.append(f"      guid:{r.get('LicenceGuid') or '-'}  "
                             f"deployment:{r.get('DeploymentId') or '-'}")
    return lines


EXPIRY_COLOUR = {"expiring": "#d97706", "expired": "#dc2626"}


def expiry_html_rows(rows: list[dict], ahead: int, behind: int) -> str:
    if not rows:
        return ""
    g = _expiry_grouped(rows)
    out = [('<tr><td style="padding:16px 18px 4px;"><div style="font-size:12px;'
            'font-weight:700;letter-spacing:.5px;color:#697386;text-transform:uppercase;">'
            f'Licence renewals ({len(rows)})</div></td></tr>'),
           '<tr><td style="padding:0 4px 8px;"><table role="presentation" width="100%" '
           'cellpadding="0" cellspacing="0">']
    for key, label in EXPIRY_GROUPS:
        grp = g[key]
        if not grp:
            continue
        out.append(f'<tr><td style="padding:10px 14px 4px;"><span style="display:inline-block;'
                   f'background:{EXPIRY_COLOUR[key]};color:#fff;font-size:11px;font-weight:700;'
                   f'padding:2px 8px;border-radius:10px;">'
                   f'{_esc(label.format(ahead=ahead, behind=behind))} · {len(grp)}</span></td></tr>')
        for r in grp:
            cls = r["_cls"]
            area = cls.area or "region unknown"
            meta = f'{_esc(r.get("CurrentLicence"))} · {_esc(expiry_when(r))} · {_esc(area)}'
            lr = r.get("_lr")
            link = sf_link('', lr['Id']) if lr else '#'
            extra = contacts_html(licence_contacts(lr)) if lr else ""
            out.append(_row(link, expiry_customer(r), meta, extra))
    out.append('</table></td></tr>')
    return "".join(out)


def expiry_counts(rows: list[dict]) -> tuple[int, int]:
    g = _expiry_grouped(rows)
    return len(g["expiring"]), len(g["expired"])


def expiry_subject(rows: list[dict]) -> str:
    exp, expd = expiry_counts(rows)
    return f"Licence renewals — {exp} expiring / {expd} expired (EMEA)"


def expiry_email_text_doc(rows: list[dict], ahead: int, behind: int) -> str:
    exp, expd = expiry_counts(rows)
    head = [f"EMEA licence renewals — {exp} expiring (next {ahead}d), "
            f"{expd} expired (last {behind}d)", ""]
    return "\n".join(head + expiry_email_lines(rows, ahead, behind)[1:])  # drop dup title


def expiry_email_html_doc(rows: list[dict], ahead: int, behind: int) -> str:
    """Standalone renewals email — own header/subject, same styling as the digest."""
    exp, expd = expiry_counts(rows)
    px = ("font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,"
          "Arial,sans-serif;")
    return "".join([
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '</head><body style="margin:0;padding:0;background:#f4f5f7;">',
        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
        f'style="background:#f4f5f7;padding:20px 0;{px}"><tr><td align="center">',
        '<table role="presentation" width="640" cellpadding="0" cellspacing="0" '
        'style="max-width:640px;width:100%;background:#ffffff;border-radius:10px;'
        'overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.08);">',
        '<tr><td style="background:#7c2d12;padding:18px 22px;">'
        '<div style="color:#ffffff;font-size:17px;font-weight:700;">'
        'EMEA licence renewals</div>'
        f'<div style="color:#fed7aa;font-size:12px;margin-top:3px;">'
        f'{exp} expiring (next {ahead}d) · {expd} expired (last {behind}d) · '
        'renewal follow-up</div></td></tr>',
        expiry_html_rows(rows, ahead, behind),
        '<tr><td style="background:#f8fafc;padding:12px 18px;color:#697386;'
        f'font-size:12px;border-top:1px solid #eceef1;">{exp + expd} EMEA licences '
        f'to follow up ({exp} expiring / {expd} expired)</td></tr>',
        '</table></td></tr></table></body></html>',
    ])


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


# --- Email (SMTP) -------------------------------------------------------------
def smtp_configured() -> bool:
    return bool(os.environ.get("LICENCE_SMTP_HOST")
                and os.environ.get("LICENCE_SMTP_USER")
                and os.environ.get("LICENCE_SMTP_PASS"))


def send_email(subject: str, text_body: str, html_body: str | None = None) -> None:
    """Send the digest via SMTP+STARTTLS. Config comes from the local secrets file.
    Sends multipart/alternative when html_body is given (plaintext stays the fallback)."""
    host = os.environ["LICENCE_SMTP_HOST"]
    port = int(os.environ.get("LICENCE_SMTP_PORT", "587"))
    user = os.environ["LICENCE_SMTP_USER"]
    password = os.environ["LICENCE_SMTP_PASS"]
    sender = os.environ.get("LICENCE_EMAIL_FROM", user)
    # LICENCE_EMAIL_TO may be a comma-separated list; send_message reads the To header.
    recipients = [a.strip() for a in
                  os.environ.get("LICENCE_EMAIL_TO", "adam@askadam.cloud").split(",")
                  if a.strip()]
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg.set_content(text_body)
    if html_body:
        msg.add_alternative(html_body, subtype="html")
    with smtplib.SMTP(host, port, timeout=30) as s:
        s.starttls()
        s.login(user, password)
        s.send_message(msg)


def deploy_email_lines(groups: dict, lr_by_guid: dict) -> list[str]:
    """Deployments section for the email — one bucket per channel, each row linked."""
    total = sum(len(v) for v in groups.values())
    lines = [f"DEPLOYMENTS ({total}):"]
    for key, label in DEPLOY_CHANNELS:
        rows = groups.get(key, [])
        if not rows:
            continue
        lines.append(f"\n  {label} ({len(rows)}):")
        for dep in rows:
            cust = dep.get("Customer_Name__c") or "—"
            meta = " · ".join(filter(None, [
                dep.get("Licence_Management_Type__c") or dep.get("Deployment_Type__c"),
                deploy_status(dep)]))
            lines.append(f"    • {cust} · {meta}")
            lines.append(f"      {sf_link('', dep['Id'])}   guid:{dep.get('Licence_GUID__c') or '-'}")
            cts = contacts_text(deploy_contacts(dep))
            if cts:
                lines.append(f"      {cts}")
            lr = lr_by_guid.get(dep.get("Licence_GUID__c") or "")
            if lr:
                lines.append(f"      ↳ licence request {lr['name']}: {sf_link('', lr['id'])}")
    return lines


def digest_email_body(emea: list, hits: list, hours: int, hb: dict,
                      deploy_groups: dict | None = None,
                      lr_by_guid: dict | None = None) -> str:
    """Action-first plaintext hit-list for the overnight email. Every row carries a
    Salesforce link (and a guid tag) for follow-up / referencing back in chat."""
    lines = [f"Overnight — {len(emea)} EMEA licence requests in the last {hours}h",
             f"Watcher last ran: {hb.get('at', '?')} (ok={hb.get('ok', '?')})", ""]
    if hits:
        lines.append(f">>> ACTION NEEDED — watchlist hits ({len(hits)}):")
        for rec, cls, rule in hits:
            lines.append(f"  • [{rule['match']}] {customer_display(rec)} · "
                         f"{cls.area or 'review'} · {rec.get('Status__c')}")
            lines.append(f"    {sf_link('', rec['Id'])}")
        lines.append("")
    else:
        lines.append(">>> No watchlist hits overnight — nothing flagged to action.")
        lines.append("")
    lines.append(f"EMEA LICENCE REQUESTS ({len(emea)}):")
    for rec, cls, _ in emea:
        lines.append(f"  • {customer_display(rec)} · {rec.get('Country__c') or '?'} / "
                     f"{cls.area or 'review'} · {rec.get('Status__c')}")
        lines.append(f"    {sf_link('', rec['Id'])}   guid:{rec.get('Licence_GUID__c') or '-'}")
        cts = contacts_text(licence_contacts(rec))
        if cts:
            lines.append(f"    {cts}")
    if deploy_groups is not None:
        lines.append("")
        lines.extend(deploy_email_lines(deploy_groups, lr_by_guid or {}))
    return "\n".join(lines)


# --- HTML email ---------------------------------------------------------------
CHANNEL_COLOUR = {"desk": "#7c3aed", "partner": "#0891b2", "public": "#16a34a"}


def _esc(v) -> str:
    return html.escape(str(v if v not in (None, "") else "—"))


def _row(link_url: str, title: str, meta: str, extra: str = "") -> str:
    """One record row: linked title, muted meta line, optional extra (guid / LR link)."""
    return (
        '<tr><td style="padding:9px 14px;border-bottom:1px solid #eceef1;">'
        f'<a href="{html.escape(link_url)}" style="color:#1a56db;text-decoration:none;'
        f'font-weight:600;font-size:14px;">{_esc(title)}</a>'
        f'<div style="color:#697386;font-size:12px;margin-top:2px;">{meta}</div>'
        f'{extra}</td></tr>')


def digest_html_body(emea: list, hits: list, hours: int, hb: dict,
                     deploy_groups: dict, lr_by_guid: dict) -> str:
    deps_total = sum(len(v) for v in deploy_groups.values())
    px = ("font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,"
          "Arial,sans-serif;")
    out = [
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '</head><body style="margin:0;padding:0;background:#f4f5f7;">',
        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
        f'style="background:#f4f5f7;padding:20px 0;{px}"><tr><td align="center">',
        '<table role="presentation" width="640" cellpadding="0" cellspacing="0" '
        'style="max-width:640px;width:100%;background:#ffffff;border-radius:10px;'
        'overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.08);">',
        # header
        '<tr><td style="background:#0f172a;padding:18px 22px;">'
        '<div style="color:#ffffff;font-size:17px;font-weight:700;">Overnight Altra activity</div>'
        f'<div style="color:#94a3b8;font-size:12px;margin-top:3px;">Last {hours}h · watcher '
        f'last ran {_esc(hb.get("at", "?"))} (ok={_esc(hb.get("ok", "?"))})</div></td></tr>',
    ]
    # action banner
    if hits:
        rows = "".join(
            f'<div style="font-size:13px;margin-top:4px;">🎯 <b>{_esc(r["match"])}</b> → '
            f'{_esc(customer_display(rec))} ({_esc(cls.area or "review")})</div>'
            for rec, cls, r in hits)
        out.append('<tr><td style="background:#fef3c7;border-left:4px solid #f59e0b;'
                   f'padding:12px 18px;"><b style="color:#92400e;">⚠️ Action needed — '
                   f'{len(hits)} watchlist hit(s)</b>{rows}</td></tr>')
    else:
        out.append('<tr><td style="background:#ecfdf5;border-left:4px solid #10b981;'
                   'padding:12px 18px;color:#065f46;font-size:13px;">'
                   '✓ No watchlist hits overnight — nothing flagged to action.</td></tr>')

    def section(title: str) -> str:
        return ('<tr><td style="padding:16px 18px 4px;"><div style="font-size:12px;'
                'font-weight:700;letter-spacing:.5px;color:#697386;text-transform:uppercase;">'
                f'{title}</div></td></tr>')

    # licence requests
    out.append(section(f"EMEA licence requests ({len(emea)})"))
    out.append('<tr><td style="padding:0 4px;"><table role="presentation" width="100%" '
               'cellpadding="0" cellspacing="0">')
    for rec, cls, _ in emea:
        meta = (f'{_esc(rec.get("Country__c") or "?")} / {_esc(cls.area or "review")} · '
                f'{_esc(rec.get("Status__c"))}')
        out.append(_row(sf_link("", rec["Id"]), customer_display(rec), meta,
                        contacts_html(licence_contacts(rec))))
    out.append('</table></td></tr>')

    # deployments
    out.append(section(f"Deployments ({deps_total})"))
    out.append('<tr><td style="padding:0 4px 8px;"><table role="presentation" width="100%" '
               'cellpadding="0" cellspacing="0">')
    for key, label in DEPLOY_CHANNELS:
        drows = deploy_groups.get(key, [])
        if not drows:
            continue
        out.append(f'<tr><td style="padding:10px 14px 4px;"><span style="display:inline-block;'
                   f'background:{CHANNEL_COLOUR[key]};color:#fff;font-size:11px;font-weight:700;'
                   f'padding:2px 8px;border-radius:10px;">{label} · {len(drows)}</span></td></tr>')
        for dep in drows:
            meta = (f'{_esc(dep.get("Licence_Management_Type__c") or dep.get("Deployment_Type__c"))}'
                    f' · {_esc(deploy_status(dep))}')
            extra = contacts_html(deploy_contacts(dep))
            lr = lr_by_guid.get(dep.get("Licence_GUID__c") or "")
            if lr:
                extra += (f'<div style="font-size:11px;margin-top:2px;">↳ '
                          f'<a href="{html.escape(sf_link("", lr["id"]))}" '
                          f'style="color:#7c3aed;text-decoration:none;">licence request '
                          f'{_esc(lr["name"])}</a></div>')
            out.append(_row(sf_link("", dep["Id"]), dep.get("Customer_Name__c"), meta, extra))
    out.append('</table></td></tr>')

    # footer
    dc = {k: len(v) for k, v in deploy_groups.items()}
    out.append('<tr><td style="background:#f8fafc;padding:12px 18px;color:#697386;'
               f'font-size:12px;border-top:1px solid #eceef1;">{len(emea)} licence requests · '
               f'{deps_total} deployments ({dc["public"]} public / {dc["desk"]} desk / '
               f'{dc["partner"]} partner)</td></tr>')
    out.append('</table></td></tr></table></body></html>')
    return "".join(out)


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

    # Overnight deployments, split into Assessment Desk / Partner / Public plan.
    deps = sf_deployments_since(cutoff)
    lr_by_guid = sf_licence_names_for_guids(
        [d.get("Licence_GUID__c") for d in deps])
    groups = bucket_deployments(deps, lr_by_guid)
    dep_counts = {k: len(v) for k, v in groups.items()}

    # Expiring / expired EMEA licences (renewal follow-up). Changes-only: only
    # licences newly entering a bucket since last run; suppress guids already
    # shown above so nothing appears twice in one digest.
    ahead = int(os.environ.get("LICENCE_EXPIRY_AHEAD_DAYS", "30"))
    behind = int(os.environ.get("LICENCE_EXPIRY_BEHIND_DAYS", "30"))
    now = datetime.now(timezone.utc)
    suppress = {r.get("Licence_GUID__c") for r, _, _ in emea if r.get("Licence_GUID__c")}
    suppress |= {d.get("Licence_GUID__c") for d in deps if d.get("Licence_GUID__c")}
    all_expiry = expiry_rows(now, ahead, behind, suppress)
    seen = expiry_load_seen()
    expiry = expiry_new_only(all_expiry, seen)

    hits = [e for e in emea if e[2]]
    lines = [f"*Overnight EMEA licence requests* — {len(emea)} in the last {hours}h"]
    hb = json.loads((state_dir() / "heartbeat.json").read_text()) \
        if (state_dir() / "heartbeat.json").exists() else {}
    lines.append(f"_watcher last ran: {hb.get('at','?')} (ok={hb.get('ok','?')})_")
    if hits:
        lines.append(f"\n🎯 *Watchlist ({len(hits)}):*")
        for rec, cls, rule in hits:
            lines.append(f"• *{rule['match']}* → {customer_display(rec)} ({cls.area or 'review'})")
    lines.append("\n*Licence requests:*")
    for rec, cls, _ in emea:
        lines.append(f"• <{sf_link('', rec['Id'])}|{customer_display(rec)}> · "
                     f"{rec.get('Country__c') or '?'} / "
                     f"{cls.area or '⚠️ review'} · {rec.get('Status__c')}")
        cts = contacts_slack(licence_contacts(rec))
        if cts:
            lines.append(f"    {cts}")
    lines.append(f"\n*Deployments ({len(deps)}):*")
    for key, label in DEPLOY_CHANNELS:
        rows = groups.get(key, [])
        if not rows:
            continue
        lines.append(f"{label} ({len(rows)}):")
        for dep in rows:
            cust = dep.get("Customer_Name__c") or "—"
            lines.append(f"• <{sf_link('', dep['Id'])}|{cust}> · "
                         f"{dep.get('Licence_Management_Type__c') or dep.get('Deployment_Type__c') or '?'} "
                         f"· {deploy_status(dep)}")
            cts = contacts_slack(deploy_contacts(dep))
            if cts:
                lines.append(f"    {cts}")
    text = "\n".join(lines)
    dep_total = len(deps)
    email_subject = (f"Overnight — {len(emea)} EMEA licence requests · {dep_total} deployments "
                     f"({dep_counts['public']} public / {dep_counts['desk']} desk / "
                     f"{dep_counts['partner']} partner)"
                     f"{f' · {len(hits)} to action' if hits else ''}")
    email_body = digest_email_body(emea, hits, hours, hb, groups, lr_by_guid)
    email_html = digest_html_body(emea, hits, hours, hb, groups, lr_by_guid)
    # Licence renewals go out as their OWN email + Slack message (separate subject
    # and header), not folded into the overnight digest.
    expiry_subj = expiry_subject(expiry) if expiry else ""
    expiry_text = ("\n".join([f"*{expiry_subj}*"] + expiry_slack_lines(expiry, ahead, behind))
                   if expiry else "")
    expiry_body = expiry_email_text_doc(expiry, ahead, behind) if expiry else ""
    expiry_html = expiry_email_html_doc(expiry, ahead, behind) if expiry else ""
    if dry:
        log("WOULD POST DIGEST:\n" + text)
        preview = state_dir() / "digest-preview.html"
        preview.write_text(email_html, encoding="utf-8")
        log(f"WOULD EMAIL (smtp_configured={smtp_configured()}) subject={email_subject!r}"
            f"; HTML preview → {preview}\n" + email_body)
        if expiry:
            xpreview = state_dir() / "expiry-preview.html"
            xpreview.write_text(expiry_html, encoding="utf-8")
            log(f"WOULD POST + EMAIL RENEWALS subject={expiry_subj!r}; "
                f"HTML preview → {xpreview}\n" + expiry_text)
        else:
            log("no new licence renewals to send")
    else:
        dm = slack_dm_channel(ping_user)
        slack_post(dm, text)
        expiry_save_seen(all_expiry)
        log(f"digest posted: {len(emea)} emea, {len(hits)} watchlist hits, "
            f"{len(deps)} deployments {dep_counts}, "
            f"{len(expiry)} new licence renewals ({len(all_expiry)} in window)")
        if smtp_configured():
            try:
                send_email(email_subject, email_body, email_html)
                log(f"digest emailed to {os.environ.get('LICENCE_EMAIL_TO', 'adam@askadam.cloud')}")
            except Exception as e:  # noqa: BLE001 - email is best-effort, Slack already sent
                log(f"WARNING digest email failed: {type(e).__name__}: {e}")
        else:
            log("digest email skipped (SMTP not configured)")
        # Separate licence-renewals email + Slack DM (own subject/header).
        if expiry:
            slack_post(dm, expiry_text)
            if smtp_configured():
                try:
                    send_email(expiry_subj, expiry_body, expiry_html)
                    log(f"renewals emailed: {expiry_subj}")
                except Exception as e:  # noqa: BLE001 - best-effort, Slack already sent
                    log(f"WARNING renewals email failed: {type(e).__name__}: {e}")


def do_expiry(dry: bool, full: bool) -> None:
    """Standalone renewal view — its own Slack DM + email (separate subject/header).
    --full ignores the seen-state and sends the whole current EMEA expiring/expired
    list; otherwise it's the same changes-only delta the daily digest uses."""
    ahead = int(os.environ.get("LICENCE_EXPIRY_AHEAD_DAYS", "30"))
    behind = int(os.environ.get("LICENCE_EXPIRY_BEHIND_DAYS", "30"))
    ping_user = os.environ.get("LICENCE_PING_USER_ID", "U0BLN3B8TCZ")
    now = datetime.now(timezone.utc)
    rows = expiry_rows(now, ahead, behind)
    if not full:
        rows = expiry_new_only(rows, expiry_load_seen())
    if not rows:
        log("expiry: no EMEA licences expiring/expired in window (nothing to send)")
        return
    subject = expiry_subject(rows) + (" — full snapshot" if full else "")
    header = f"*{subject}*"
    text = "\n".join([header] + expiry_slack_lines(rows, ahead, behind))
    body = expiry_email_text_doc(rows, ahead, behind)
    html_doc = expiry_email_html_doc(rows, ahead, behind)
    if dry:
        preview = state_dir() / "expiry-preview.html"
        preview.write_text(html_doc, encoding="utf-8")
        log(f"WOULD POST + EMAIL RENEWALS subject={subject!r} "
            f"(smtp_configured={smtp_configured()}); HTML preview → {preview}\n" + text)
    else:
        slack_post(slack_dm_channel(ping_user), text)
        if smtp_configured():
            try:
                send_email(subject, body, html_doc)
                log(f"renewals emailed: {subject}")
            except Exception as e:  # noqa: BLE001 - best-effort, Slack already sent
                log(f"WARNING renewals email failed: {type(e).__name__}: {e}")
        if not full:
            expiry_save_seen(expiry_rows(now, ahead, behind))
        log(f"expiry posted: {len(rows)} rows (full={full})")


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
                    choices=["run", "digest", "expiry", "selftest"])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--full", action="store_true",
                    help="expiry mode: full snapshot, ignore changes-only state")
    args = ap.parse_args()
    try:
        if args.mode == "selftest":
            do_selftest()
        elif args.mode == "digest":
            do_digest(args.dry_run)
        elif args.mode == "expiry":
            do_expiry(args.dry_run, args.full)
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
