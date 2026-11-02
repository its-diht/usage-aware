#!/usr/bin/env bash
# One-time setup: sync scripts to the fixed path and print settings.json snippets.
# Never edits settings.json itself.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if ! ua_have_jq; then
  echo "usage-aware: jq is required but not found. Install it first (e.g. sudo apt install jq, sudo pacman -S jq, brew install jq), then re-run." >&2
  exit 1
fi

ua_sync "$(dirname "$here")" || { echo "usage-aware: could not write $UA_DIR" >&2; exit 1; }
echo "Synced scripts to $UA_DIR"

tap="$UA_DISPLAY_DIR/tap-statusline"
old=""
[[ -f "$settings" ]] && old="$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)"

if [[ "$old" == *usage-aware/tap-statusline* ]]; then
  echo
  echo "Your statusLine already uses usage-aware; no statusLine change needed."
  cmd=""
elif [[ -n "$old" ]]; then
  q="'${old//\'/\'\\\'\'}'"          # single-quote for the shell
  cmd="USAGE_AWARE_NEXT=$q $tap"
  echo
  echo "Found an existing statusLine; the snippet below keeps it via USAGE_AWARE_NEXT."
else
  cmd="$tap"
fi

echo
echo "Add this to $settings (merge with what's there):"
echo
jq -n --arg cmd "$cmd" --arg rule "Bash($UA_DISPLAY_DIR/usage-status *)" '
  (if $cmd != "" then {statusLine: {type: "command", command: $cmd}} else {} end)
  + {permissions: {allow: [$rule]}}'
echo
echo "The permission rule lets Claude run usage-status mid-turn without a prompt."
