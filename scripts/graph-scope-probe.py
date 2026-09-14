#!/usr/bin/env python3
"""Delegated Microsoft Graph scope probe (stdlib only, nothing persisted).

Answers one question: which *user-consentable* delegated scopes does the
`altra.cloud` tenant actually grant to the first-party "Microsoft Graph
Command Line Tools" public client the app already uses for Mail.Send?

Two modes:
  --refresh   Exchange the app's stored refresh token (Keychain item
              `msGraphRefreshToken`, service `com.meetingreminder.app`) for an
              access token carrying the requested scopes. Non-interactive. If
              the user never consented to a scope, Entra answers AADSTS65001.
  (default)   Device-code flow: opens the browser, waits for sign-in, then
              probes. This is the path that can *grant* new consent.

Then hits /me/chats, /me/messages, /me/presence and prints ok/fail per
endpoint plus the `scp` claim decoded from the access token.

Usage:
  python3 scripts/graph-scope-probe.py --refresh
  python3 scripts/graph-scope-probe.py --scopes "Chat.ReadBasic"
"""

import argparse, base64, json, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, webbrowser

CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
TENANT = "altra.cloud"
DEFAULT_SCOPES = "Chat.Read Mail.Read offline_access openid profile"
GRAPH = "https://graph.microsoft.com/v1.0"
KEYCHAIN_SERVICE = "com.meetingreminder.app"
KEYCHAIN_ACCOUNT = "msGraphRefreshToken"


def qualify(scopes: str) -> str:
    out = []
    for s in scopes.split():
        if s in ("offline_access", "openid", "profile", "email") or "://" in s:
            out.append(s)
        else:
            out.append("https://graph.microsoft.com/" + s)
    return " ".join(out)


def post_form(url, params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {"error": "http", "error_description": body[:300]}


def get_json(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {"raw": body[:300]}


def decode_scp(token: str) -> str:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return claims.get("scp", "(no scp claim)")
    except Exception as e:  # noqa: BLE001
        return f"(could not decode: {e})"


def keychain_refresh_token() -> str:
    out = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(
            f"no refresh token in Keychain ({KEYCHAIN_SERVICE}/{KEYCHAIN_ACCOUNT}): {out.stderr.strip()}"
        )
    return out.stdout.strip()


def token_via_refresh(scopes: str):
    status, j = post_form(
        f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token",
        {
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "scope": qualify(scopes),
            "refresh_token": keychain_refresh_token(),
        },
    )
    return status, j


def token_via_device_code(scopes: str):
    base = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0"
    status, dc = post_form(
        f"{base}/devicecode", {"client_id": CLIENT_ID, "scope": qualify(scopes)}
    )
    if "device_code" not in dc:
        return status, dc
    print(
        f"\n>>> Sign in at {dc['verification_uri']} with code: {dc['user_code']}\n",
        flush=True,
    )
    webbrowser.open(dc["verification_uri"])
    interval = dc.get("interval", 5)
    deadline = time.time() + dc.get("expires_in", 900)
    while time.time() < deadline:
        time.sleep(interval)
        status, j = post_form(
            f"{base}/token",
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": CLIENT_ID,
                "device_code": dc["device_code"],
            },
        )
        err = j.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        return status, j
    return 408, {"error": "timeout", "error_description": "device code expired"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scopes", default=DEFAULT_SCOPES)
    ap.add_argument(
        "--messages",
        action="store_true",
        help="also read one 1:1 chat's messages (what the app does)",
    )
    ap.add_argument(
        "--refresh",
        action="store_true",
        help="use the app's stored refresh token instead of device code",
    )
    args = ap.parse_args()

    print(f"client={CLIENT_ID} tenant={TENANT}")
    print(f"requesting: {args.scopes}")
    status, tok = (
        token_via_refresh(args.scopes)
        if args.refresh
        else token_via_device_code(args.scopes)
    )
    if "access_token" not in tok:
        print(f"TOKEN FAIL http={status} error={tok.get('error')}")
        print(f"  {tok.get('error_description', '')[:600]}")
        sys.exit(2)

    at = tok["access_token"]
    print(f"TOKEN OK  scp = {decode_scp(at)}")
    print(f"  granted scope (token response) = {tok.get('scope', '')}")

    if args.messages:
        # Exercise exactly what TeamsChatService calls: the expanded chat list
        # and one 1:1 chat's messages page.
        code, chats = get_json(f"{GRAPH}/me/chats?$expand=members&$top=50", at)
        vals = chats.get("value", [])
        one = [c for c in vals if c.get("chatType") == "oneOnOne"]
        print(
            f"  {code} /me/chats?$expand=members: {len(vals)} chats, {len(one)} oneOnOne, nextLink={'@odata.nextLink' in chats}"
        )
        if one:
            print(f"    member keys: {sorted(one[0]['members'][0].keys())}")
            code, msgs = get_json(f"{GRAPH}/chats/{one[0]['id']}/messages?$top=20", at)
            m = msgs.get("value", [])
            print(
                f"  {code} /chats/{{id}}/messages: {len(m)} msgs, types={sorted({x.get('messageType') for x in m})}, "
                f"bodies={sorted({x.get('body', {}).get('contentType') for x in m})}"
            )
        return

    probes = [
        ("GET /me/chats?$top=3", f"{GRAPH}/me/chats?$top=3"),
        (
            "GET /me/messages?$top=1",
            f"{GRAPH}/me/messages?$top=1&$select=subject,from,receivedDateTime",
        ),
        ("GET /me/presence", f"{GRAPH}/me/presence"),
    ]
    for label, url in probes:
        code, body = get_json(url, at)
        if code == 200:
            n = len(body.get("value", [])) if "value" in body else "-"
            extra = (
                f" items={n}"
                if n != "-"
                else f" availability={body.get('availability')}"
            )
            print(f"  ok   {code} {label}{extra}")
        else:
            err = body.get("error", {})
            msg = err.get("message") if isinstance(err, dict) else body.get("raw", "")
            print(f"  FAIL {code} {label} — {str(msg)[:200]}")


if __name__ == "__main__":
    main()
