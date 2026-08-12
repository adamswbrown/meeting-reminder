#!/bin/bash
# Activate the licence watcher as two local launchd jobs (run every 15m, digest 08:00).
# Run this AFTER filling in ~/.config/licence-watcher/env (see env.example).
#   ./install.sh          # install + load
#   ./install.sh uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA="$HOME/Library/LaunchAgents"
SECRETS_ENV="$HOME/.config/licence-watcher/env"
DOMAIN="gui/$(id -u)"
LABELS=(com.adambrown.licence-watcher.run com.adambrown.licence-watcher.digest)

if [[ "${1:-}" == "uninstall" ]]; then
  for label in "${LABELS[@]}"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$LA/$label.plist"
    echo "removed $label"
  done
  exit 0
fi

if [[ ! -f "$SECRETS_ENV" ]] || grep -q 'xoxb-\.\.\.' "$SECRETS_ENV" 2>/dev/null; then
  echo "ERROR: fill in $SECRETS_ENV first (copy from $SCRIPT_DIR/env.example)." >&2
  exit 1
fi

mkdir -p "$LA" "$HOME/.local/state/licence-watcher"
for label in "${LABELS[@]}"; do
  ln -sf "$SCRIPT_DIR/launchd/$label.plist" "$LA/$label.plist"
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$LA/$label.plist"
  echo "loaded $label"
done
echo "Done. Tail logs: tail -f ~/.local/state/licence-watcher/watcher.log"
