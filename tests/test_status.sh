#!/usr/bin/env bash
# usage-status: the facts line (no modes) and the measurement variables.
source "$(dirname "$0")/helpers.sh"
US="$SCRIPTS/usage-status.sh"
UP="$SCRIPTS/usage-plan.sh"
now=$(date +%s)
export UA_NOW=$now   # pinned clock: exact-line checks

# state <age_secs> <5h_used|null> <5h_reset_in> <7d_used|null> <7d_reset_in> [spend_used spend_reset_in]
state() {
  local w5=null w7=null sp=null
  [[ $2 != null ]] && w5="{\"used_percentage\":$2,\"resets_at\":$((now+$3))}"
  [[ $4 != null ]] && w7="{\"used_percentage\":$4,\"resets_at\":$((now+$5))}"
  [[ -n ${6:-} ]] && sp="{\"used_percentage\":$6,\"resets_at\":$((now+$7))}"
  printf '{"updated_at":%d,"five_hour":%s,"seven_day":%s,"spend_limit":%s}\n' "$((now-$1))" "$w5" "$w7" "$sp" >"$USAGE_AWARE_DIR/state.json"
}
# var <name>: a measurement as usage-plan context prints it ("" when unset)
var() { bash "$UP" context S0 | sed -n "s/^  $1 = //p"; }

