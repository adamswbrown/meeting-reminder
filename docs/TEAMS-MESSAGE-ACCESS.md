# Teams chat context for the pre-call brief

Decision record + how the feature works. Written 2026-09-14.

## Goal

Show recent 1:1 Microsoft Teams chat messages with a meeting's attendees inside
the pre-call brief panel, next to the Notion-sourced brief, so the "what did we
last talk about" context is on screen before the call.

## Constraints

- No admin consent is obtainable on the `altra.cloud` tenant.
- The app already signs in to Microsoft Graph with the device-code flow via the
  first-party **Microsoft Graph Command Line Tools** public client
  (`14d82eec-204b-4c2f-b7e8-296a70dab67e`), refresh token in Keychain as
  `msGraphRefreshToken` (`GraphMailService`).
- Avoid the metered, app-only Teams export API
  (`/users/{id}/chats/getAllMessages`). Only per-chat delegated reads.

## Probe results (2026-09-14, `scripts/graph-scope-probe.py`)

| Test | Result |
|------|--------|
| Refresh grant with the stored token, existing scope (`Mail.Send`) | 200. `scp` = `Application.ReadWrite.All Chat.ReadWrite Mail.Send openid profile User.Read email` |
| `GET /me/chats?$top=3` with that token | **200**, 3 chats |
| `GET /me/messages?$top=1` | 403 (no `Mail.Read`) |
| `GET /me/presence` | 403 (no `Presence.Read`) |
| Refresh grant requesting `Chat.Read Mail.Read` | `invalid_grant` / AADSTS65001, `suberror: consent_required` |
| Refresh grant requesting `Chat.Read` only | AADSTS65001 — Entra evaluates consent per **exact** permission; `Chat.ReadWrite` consent does not satisfy `Chat.Read` |
| Device-code sign-in requesting `Chat.Read Mail.Read` | **"Need admin approval"** page |
| Device-code sign-in requesting `Chat.Read` only | **"Need admin approval"** page |
| `GET /me/chats?$expand=members&$top=50` + `GET /chats/{id}/messages?$top=20` (refresh scope `Mail.Send Chat.ReadWrite`) | 200 / 200 |

Reading: the tenant's user-consent policy blocks *any new* delegated grant on
this client, regardless of what the Microsoft docs say about
`AdminConsentRequired: No`. But an earlier `mgc` CLI login already consented
`Chat.ReadWrite` (and `Application.ReadWrite.All`, `User.Read`) for this user,
and the refresh token still carries that grant. So Teams chat reading works
today with zero new consent; `Mail.Read` is not available.

## Decision

Build on Graph (path 2A) using the already-consented **`Chat.ReadWrite`** scope
(`TeamsChatSupport.chatScope`). Only read endpoints are called. The local Teams
cache fallback (2B) was not needed and was not built.

Why not `Chat.Read`: it is the minimal scope on paper, but requesting it either
breaks the refresh (65001) or, on reconnect, lands on the admin-approval page.
`Chat.ReadWrite` is the one the tenant has actually granted.

## How auth is wired

`GraphMailService` stays the single token owner:

- `fullScope` = `Mail.Send` + `Chat.ReadWrite` + `offline_access openid profile`;
  `baseScope` = mail only.
- **Refresh** tries `fullScope`; on `invalid_grant` with
  `suberror == consent_required` (or `AADSTS65001` in the description) it retries
  with `baseScope`. Only a *non-consent* `invalid_grant` deletes the refresh
  token and raises `needsReauth`. Previously every `invalid_grant` wiped the
  token — adding a scope would have logged the user out of booking email.
- **Connect** (device code) requests `fullScope`, so a fresh sign-in on a tenant
  that allows it consents both at once. On altra.cloud this shows "Need admin
  approval" for the chat part; the user can "Return to the application without
  granting consent" and mail still works.
- The returned access token's `scp` claim is decoded (unverified, gating only)
  into `grantedScopes` (published, persisted as `msGraphGrantedScopes`).
  `canReadChats` is true for `Chat.Read*` in any form.
- `get(_:)` is a shared authenticated GET with `Retry-After` handling on 429
  and transient 5xx (3 attempts). `TeamsChatService` uses it for everything.

## `TeamsChatService`

- **Directory**: `GET /me/chats?$expand=members&$top=50`, paged via
  `@odata.nextLink` (max 10 pages). Built into `email → [TeamsChatRef]` by
  `TeamsChatSupport.buildDirectory`, self excluded, 1:1 chats first. Persisted
  in UserDefaults `teamsChatDirectory`; rebuilt when older than 24 h, or via
  Settings → "Refresh chat directory". Warmed at launch when the feature is on.
- **Context**: for each attendee email on the event (new
  `MeetingEvent.attendeeEmails`, parallel to `attendees`), take the 1:1 chat and
  `GET /chats/{id}/messages?$top=20`. System events, deleted and empty messages
  are dropped, HTML bodies reduced to text (`stripHTML`), then filtered to the
  last 14 days and the last 10 messages. Group chats are ignored on purpose.
- 150 ms pacing between chats; Graph's per-app throttle is handled by `get`.
- Everything degrades to an empty result: toggle off, not connected, scope
  missing, 403, network error. `lastError` is surfaced only in Settings.

## UI

- Settings → Integrations → Availability → **Teams chat context**: toggle
  (`teamsChatContextEnabled`), status line (scope granted / directory age),
  refresh button, last error. The "Exchange sending" copy notes that reconnect
  now also asks for chat permission.
- Brief panel: a "Recent Teams chat" block per attendee under the Notion
  markdown, and also in the "No brief found" state. Loaded independently of the
  Notion fetch so neither blocks the other.

## Not done / future

- `Mail.Read` (recent email with the attendee) is blocked by the same consent
  policy. If an admin ever grants it, `GraphMailService.fullScope` is the only
  place to add it and `grantedScopes` will light it up.
- Group / meeting chats are indexed in the directory but not shown.
- Local Teams cache reader (2B) — not needed; see the original brief for the
  approach if Graph ever closes.
