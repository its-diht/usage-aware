#!/usr/bin/env bash
# SessionStart hook: dependency check, sync fixed-path script copies, inject the budgeting policy.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
cat >/dev/null   # discard hook input

if ! ua_have_jq; then
  printf '%s\n' '{"systemMessage": "usage-aware: jq not found, plugin inactive. Install jq (e.g. sudo apt install jq)."}'
  exit 0
fi

ua_sync "${CLAUDE_PLUGIN_ROOT:-$(dirname "$here")}"
read -r c w < <(ua_thresholds)
cmd="$UA_DISPLAY_DIR/usage-status"

policy="$(cat <<POLICY
# usage-aware: plan-usage budgeting policy

The user's Claude plan has a 5-hour and a 7-day usage window. A usage line like the one below is added to every prompt. The mode comes from whichever window has less left.

| Mode | When | Rule |
|---|---|---|
| NORMAL | ≥ ${c}% left | Work normally, but still size plans against remaining usage. |
| CONSERVE | ${w}–${c}% left | Small verifiable steps. Avoid fan-outs and subagents. Checkpoint often. |
| WRAP-UP | < ${w}% left | Finish the current unit. Write a handoff note (done / next / open issues). Ask before starting new work. |

Two adjustments, shown in parentheses after the mode:
- **(pace: 5h/7d):** at the average rate so far, that window is on pace to run out before it resets ("pace: out in …"), so the mode is at least CONSERVE.
- **(… resets soon):** a window resetting within 15 min (5h) or 12 h (7d) counts one step less strict, since it's about to refill.
A \`spend\` window (spend-limit accounts) counts like the others.

Rules:
- Account for usage in every plan. Before multi-step work, estimate its size against what's left.
- Say so when you defer or split work because of usage.
- Weigh the 7d window as pacing across days, not just the 5h window.
- During long autonomous work, run \`$cmd\` (exactly that command, with the literal path) before each major step and before spawning subagents. If the mode got stricter, adjust the plan.
- "usage unknown" means no data yet (it appears after your first response) or an API-key account; fall back to normal judgment.

Current: $(bash "$here/usage-status.sh")
POLICY
)"

jq -nc --arg ctx "$policy" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
