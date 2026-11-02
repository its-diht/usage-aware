#!/usr/bin/env bash
# UserPromptSubmit hook: injects the current usage line into Claude's context.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
cat >/dev/null   # discard hook input
ua_have_jq || exit 0   # SessionStart already warned the user
bash "$here/usage-status.sh" | jq -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: rtrimstr("\n")}}'
exit 0
