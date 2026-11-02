#!/usr/bin/env bash
# Prints the usage line. The single formatter for both the hook and Claude.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

unknown() { echo "[usage] usage unknown ($1)"; exit 0; }
ua_have_jq || unknown "jq not found"
[[ -f "$UA_STATE" ]] || unknown "no data yet; it appears after Claude's first response in a session"

read -r conserve wrapup < <(ua_thresholds)

render() {
  jq -r --argjson now "$(date +%s)" --argjson c "$conserve" --argjson w "$wrapup" \
        --argjson stale "$UA_STALE_SECS" --argjson pace "$UA_PACE_JSON" \
        --argjson minel "$UA_PACE_MIN_ELAPSED" "$UA_JQ_DUR"'
  def names: ["NORMAL", "CONSERVE", "WRAP-UP"];
  def rules: ["work normally, but size plans against remaining usage",
              "small verifiable steps, no fan-outs/subagents, checkpoint often",
              "finish the current unit, write a handoff note (done / next / open issues), ask before starting new work"];
  def level($left): if $left >= $c then 0 elif $left >= $w then 1 else 2 end;

  # One window -> {txt, level (raw), adj (after pace/relax), why}
  def win($key; $label):
    ($pace[$key]) as $p
    | if type != "object" or (.used_percentage | type) != "number" then {txt: "\($label): n/a"}
      elif (.resets_at | type) == "number" and .resets_at <= $now then
        {txt: "\($label): 100% left (reset)", level: 0, adj: 0}
      else
        (.used_percentage) as $used
        | ([100 - $used, 0] | max) as $left
        | (if (.resets_at | type) == "number" then .resets_at - $now else null end) as $ttr
        | level($left) as $lv
        | (if $p != null and $ttr != null and $ttr <= $p.soon then "soon"
           elif $p != null and $ttr != null and $used > 0 and $left > 0 and ($p.len - $ttr) >= $minel * $p.len
                and ($left * ($p.len - $ttr) / $used) < $ttr then "pace"
           else null end) as $why
        | (if $why == "pace" then ($left * ($p.len - $ttr) / $used) else null end) as $runway
        | {level: $lv,
           adj: (if $why == "soon" then ([$lv - 1, 0] | max) elif $why == "pace" then ([$lv, 1] | max) else $lv end),
           why: $why,
           txt: ("\($label): \($left | floor)% left" + (if $left <= 0 then " (limit reached)" else "" end)
                 + (if $ttr != null then ", resets \($ttr | dur)" else "" end)
                 + (if $runway != null then ", pace: out in \($runway | dur)" else "" end))}
      end
    | . + {label: $label};

  . as $state
  | [ (.five_hour | win("five_hour"; "5h")), (.seven_day | win("seven_day"; "7d")) ]
  + (if (.spend_limit | type) == "object" then [.spend_limit | win("spend_limit"; "spend")] else [] end)
  | . as $ws
  | ($ws | map(select(.level != null))) as $known
  | if ($known | length) == 0 then "[usage] usage unknown (no rate_limits windows in data)"
    else ($known | map(.adj) | max) as $m
      | ($known | map(.level) | max) as $raw
      | (if $m > $raw then " (pace: \($known | map(select(.why == "pace" and .adj == $m) | .label) | join(", ")))"
         elif $m < $raw then " (\($known | map(select(.why == "soon" and .level == $raw) | .label) | join(", ")) resets soon)"
         else "" end) as $reason
      | "[usage] mode: \(names[$m])\($reason) · \($ws | map(.txt) | join(" · ")) · \($now - $state.updated_at | dur) old"
        + (if ($now - $state.updated_at) > $stale then " · stale" else "" end)
        + "\n        → \(rules[$m])"
    end
' "$UA_STATE" 2>/dev/null
}
out="$(render)"
[[ -n "$out" ]] || { sleep 0.05; out="$(render)"; }   # writer may be mid-write; retry once
[[ -n "$out" ]] || unknown "state file unreadable"
printf '%s\n' "$out"
exit 0
