#!/bin/bash
# Local launchd entrypoint for the EMEA licence watcher.
# Sources Salesforce client-creds (already on this Mac) + the local secrets file
# (Slack / Notion / Todoist / SMTP), then runs watcher.py with the given mode.
#
#   ./run-local.sh run       # one polling cycle (launchd .run plist, every 15m)
#   ./run-local.sh digest    # morning overnight summary + email (.digest plist, 08:00)
#   ./run-local.sh run --dry-run
#
# Secrets live OUTSIDE the repo: ~/.config/licence-watcher/env (see env.example).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_ENV="$HOME/Developer/Tools/salesforce-readonly-mcp-PROD/.env"
SECRETS_ENV="${LICENCE_SECRETS_ENV:-$HOME/.config/licence-watcher/env}"

# Salesforce client-creds (required).
if [[ -f "$SF_ENV" ]]; then
  set -a; . "$SF_ENV"; set +a
else
  echo "ERROR: Salesforce env not found at $SF_ENV" >&2
  exit 3
fi

# Slack / Notion / Todoist / SMTP (optional until filled in — see env.example).
if [[ -f "$SECRETS_ENV" ]]; then
  set -a; . "$SECRETS_ENV"; set +a
fi

exec /usr/bin/python3 "$SCRIPT_DIR/watcher.py" "$@"
