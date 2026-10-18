#!/usr/bin/env bash
# One-time setup for the Meeting Reminder Managed Agents. Run on your Mac, in a terminal.
#
#   ./managed-agents/setup.sh
#
# Needs: ant (brew install anthropics/tap/ant), jq, and `ant auth login` done for the
# workspace whose API credit you want billed.
#
# It reads your existing Notion and Slack tokens from the macOS Keychain (the same entries the
# app uses) and stores them in an Anthropic vault. The sandbox only ever sees placeholders; the
# real values are swapped in on requests to the listed hosts. Nothing is written to disk.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v ant >/dev/null || { echo "ant not found: brew install anthropics/tap/ant"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found: brew install jq"; exit 1; }

FILES=(
  managed-agents/environment.yaml
  managed-agents/vault.yaml
  managed-agents/precall-brief/agent.md
  managed-agents/post-meeting-followup/agent.md
)

echo "== Workspace in use =="
ant auth status
echo
echo "== Plan (nothing is changed yet) =="
ant apply --dry-run -v "${FILES[@]}"
echo
read -r -p "Apply this plan? [y/N] " yn
[[ "$yn" == "y" || "$yn" == "Y" ]] || { echo "Stopped."; exit 0; }
ant apply "${FILES[@]}"

lock() { jq -r --arg k "./$1" '.resources[$k].id' claude-lock.json; }
VAULT_ID=$(lock managed-agents/vault.yaml)

keychain() { security find-generic-password -s com.meetingreminder.app -a "$1" -w; }

add_credential() { # $1 display name, $2 secret_name, $3 keychain account, $4 host
  local secret
  secret=$(keychain "$3") || { echo "No Keychain entry '$3' — skipping $1"; return; }
  export CMA_SECRET="$secret"
  jq -n --arg name "$1" --arg var "$2" --arg host "$4" -f /dev/stdin <<'JQ' | ant beta:vaults:credentials create --vault-id "$VAULT_ID" >/dev/null
{
  display_name: $name,
  auth: {
    type: "environment_variable",
    secret_name: $var,
    secret_value: (env.CMA_SECRET // error("CMA_SECRET is not set")),
    networking: {type: "limited", allowed_hosts: [$host]},
    injection_location: {header: true}
  }
}
JQ
  unset CMA_SECRET
  echo "Stored $1 (sent only to $4)"
}

echo
add_credential "Notion"       NOTION_API_TOKEN  notionAPIToken  api.notion.com
add_credential "Slack bot"    SLACK_BOT_TOKEN   slackBotToken    slack.com

echo
echo "== Paste these into Settings → Notion → Calendar Sync → Managed Agents =="
echo "Environment ID:                 $(lock managed-agents/environment.yaml)"
echo "Vault ID:                       $VAULT_ID"
echo "Pre-call briefing agent ID:     $(lock managed-agents/precall-brief/agent.md)"
echo "Follow-up agent ID:             $(lock managed-agents/post-meeting-followup/agent.md)"
echo
echo "Then add your Anthropic API key in the same section and switch the toggles on."
echo "Commit claude-lock.json so the IDs are recorded."
