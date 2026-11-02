#!/usr/bin/env bash
# Prints the usage line. The single formatter for both the hook and Claude.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

unknown() { echo "[usage] usage unknown ($1)"; exit 0; }
ua_have_jq || unknown "jq not found"
[[ -f "$UA_STATE" ]] || unknown "no data yet; it appears after Claude's first response in a session"

read -r conserve wrapup < <(ua_thresholds)

out="$(jq -r --argjson now "$(date +%s)" --argjson c "$conserve" --argjson w "$wrapup" \
          --argjson stale "$UA_STALE_SECS" "$UA_JQ_DUR"'
  def win($label):
    if type != "object" or (.used_percentage | type) != "number" then {txt: "\($label): n/a", left: null}
    elif (.resets_at | type) == "number" and .resets_at <= $now then {txt: "\($label): 100% left (reset)", left: 100}
    else (100 - .used_percentage) as $l
      | {left: $l, txt: ("\($label): \($l | if . < 0 then 0 else floor end)% left"
                         + (if (.resets_at | type) == "number" then ", resets \(.resets_at - $now | dur)" else "" end))}
    end;
  (.five_hour | win("5h")) as $a | (.seven_day | win("7d")) as $b
  | ([$a.left, $b.left] | map(select(. != null))) as $ls
  | if ($ls | length) == 0 then "[usage] usage unknown (no rate_limits windows in data)"
    else ($ls | min) as $left
      | (if $left >= $c then ["NORMAL", "work normally, but size plans against remaining usage"]
         elif $left >= $w then ["CONSERVE", "small verifiable steps, no fan-outs/subagents, checkpoint often"]
         else ["WRAP-UP", "finish the current unit, write a handoff note (done / next / open issues), ask before starting new work"] end) as $m
      | ($now - .updated_at) as $age
      | "[usage] mode: \($m[0]) · \($a.txt) · \($b.txt) · \($age | dur) old"
        + (if $age > $stale then " · stale" else "" end)
        + "\n        → \($m[1])"
    end
' "$UA_STATE" 2>/dev/null)"

[[ -n "$out" ]] || unknown "state file unreadable"
printf '%s\n' "$out"
exit 0
