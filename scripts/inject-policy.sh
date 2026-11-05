#!/usr/bin/env bash
# SessionStart hook: dependency check, sync fixed-path script copies, carry a plan across /clear,
# and inject the usage-facts glossary.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$here/lib.sh"
input="$(cat)"

if ! ua_have_jq; then
  printf '%s\n' '{"systemMessage": "usage-aware: jq not found, plugin inactive. Install jq (e.g. sudo apt install jq)."}'
  exit 0
fi

ua_sync "${CLAUDE_PLUGIN_ROOT:-$(dirname "$here")}"
# The mod can't delete files: prune week-old session cost files and two-week-old plans.
find "$UA_DIR/sessions" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null
find "$UA_PLANS" -maxdepth 1 -name '*.json' -mtime +14 -delete 2>/dev/null

sid="$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)"
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || sid=""
src="$(jq -r '.source // ""' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)"

# /clear starts a new session id; SessionEnd left a pointer to the old one (see carry-plan.sh).
carried=""
if [[ $src == clear && -n $sid ]]; then
  carry="$UA_PLANS/.carry-$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
  if [[ -f $carry ]] && (( $(date +%s) - $(stat -c %Y "$carry") <= 60 )); then
    old="$(cat "$carry")"
    if [[ $old =~ ^[A-Za-z0-9_-]{1,128}$ && -f "$UA_PLANS/$old.json" && ! -f "$UA_PLANS/$sid.json" ]]; then
      cp "$UA_PLANS/$old.json" "$UA_PLANS/$sid.json" && carried=" (carried over from before /clear)"
    fi
    rm -f "$carry"
  fi
fi

cmd="$UA_DISPLAY_DIR/usage-status $sid"
if [[ -n $sid && -f "$UA_PLANS/$sid.json" ]]; then
  plan_note="This session has a usage plan$carried. Its active rules are listed under the usage line; follow them, they are the user's instructions. Rules marked \"before dispatching a subagent\" arrive right before you spawn one."
else
  plan_note="No usage plan is set for this session. Use your own judgment, and size work against the token/steps estimates. The user can set one with /usage-aware:usage-plan <what they want>."
fi

policy="$(cat <<POLICY
# usage-aware: usage facts

The user's Claude plan has a 5-hour and a 7-day usage window (plus a \`spend\` window on spend-limit accounts). A usage line of plain measurements is added to every prompt. It carries no advice: what to do about usage comes from the user's usage plan, or your own judgment if there is none.

How to read it:
- **N% left, resets X:** what's left in each window, and when it refills.
- **(~N tok):** estimated tokens left in that window. It's learned from how far the % moves per dollar of usage, then converted at the tokens per dollar seen so far. It's plan-independent, so size work in tokens: 10% on one plan can be far more work than on another. It's an estimate: it counts every Claude Code session on this machine, can run low when the account is also used elsewhere, and is missing until calibrated.
- **at avg rate out in X:** at the window's average rate so far, it runs out before it resets.
- **≈N steps at Xk context:** tokens left in the tighter window divided by your current context. Each model call (one tool use and its reply) costs about one full context, so this shrinks as context grows and recovers after /compact. A subagent costs its own context per step, plus its result added to yours.
- **N old / stale:** the age of the reading. "usage unknown" means no data yet (it appears after your first response) or an API-key account.

$plan_note

During long autonomous work, run \`$cmd\` (exactly that command, with the literal path) before major steps and before spawning subagents, to get fresh numbers and any rules that have newly become active.

Current:
$(bash "$here/usage-status.sh" "$sid")
POLICY
)"

jq -nc --arg ctx "$policy" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
