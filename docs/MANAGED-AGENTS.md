# Managed Agents (cloud runs)

Two jobs can run in an Anthropic-hosted sandbox instead of on your Mac, billed to your
Anthropic API credit. Both are **opt-in and off by default**.

| Job | Trigger (still on the Mac) | What runs in the sandbox |
|---|---|---|
| **Intraday pre-call briefing** | `PreCallBriefTriggerService` sees a new/removed meeting | Your local briefing skill, sent as the prompt. Notion + Slack via `curl` |
| **Post-meeting follow-up** | `MeetingMonitor.onMeetingEnded` (audio silence / calendar end / "Done") | Reads the meeting's Notion notes page, appends a summary, action items and a draft email to it |

Code: `Services/ManagedAgentsClient.swift` (raw-HTTP client, no SDK), `Services/PostMeetingFollowUpService.swift`,
`Views/ManagedAgentsSettingsSection.swift`. Agent definitions: [`managed-agents/`](../managed-agents).

## What this does and doesn't change

- **Detection stays on the Mac.** The app still has to be running and awake to notice a new
  meeting or the end of a call. A closed or sleeping laptop gets no briefing from this feature.
  What moves to the cloud is the *work*: no dependency on the local `claude` CLI, Node, Full
  Disk Access or a 10-minute child process, and every run has a transcript in the Console.
- **Reminders are skipped in the cloud.** `remctl` is a macOS CLI; the sandbox can't run it.
  The preamble tells the skill to skip those steps, so cloud briefings post to Slack and Notion
  but don't sync action items to Apple Reminders.
- **The follow-up never sends anything.** It only appends to the Notion notes page.

## Setup (once)

1. `brew install anthropics/tap/ant jq`, then `ant auth login` for the workspace to bill.
2. Check `managed-agents/environment.yaml` → `allowed_hosts`. The third entry must be the host of
   your published Outlook ICS feed (it's in your local briefing skill).
3. Run `./managed-agents/setup.sh`. It shows the plan, creates the environment, vault and two
   agents, copies your Notion and Slack tokens from the Keychain into the vault, and prints four
   IDs. Commit `claude-lock.json`.
4. Settings → Notion → Calendar Sync → **Managed Agents (cloud)**: paste the IDs and your
   Anthropic API key (stored in the Keychain as `anthropicAPIKey`), then switch on the toggles.

The sandbox never holds the real tokens. It sees placeholders; they are swapped in on requests to
`api.notion.com` / `slack.com` only.

## Behaviour and safety

- **Spend caps.** Every session has a hard budget: $1.50 per briefing, $1.00 per follow-up
  (list price). At the cap the session pauses and the run is reported as failed.
- **Fallback.** If a briefing session can't be *started* (no network, bad key), the app falls back
  to the local `claude` CLI. A session that started and then failed is **not** re-run locally,
  because it may already have posted to Slack.
- **No blind approvals.** Tool permission policy is `auto`. A call the server can't clear is
  denied, not approved, because nobody is watching.
- **Untrusted text.** Invite titles/attendees and page content are framed as data in the prompts.
  Follow-up prompts omit the invite body entirely.
- **Privacy.** The briefing prompt is your local skill, which contains the private ICS feed URL. It
  is sent to Anthropic as the session's first message and is retained in the session history. It
  already passes through the API when the `claude` CLI runs it; this just adds a stored session.
  Don't send customer data you aren't allowed to put through the API.
- **Follow-up cost control.** Only meetings with a Notion notes page the app created or found are
  followed up; the agent skips pages with under ~200 characters of notes and pages that already have
  a "Follow-up draft" heading. Each meeting is processed once (`postMeetingFollowUpDoneIDs`).

## Settings (UserDefaults / Keychain)

| Key | Default | Description |
|---|---|---|
| Keychain `anthropicAPIKey` | — | Anthropic API key used to start sessions |
| `managedAgentsEnvironmentID` | "" | `env_…` from `setup.sh` |
| `managedAgentsVaultID` | "" | `vlt_…` from `setup.sh` |
| `managedAgentsPrecallAgentID` | "" | `agent_…` for the briefing runner |
| `managedAgentsFollowUpAgentID` | "" | `agent_…` for the follow-up writer |
| `managedAgentsPrecallEnabled` | false | Run intraday briefings on the Managed Agent |
| `postMeetingFollowUpEnabled` | false | Draft a follow-up when a meeting with notes ends |
| `postMeetingFollowUpDelaySeconds` | 90 | Pause after the meeting ends so late notes are saved |
| `postMeetingFollowUpDoneIDs` | [] | Event IDs already followed up (bounded) |

Logs: `~/Library/Logs/MeetingReminder/precall-brief-intraday.log`, `post-meeting-followup.log`.
Session transcripts: Console → Managed Agents → Sessions.

## Changing an agent

Edit its file under `managed-agents/` and re-run `ant apply managed-agents/<dir>/agent.md`. Each
change makes a new version; running sessions keep theirs. Don't edit agents in the Console — the
next `ant apply` will refuse to run.

## Not built yet

- **Cloud-side detection.** Making briefings work with the Mac closed needs a scheduled deployment
  that polls the Notion Calendar Events DB for new meetings.
- **Todoist actions.** Pushing the follow-up's action items to Todoist needs a Todoist MCP
  credential in the vault.
