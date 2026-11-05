#!/usr/bin/env bash
# Manages a session's usage plan (~/.claude/usage-aware/plans/<session_id>.json).
#   usage-plan context <sid>   current measurements + current plan (for writing a plan)
#   usage-plan show <sid>      the plan, each rule marked active/inactive now
#   usage-plan set <sid>       validate a plan from stdin and save it (replaces the old one)
#   usage-plan clear <sid>     delete the plan
#   usage-plan check <sid>     validate the saved plan
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

cmd="${1:-}" sid="${2:-}"
usage() { echo "usage: usage-plan context|show|set|clear|check <session_id>"; exit 2; }
[[ $cmd =~ ^(context|show|set|clear|check)$ ]] || usage
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || { echo "usage-plan: missing or bad session id"; exit 2; }
ua_have_jq || { echo "usage-plan: jq not found"; exit 1; }
plan="$UA_PLANS/$sid.json" pstate="$UA_PLANS/$sid.state.json"
now="${UA_NOW:-$(date +%s)}"

vars() {
  [[ -f "$UA_STATE" ]] && jq -c --argjson now "$now" "$UA_JQ_DUR$UA_JQ_FACTS"' facts.vars' "$UA_STATE" 2>/dev/null || echo '{}'
}

# Readable plan; with $1 = vars JSON, marks each rule active/inactive.
render() {
  jq -r --argjson v "$1" "$UA_JQ_RULES"'
    if (plan_errors | length) > 0 then "Plan is invalid:\n" + (plan_errors | map("  - " + .) | join("\n"))
    else (if .source then "Asked for: \(.source)\n" else "" end)
      + ([.rules | to_entries[] | .key as $i | .value
          | "  \(if .when | when_true($v) then "● active  " else "○ inactive" end)  [\(rid($i))] when \(.when)"
            + (if (.on // "prompt") == "subagent" then ", before subagents" else "" end)
            + (if .once then ", once" else "" end)
            + "\n      → \(.do)"] | join("\n"))
    end' "$2"
}

case $cmd in
  context)
    echo "Session: $sid"
    echo "Plan file: $plan"
    echo "Current measurements (unset ones are missing):"
    vars | jq -r 'to_entries | map("  \(.key) = \(.value | if . == (. | floor) then . else (. * 10 | round) / 10 end)") | join("\n") | if . == "" then "  (none yet)" else . end'
    if [[ -f $plan ]]; then echo "Current plan:"; render "$(vars)" "$plan"; else echo "Current plan: none"; fi
    ;;
  show)
    if [[ -f $plan ]]; then echo "Usage plan for this session:"; render "$(vars)" "$plan"
    else echo "No usage plan for this session. Set one with /usage-aware:usage-plan <what you want>."; fi
    ;;
  clear)
    if [[ -f $plan ]]; then rm -f "$plan" "$pstate"; echo "Usage plan cleared."; else echo "No usage plan to clear."; fi
    ;;
  check)
    [[ -f $plan ]] || { echo "No plan saved."; exit 1; }
    errs="$(jq -r "$UA_JQ_RULES"'plan_errors[]' "$plan" 2>/dev/null)" || errs="not valid JSON"
    [[ -z $errs ]] && { echo "OK: $(jq '.rules | length' "$plan") rule(s)."; exit 0; }
    printf 'Invalid:\n%s\n' "$errs"; exit 1
    ;;
  set)
    new="$(cat)"
    errs="$(jq -r "$UA_JQ_RULES"'plan_errors[]' <<<"$new" 2>/dev/null)" || errs="not valid JSON"
    if [[ -n $errs ]]; then printf 'Not saved. Fix these and run set again:\n%s\n' "$errs" | sed '2,$s/^/  - /'; exit 1; fi
    saved="$(jq --argjson now "$now" '{version: 1} + . + {created_at: $now}' <<<"$new")"
    mkdir -p "$UA_PLANS" && ua_write_atomic "$plan" "$saved" && rm -f "$pstate" || { echo "usage-plan: could not write $plan"; exit 1; }
    echo "Saved $(jq '.rules | length' <<<"$saved") rule(s):"
    render "$(vars)" "$plan"
    ;;
esac
exit 0
