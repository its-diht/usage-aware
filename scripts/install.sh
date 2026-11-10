#!/usr/bin/env bash
# Optional setup: sync scripts to the fixed path and print the permission rule to add.
# Never edits settings.json itself.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
settings="${CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"

if ! ua_have_jq; then
  echo "usage-aware: jq is required but not found. Install it first (e.g. sudo apt install jq, sudo pacman -S jq, brew install jq), then re-run." >&2
  exit 1
fi

ua_sync "$(dirname "$here")" || { echo "usage-aware: could not write $UA_BIN_DIR" >&2; exit 1; }
echo "Synced scripts to $UA_BIN_DIR"
echo "This account's usage data lives in $UA_DIR"

rule="Bash($UA_DISPLAY_DIR/usage-status *)"
old_sl="" have_rule=""
if [[ -f "$settings" ]]; then
  old_sl="$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)"
  have_rule="$(jq -r --arg r "$rule" '(.permissions.allow // []) | index($r) // empty' "$settings" 2>/dev/null)"
fi

if [[ "$old_sl" == *usage-aware/tap-statusline* ]]; then
  echo
  echo "Your statusLine still points at usage-aware's old tap-statusline, which no longer exists."
  echo "Please remove it from $settings (or restore the command saved in USAGE_AWARE_NEXT)."
fi

echo
if [[ -n "$have_rule" ]]; then
  echo "The permission rule is already in $settings; nothing to add."
else
  echo "Add this to $settings (merge with what's there):"
  echo
  jq -n --arg rule "$rule" '{permissions: {allow: [$rule]}}'
  echo
  echo "It lets Claude run usage-status mid-turn without a permission prompt."
fi