echo "usage-status: missing state"
setup_dir
out=$(bash "$US"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "says unknown" "usage unknown" "$out"

echo "usage-status: corrupt state"
setup_dir; echo 'garbage{' >"$USAGE_AWARE_DIR/state.json"
out=$(bash "$US"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "corrupt -> unknown" "usage unknown" "$out"

echo "usage-status: facts line"
setup_dir; state 40 66 6600 29 356400
out=$(bash "$US")
# 5h: 66% used over 3h10m elapsed -> 34% lasts 1h37m at that rate, before the 1h50m reset
assert_eq "line" "[usage] 5h: 34% left, resets 1h50m, at avg rate out in 1h37m · 7d: 71% left, resets 4d3h · 40s old" "$out"
assert_not_contains "no modes" "mode:" "$out"
assert_not_contains "no advice line" "→" "$out"
assert_eq "pct_5h" 34 "$(var pct_5h)"
assert_eq "reset_5h_min" 110 "$(var reset_5h_min)"
assert_eq "runway_5h_min" 97.9 "$(var runway_5h_min)"
assert_eq "out_before_reset_5h" 1 "$(var out_before_reset_5h)"
assert_eq "out_before_reset_7d" 0 "$(var out_before_reset_7d)"
assert_eq "no estimate: tokens_left unset" "" "$(var tokens_left)"

echo "usage-status: stale"
setup_dir; state 1801 10 3600 10 86400
out=$(bash "$US")
assert_contains "stale tag" "stale" "$out"
assert_contains "age shown" "30m old" "$out"
state 1799 10 3600 10 86400
assert_not_contains "29m59s not stale" "stale" "$(bash "$US")"

echo "usage-status: reset already passed"
setup_dir; state 5 90 -10 20 86400
out=$(bash "$US")
assert_contains "5h treated as reset" "5h: 100% left (reset)" "$out"
assert_eq "pct_5h 100" 100 "$(var pct_5h)"
assert_eq "no reset time once passed" "" "$(var reset_5h_min)"

echo "usage-status: missing window"
setup_dir; state 5 null 0 85 86400
assert_contains "5h n/a" "5h: n/a" "$(bash "$US")"
assert_eq "pct_5h unset" "" "$(var pct_5h)"

echo "usage-status: runway"
setup_dir; state 5 0 3600 20 432000
# 7d: 20% used in 2d -> 80% lasts 8d at that rate, past the 5d reset: on pace
assert_not_contains "on pace: no runway text" "out in" "$(bash "$US")"
assert_eq "on pace: out_before_reset 0" 0 "$(var out_before_reset_7d)"
state 5 0 3600 60 432000
assert_contains "too fast: runway shown" "7d: 40% left, resets 5d0h, at avg rate out in 1d8h" "$(bash "$US")"
state 5 0 3600 50 600000
assert_eq "too early to judge: runway unset" "" "$(var runway_7d_min)"
state 5 0 3600 100 144060
out=$(bash "$US")
assert_contains "exhausted window says limit reached" "7d: 0% left (limit reached), resets 1d16h" "$out"
assert_not_contains "no runway text at 0%" "out in" "$out"
assert_eq "exhausted: out before reset" 1 "$(var out_before_reset_7d)"

echo "usage-status: spend_limit window"
setup_dir; state 5 10 3600 10 86400 85 864060
assert_contains "spend shown" "spend: 15% left, resets 10d0h" "$(bash "$US")"
assert_eq "pct_spend" 15 "$(var pct_spend)"
setup_dir; state 5 null 0 null 0 120 86400
assert_contains "exceeded spend floors at 0" "spend: 0% left" "$(bash "$US")"
setup_dir; state 5 10 3600 10 86400
assert_not_contains "absent spend not shown" "spend" "$(bash "$US")"

echo "usage-status: token estimate"
setup_dir
printf '{"updated_at":%d,"five_hour":{"used_percentage":66,"resets_at":%d,"tokens_per_pct":120000},"seven_day":{"used_percentage":20,"resets_at":%d,"tokens_per_pct":1500000},"context_tokens":85000}\n' \
  "$((now-40))" "$((now+6600))" "$((now+300060))" >"$USAGE_AWARE_DIR/state.json"
assert_eq "tokens beside %, steps from tighter window" \
  "[usage] 5h: 34% left (~4.1M tok), resets 1h50m, at avg rate out in 1h37m · 7d: 80% left (~120M tok), resets 3d11h · ≈48 steps at 85k context · 40s old" \
  "$(bash "$US")"
assert_eq "tokens_left = tighter window" 4080000 "$(var tokens_left)"
assert_eq "tok_7d" 120000000 "$(var tok_7d)"
assert_eq "steps" 48 "$(var steps)"
assert_eq "context" 85000 "$(var context)"
setup_dir
printf '{"updated_at":%d,"five_hour":{"used_percentage":95,"resets_at":%d,"tokens_per_pct":20000},"seven_day":{"used_percentage":10,"resets_at":%d},"context_tokens":40000}\n' \
  "$now" "$((now+16000))" "$((now+300060))" >"$USAGE_AWARE_DIR/state.json"
out=$(bash "$US")
assert_contains "k formatting" "5h: 5% left (~100k tok)" "$out"
assert_contains "window without estimate stays plain" "7d: 90% left, resets" "$out"
assert_contains "steps use the window that has an estimate" "≈2 steps at 40k context" "$out"
setup_dir
printf '{"updated_at":%d,"five_hour":{"used_percentage":50,"resets_at":%d,"tokens_per_pct":900}}\n' "$now" "$((now-5))" >"$USAGE_AWARE_DIR/state.json"
out=$(bash "$US")
assert_contains "reset window: full estimate" "5h: 100% left (~90k tok) (reset)" "$out"
assert_not_contains "no context: no steps" "steps" "$out"

echo "usage-status: retries a half-written state file"
setup_dir; state 5 10 3600 10 86400
good="$(cat "$USAGE_AWARE_DIR/state.json")"; echo '{"updated_' >"$USAGE_AWARE_DIR/state.json"
( sleep 0.02; printf '%s\n' "$good" >"$USAGE_AWARE_DIR/state.json" ) &
out=$(bash "$US"); wait
assert_contains "read after retry" "5h: 90% left" "$out"

echo "usage-status: speed"
setup_dir; state 5 10 3600 10 86400
start=$(date +%s%N); bash "$US" >/dev/null; ms=$(( ($(date +%s%N) - start) / 1000000 ))
assert_true "under 100ms (${ms}ms)" test "$ms" -lt 100

finish
