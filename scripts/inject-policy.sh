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
# The mod can't delete files: prune per-session cost files a week old (it ignores those anyway).
find "$UA_DIR/sessions" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null
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

Token estimate (your main sizing unit): each window may show "(~N tok)", an estimate of the tokens left in it, learned from how far the % moves per dollar of usage, then converted at the tokens per dollar seen so far. It's plan-independent: 10% on one plan can be far more work than 10% on another, so size work by tokens, and use the % and mode as the coarse gate. "≈N steps at Xk context" divides the tighter window's tokens by your current context size. Each model call (a step: one tool use and its reply) costs about one full context, so this shrinks as context grows and grows after /compact. A subagent costs its own context per step, plus its result added to yours. It's an estimate: it counts every Claude Code session on this machine, but can run low when the account is also used elsewhere (claude.ai, other devices), and it's missing until calibrated (the first point or so of movement). With no estimate, size by % alone.

Rules:
- Account for usage in every plan. Before multi-step work, estimate its size in steps/tokens against the tokens left in the tighter window (the % if there's no estimate), and leave headroom.
- Say so when you defer or split work because of usage.
- Weigh the 7d window as pacing across days, not just the 5h window.
- During long autonomous work, run \`$cmd\` (exactly that command, with the literal path) before each major step and before spawning subagents. If the mode got stricter, adjust the plan.
- "usage unknown" means no data yet (it appears after your first response) or an API-key account; fall back to normal judgment.

Current: $(bash "$here/usage-status.sh")
POLICY
)"

jq -nc --arg ctx "$policy" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
