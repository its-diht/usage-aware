#!/usr/bin/env bash
# PreToolUse hook (Agent/Task): hands Claude the plan's "before dispatching a subagent" rules
# that are active now, with the usage line. Silent when there are none. Never blocks the tool.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
input="$(cat)"
ua_have_jq || exit 0
sid="$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)"
rules="$(bash "$here/usage-status.sh" "$sid" --on subagent --rules-only)"
[[ -n $rules ]] || exit 0
printf '%s\n%s\n' "$rules" "$(bash "$here/usage-status.sh" | head -1)" | jq -Rsc \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: rtrimstr("\n")}}'
exit 0
