#!/usr/bin/env bash
# Prints the usage facts line and, given a session id, that session's active usage-plan rules.
# The single formatter for the hooks and for Claude's mid-turn checks.
#   usage-status [session_id] [--on prompt|subagent] [--rules-only]
# Synced copies use ua-lib.sh: pre-0.4 sessions still sync their own lib.sh.
ua_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [[ -f "$ua_here/ua-lib.sh" ]]; then source "$ua_here/ua-lib.sh"; else source "$ua_here/lib.sh"; fi

sid="" on="prompt" rules_only=0
while (($#)); do
  case $1 in
    --on) on="${2:-prompt}"; shift ;;
    --rules-only) rules_only=1 ;;
    *) [[ -z $sid ]] && sid="$1" ;;
  esac
  shift
done
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || sid=""
[[ $on == subagent ]] || on="prompt"

ua_have_jq || { echo "[usage] usage unknown (jq not found)"; exit 0; }
now="${UA_NOW:-$(date +%s)}"

# ---- facts ----
facts='{"vars":{},"line":""}'
if [[ -f "$UA_STATE" ]]; then
  for _ in 1 2; do   # the mod may be mid-write; retry once
    f="$(jq -c --argjson now "$now" "$UA_JQ_DUR$UA_JQ_FACTS"' facts' "$UA_STATE" 2>/dev/null)" && [[ -n $f ]] && { facts="$f"; break; }
    sleep 0.05
  done
  [[ $f == "$facts" ]] || facts='{"vars":{},"line":"[usage] usage unknown (state file unreadable)"}'
  [[ $(jq -r .known <<<"$facts") == 0 ]] && facts='{"vars":{},"line":"[usage] usage unknown (no rate_limits windows in data)"}'
else
  facts='{"vars":{},"line":"[usage] usage unknown (no data yet; it appears after Claude'"'"'s first response in a session)"}'
fi
line="$(jq -r .line <<<"$facts")"

# ---- plan ----
plan="$UA_PLANS/$sid.json" pstate="$UA_PLANS/$sid.state.json"
rules=""
if [[ -n $sid && -f $plan ]]; then
  out="$(jq -c --argjson facts "$facts" --arg on "$on" --slurpfile st <(cat "$pstate" 2>/dev/null || echo '{}') \
        "$UA_JQ_RULES"'
    ($st[0].fired // {}) as $fired | $facts.vars as $v
    | plan_errors as $err
    | if ($err | length) > 0 then {text: "Usage plan: invalid, ignored (\($err | first)). Fix it with /usage-aware:usage-plan.", fired: $fired}
      else [.rules | to_entries[] | .key as $i | .value | . + {id: rid($i), active: (.when | when_true($v))}] as $rs
        | [$rs[] | select((.on // "prompt") == $on)] as $mine
        | [$mine[] | select(.active and ((.once // false) and ($fired[.id] // false) | not))] as $show
        | ($fired + ([$mine[] | select(.once // false) | {(.id): .active}] | add // {})) as $nf
        # PreToolUse context only reaches Claude after the dispatch, so prompts also list active subagent rules.
        | (if $on == "prompt" then [$rs[] | select((.on // "prompt") == "subagent" and .active
              and ((.once // false) and ($fired[.id] // false) | not))] else [] end) as $sub
        | {fired: $nf,
           text: ([ (if ($show | length) > 0
                     then (if $on == "subagent" then "Usage plan (before dispatching a subagent):" else "Usage plan (active):" end)
                          + ([$show[] | "\n- [\(.id)] \(.do)"] | join(""))
                     else empty end),
                    (if ($sub | length) > 0
                     then "Usage plan (when you dispatch a subagent, do this before the call):"
                          + ([$sub[] | "\n- [\(.id)] \(.do)"] | join(""))
                     else empty end)
                  ] | join("\n")
                  | if . == "" and $on == "prompt" then "Usage plan: \($rs | length) rule(s), none active now." else . end)}
      end' "$plan" 2>/dev/null)"
  if [[ -z $out ]]; then
    rules="Usage plan: unreadable, ignored (not valid JSON). Fix it with /usage-aware:usage-plan."
  else
    rules="$(jq -r .text <<<"$out")"
    nf="$(jq -c '{fired: .fired}' <<<"$out")"
    [[ $nf == "$(jq -c '{fired: (.fired // {})}' "$pstate" 2>/dev/null || echo '{"fired":{}}')" ]] || ua_write_atomic "$pstate" "$nf"
  fi
fi

if ((rules_only)); then
  [[ -n $rules ]] && printf '%s\n' "$rules"
else
  printf '%s\n' "$line"
  [[ -n $rules ]] && printf '%s\n' "$rules"
fi
exit 0
