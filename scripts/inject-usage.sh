#!/usr/bin/env bash
# UserPromptSubmit hook: injects the usage line and this session's active plan rules.
# Also warns the user once per session when the bundled mod isn't feeding data.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
input="$(cat)"
ua_have_jq || exit 0   # SessionStart already warned the user

warn=""
sid="$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)"
hb="$(jq -r '.heartbeat // 0' "$UA_HEARTBEAT" 2>/dev/null || echo 0)"
if (( $(date +%s) - ${hb:-0} > UA_HEARTBEAT_MAX )) && [[ "$(cat "$UA_DIR/warned" 2>/dev/null)" != "$sid" ]]; then
  warn="usage-aware: its mod isn't running, so usage data won't update. Check that the plugin is enabled in /plugin and that plugin mods can load. (Shown once per session.)"
  ua_write_atomic "$UA_DIR/warned" "$sid"
fi

bash "$here/usage-status.sh" "$sid" | jq -Rsc --arg warn "$warn" '
  {hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: rtrimstr("\n")}}
  + (if $warn != "" then {systemMessage: $warn} else {} end)'
exit 0
