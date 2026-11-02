#!/usr/bin/env bash
# Testing step 1: tap-statusline
source "$(dirname "$0")/helpers.sh"
TAP="$SCRIPTS/tap-statusline.sh"
now=$(date +%s)

echo "tap-statusline: epoch resets_at"
setup_dir
in=$(jq -nc --argjson r "$((now+3600))" --argjson s "$((now+86400))" \
  '{model:{display_name:"X"},rate_limits:{five_hour:{used_percentage:42,resets_at:$r},seven_day:{used_percentage:15,resets_at:$s}}}')
out=$(printf '%s' "$in" | bash "$TAP"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "default output" "5h 42% · 7d 15%" "$out"
st="$USAGE_AWARE_DIR/state.json"
assert_true "state.json written" test -f "$st"
assert_eq "five_hour used" 42 "$(jq -r .five_hour.used_percentage "$st")"
assert_eq "five_hour resets epoch" "$((now+3600))" "$(jq -r .five_hour.resets_at "$st")"
assert_eq "seven_day used" 15 "$(jq -r .seven_day.used_percentage "$st")"
upd=$(jq -r .updated_at "$st")
assert_true "updated_at is recent epoch" test "$upd" -ge "$now"
assert_eq "no temp files left" 1 "$(ls -A "$USAGE_AWARE_DIR" | wc -l)"

echo "tap-statusline: ISO resets_at"
setup_dir
in='{"rate_limits":{"five_hour":{"used_percentage":10.5,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"used_percentage":3,"resets_at":"2030-01-02T12:00:00.123+00:00"}}}'
out=$(printf '%s' "$in" | bash "$TAP")
st="$USAGE_AWARE_DIR/state.json"
assert_eq "ISO Z -> epoch" "$(date -d 2030-01-01T00:00:00Z +%s)" "$(jq -r .five_hour.resets_at "$st")"
assert_eq "ISO offset+fraction -> epoch" "$(date -d 2030-01-02T12:00:00Z +%s)" "$(jq -r .seven_day.resets_at "$st")"
assert_eq "fractional pct rounded in output" "5h 11% · 7d 3%" "$out"

echo "tap-statusline: only one window present"
setup_dir
out=$(printf '%s' '{"rate_limits":{"seven_day":{"used_percentage":20,"resets_at":2000000000}}}' | bash "$TAP")
assert_eq "missing five_hour is null" null "$(jq -r .five_hour "$USAGE_AWARE_DIR/state.json")"
assert_eq "output shows only 7d" "7d 20%" "$out"

echo "tap-statusline: no rate_limits"
setup_dir
printf '%s' "$in" | bash "$TAP" >/dev/null
before=$(cat "$USAGE_AWARE_DIR/state.json")
out=$(printf '%s' '{"model":{"display_name":"X"}}' | bash "$TAP"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "state untouched" "$before" "$(cat "$USAGE_AWARE_DIR/state.json")"
assert_eq "placeholder output" "5h -- · 7d --" "$out"
setup_dir
printf '%s' '{}' | bash "$TAP" >/dev/null
assert_true "no state file created" test ! -e "$USAGE_AWARE_DIR/state.json"

echo "tap-statusline: USAGE_AWARE_NEXT chaining"
setup_dir
in=$(jq -nc --argjson r "$((now+60))" '{rate_limits:{five_hour:{used_percentage:1,resets_at:$r}}}')
out=$(printf '%s' "$in" | USAGE_AWARE_NEXT='jq -r ".rate_limits.five_hour.used_percentage | \"old:\(.)\""' bash "$TAP"); rc=$?
assert_eq "chained output" "old:1" "$out"
assert_true "state still written when chaining" test -f "$USAGE_AWARE_DIR/state.json"
out=$(printf '%s' "$in" | USAGE_AWARE_NEXT='exit 3' bash "$TAP"); rc=$?
assert_eq "exit 0 even if next fails" 0 "$rc"

echo "tap-statusline: garbage input"
setup_dir
out=$(printf 'not json' | bash "$TAP" 2>&1); rc=$?
assert_eq "exit 0 on bad json" 0 "$rc"
assert_true "no state on bad json" test ! -e "$USAGE_AWARE_DIR/state.json"

finish
