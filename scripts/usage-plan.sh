#!/usr/bin/env bash
# Manages a session's usage plan (~/.claude/usage-aware/plans/<session_id>.json).
#   usage-plan context <sid>   current measurements + current plan (for writing a plan)
#   usage-plan show <sid>      the plan, each rule marked active/inactive now
#   usage-plan set <sid>       validate plans/<sid>.draft.json (or stdin) and save it as the plan
#   usage-plan clear <sid>     delete the plan
#   usage-plan check <sid>     validate the saved plan
# Building a plan without JSON in the shell (what /usage-aware:usage-plan uses):
#   usage-plan begin <sid> [--add] <source text...>          start a draft (--add: keep current rules)
#   usage-plan rule <sid> <id> <when> <do> [--subagent] [--once]   add/replace a rule in the draft
#   usage-plan commit <sid>                                   validate the draft and save it (= set)
# Synced copies use ua-lib.sh: pre-0.4 sessions still sync their own lib.sh.
ua_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [[ -f "$ua_here/ua-lib.sh" ]]; then source "$ua_here/ua-lib.sh"; else source "$ua_here/lib.sh"; fi

cmd="${1:-}" sid="${2:-}"
usage() { echo "usage: usage-plan context|show|set|clear|check|begin|rule|commit <session_id> ..."; exit 2; }
[[ $cmd =~ ^(context|show|set|clear|check|begin|rule|commit)$ ]] || usage
[[ $cmd == commit ]] && cmd=set
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || { echo "usage-plan: missing or bad session id"; exit 2; }
ua_have_jq || { echo "usage-plan: jq not found"; exit 1; }
plan="$UA_PLANS/$sid.json" pstate="$UA_PLANS/$sid.state.json"
now="${UA_NOW:-$(date +%s)}"

vars() {
  [[ -f "$UA_STATE" ]] && ua_facts "$sid" facts.vars 2>/dev/null || echo '{}'
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

draft="$UA_PLANS/$sid.draft.json"
case $cmd in
  begin)
    shift 2; keep=0; [[ ${1:-} == --add ]] && { keep=1; shift; }
    rules='[]'; [[ $keep == 1 && -f $plan ]] && rules="$(jq -c '.rules // []' "$plan" 2>/dev/null || echo '[]')"
    mkdir -p "$UA_PLANS" && ua_write_atomic "$draft" "$(jq -n --arg s "$*" --argjson r "$rules" '{source: $s, rules: $r}')" \
      || { echo "usage-plan: could not write draft"; exit 1; }
    echo "Draft started with $(jq length <<<"$rules") rule(s). Add rules with: usage-plan rule $sid <id> <when> <do> [--subagent] [--once]"
    ;;
  rule)
    shift 2
    (( $# >= 3 )) || { echo "usage: usage-plan rule <sid> <id> <when> <do> [--subagent] [--once]"; exit 2; }
    id="$1" when="$2" do_="$3"; shift 3; on=prompt once=false
    for f in "$@"; do case $f in --subagent) on=subagent;; --once) once=true;; *) echo "usage-plan: unknown option $f"; exit 2;; esac; done
    [[ -f $draft ]] || { mkdir -p "$UA_PLANS" && ua_write_atomic "$draft" '{"rules":[]}'; }
    r="$(jq -n --arg id "$id" --arg w "$when" --arg d "$do_" --arg on "$on" --argjson once "$once" \
      '{id: $id, when: $w, do: $d} + (if $on == "subagent" then {on: $on} else {} end) + (if $once then {once: true} else {} end)')"
    new="$(jq --argjson r "$r" '.rules = ([.rules[] | select(.id != $r.id)] + [$r])' "$draft" 2>/dev/null)" \
      || { echo "usage-plan: draft unreadable; run begin again"; exit 1; }
    errs="$(jq -r --argjson r "$r" "$UA_JQ_RULES"'{rules: [$r]} | plan_errors[]' <<<'null' 2>/dev/null)"
    [[ -n $errs ]] && { printf 'Rule not added:\n%s\n' "$errs" | sed '2,$s/^/  - /;s/rule 1: //'; exit 1; }
    ua_write_atomic "$draft" "$new"
    echo "Draft has $(jq '.rules | length' <<<"$new") rule(s). Run usage-plan commit $sid when done."
    ;;
  context)
    echo "Session: $sid"
    echo "Plan file: $plan"
    echo "Current measurements (unset ones are missing):"
    vars | jq -r 'def rnd: . + 0.5 | floor; to_entries | map("  \(.key) = \(.value | if . == (. | floor) then . else (. * 10 | rnd) / 10 end)") | join("\n") | if . == "" then "  (none yet)" else . end'
    if [[ -f $plan ]]; then echo "Current plan:"; render "$(vars)" "$plan"; else echo "Current plan: none"; fi
    ;;
  show)
    if [[ -f $plan ]]; then echo "Usage plan for this session:"; render "$(vars)" "$plan"
    else echo "No usage plan for this session. Set one with /usage-aware:usage-plan create."; fi
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
    if [[ -f $draft ]]; then new="$(cat "$draft")"; else new="$(cat)"; fi
    errs="$(jq -r "$UA_JQ_RULES"'plan_errors[]' <<<"$new" 2>/dev/null)" || errs="not valid JSON"
    [[ -n "${new//[[:space:]]/}" ]] || errs="no plan given (write it to $draft first)"
    if [[ -n $errs ]]; then printf 'Not saved. Fix these and run set again:\n%s\n' "$errs" | sed '2,$s/^/  - /'; exit 1; fi
    saved="$(jq --argjson now "$now" '{version: 1} + . + {created_at: $now}' <<<"$new")"
    mkdir -p "$UA_PLANS" && ua_write_atomic "$plan" "$saved" && rm -f "$pstate" "$draft" || { echo "usage-plan: could not write $plan"; exit 1; }
    echo "Saved $(jq '.rules | length' <<<"$saved") rule(s):"
    render "$(vars)" "$plan"
    ;;
esac
exit 0
