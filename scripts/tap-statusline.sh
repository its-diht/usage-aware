#!/usr/bin/env bash
# Statusline command: saves rate_limits to state.json, then prints a statusline.
# Set USAGE_AWARE_NEXT to chain your previous statusline command.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

input="$(cat)"

if ua_have_jq; then
  # One jq pass: normalize resets_at (epoch number, numeric string, or ISO 8601) to epoch seconds.
  state="$(printf '%s' "$input" | jq -c --argjson now "$(date +%s)" '
    def toepoch:
      if type == "number" then floor
      elif type == "string" then
        if test("^[0-9]+$") then tonumber
        else try (
          sub("\\.[0-9]+"; "") as $s
          | if ($s | test("Z$")) then ($s | fromdateiso8601)
            else ($s | capture("^(?<d>.+)(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")) as $c
              | ($c.d + "Z" | fromdateiso8601)
                - (if $c.sg == "+" then 1 else -1 end) * (($c.h|tonumber)*3600 + ($c.m|tonumber)*60)
            end
        ) catch null end
      else null end;
    def win: if type == "object" then {used_percentage, resets_at: (.resets_at | toepoch)} else null end;
    select(type == "object" and (.rate_limits | type) == "object")
    | .rate_limits
    | select(.five_hour != null or .seven_day != null)
    | {updated_at: $now, five_hour: (.five_hour | win), seven_day: (.seven_day | win)}
  ' 2>/dev/null)"
  [[ -n "$state" ]] && ua_write_atomic "$UA_STATE" "$state"
fi

if [[ -n "${USAGE_AWARE_NEXT:-}" ]]; then
  printf '%s' "$input" | bash -c "$USAGE_AWARE_NEXT"
elif [[ -n "${state:-}" ]]; then
  printf '%s' "$state" | jq -r '
    [ (.five_hour | select(.) | "5h \(.used_percentage | round)%"),
      (.seven_day | select(.) | "7d \(.used_percentage | round)%") ] | join(" · ")'
else
  echo "5h -- · 7d --"
fi
exit 0
