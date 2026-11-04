#!/usr/bin/env bash
# Testing step 2: usage-status
source "$(dirname "$0")/helpers.sh"
US="$SCRIPTS/usage-status.sh"
now=$(date +%s)

# state <age_secs> <5h_used|null> <5h_reset_in> <7d_used|null> <7d_reset_in> [spend_used spend_reset_in]
state() {
  local w5=null w7=null sp=null
  [[ $2 != null ]] && w5="{\"used_percentage\":$2,\"resets_at\":$((now+$3))}"
  [[ $4 != null ]] && w7="{\"used_percentage\":$4,\"resets_at\":$((now+$5))}"
  [[ -n ${6:-} ]] && sp="{\"used_percentage\":$6,\"resets_at\":$((now+$7))}"
  printf '{"updated_at":%d,"five_hour":%s,"seven_day":%s,"spend_limit":%s}\n' "$((now-$1))" "$w5" "$w7" "$sp" >"$USAGE_AWARE_DIR/state.json"
}
mode_of() { bash "$US" | sed -n 's/.*mode: \([A-Z-]*\).*/\1/p'; }

echo "usage-status: missing state"
setup_dir
out=$(bash "$US"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "says unknown" "usage unknown" "$out"
assert_not_contains "no mode" "mode:" "$out"

echo "usage-status: corrupt state"
setup_dir; echo 'garbage{' >"$USAGE_AWARE_DIR/state.json"
out=$(bash "$US"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "corrupt -> unknown" "usage unknown" "$out"

echo "usage-status: fresh state, plan example"
setup_dir; state 40 66 6600 29 356400
out=$(bash "$US")
line1=$(head -1 <<<"$out")
# 5h: 66% used over 3h10m elapsed -> 34% lasts 1h37m at that rate, before the 1h50m reset
assert_eq "line 1" "[usage] mode: CONSERVE · 5h: 34% left, resets 1h50m, pace: out in 1h37m · 7d: 71% left, resets 4d3h · 40s old" "$line1"
assert_contains "conserve rule" "→ small verifiable steps, no fan-outs/subagents, checkpoint often" "$out"
assert_not_contains "not stale" "stale" "$out"

echo "usage-status: stale"
setup_dir; state 1801 10 3600 10 86400
out=$(bash "$US")
assert_contains "stale tag" "stale" "$out"
assert_contains "age shown" "30m old" "$out"
setup_dir; state 1799 10 3600 10 86400
assert_not_contains "29m59s not stale" "stale" "$(bash "$US")"

echo "usage-status: reset already passed"
setup_dir; state 60 95 -10 30 86400
out=$(bash "$US")
assert_contains "5h treated as reset" "5h: 100% left (reset)" "$out"
assert_eq "mode from 7d only" NORMAL "$(mode_of)"

echo "usage-status: missing window"
setup_dir; state 60 null 0 85 86400
out=$(bash "$US")
assert_contains "5h n/a" "5h: n/a" "$out"
assert_eq "mode from 7d" WRAP-UP "$(mode_of)"

echo "usage-status: mode boundaries (defaults 50/20)"
for case in "50:NORMAL" "50.5:CONSERVE" "80:CONSERVE" "80.1:WRAP-UP" "100:WRAP-UP" "0:NORMAL"; do
  used=${case%%:*} want=${case#*:}
  setup_dir; state 5 "$used" 3600 0 86400
  assert_eq "5h used $used -> $want" "$want" "$(mode_of)"
done
setup_dir; state 5 10 3600 60 86400
assert_eq "tighter window (7d) decides" CONSERVE "$(mode_of)"
setup_dir; state 5 85 3600 10 86400
assert_contains "wrap-up rule" "→ finish the current unit, write a handoff note (done / next / open issues), ask before starting new work" "$(bash "$US")"
setup_dir; state 5 10 3600 10 86400
assert_contains "normal rule" "→ work normally, but size plans against remaining usage" "$(bash "$US")"

echo "usage-status: custom config"
setup_dir; echo '{"conserve":60,"wrapup":25}' >"$USAGE_AWARE_DIR/config.json"
state 5 45 3600 0 86400; assert_eq "55% left with 60/25 -> CONSERVE" CONSERVE "$(mode_of)"
state 5 40 3600 0 86400; assert_eq "60% left with 60/25 -> NORMAL" NORMAL "$(mode_of)"
state 5 76 3600 0 86400; assert_eq "24% left with 60/25 -> WRAP-UP" WRAP-UP "$(mode_of)"
echo 'nonsense' >"$USAGE_AWARE_DIR/config.json"
state 5 45 3600 0 86400; assert_eq "bad config falls back to defaults" NORMAL "$(mode_of)"

echo "usage-status: pace"
setup_dir; state 5 0 3600 30 518400          # 7d: 30% used in 1 day, 6 days to go
assert_eq "7d burning too fast -> CONSERVE" CONSERVE "$(mode_of)"
assert_contains "reason shown" "mode: CONSERVE (pace: 7d)" "$(bash "$US")"
assert_contains "runway shown" "pace: out in 2d8h" "$(bash "$US")"
setup_dir; state 5 0 3600 30 172800          # 30% used in 5 days, 2 to go
assert_eq "7d on pace -> NORMAL" NORMAL "$(mode_of)"
assert_not_contains "no pace text when on pace" "pace:" "$(bash "$US")"
setup_dir; state 5 9 16800 0 86400           # 5h: 9% used in first 20 min (<10% elapsed)
assert_eq "too early to judge pace -> NORMAL" NORMAL "$(mode_of)"
setup_dir; state 5 85 3600 30 518400         # pace never loosens a stricter level
assert_eq "pace does not relax WRAP-UP" WRAP-UP "$(mode_of)"

setup_dir; state 5 0 3600 100 144060          # 7d exhausted
out=$(bash "$US")
assert_contains "exhausted window says limit reached" "7d: 0% left (limit reached), resets 1d16h" "$out"
assert_not_contains "no pace text at 0%" "pace:" "$out"

echo "usage-status: reset soon relaxes one step"
setup_dir; state 5 88 240 0 86400            # 5h: 12% left, resets in 4 min
assert_eq "WRAP-UP -> CONSERVE near reset" CONSERVE "$(mode_of)"
assert_contains "reason shown" "mode: CONSERVE (5h resets soon)" "$(bash "$US")"
setup_dir; state 5 60 600 0 86400
assert_eq "CONSERVE -> NORMAL near reset" NORMAL "$(mode_of)"
setup_dir; state 5 60 960 0 86400
assert_eq "16 min to reset is outside the 15 min horizon -> CONSERVE" CONSERVE "$(mode_of)"
setup_dir; state 5 0 3600 85 43200            # 7d resets within 12h
assert_eq "7d near reset relaxes" CONSERVE "$(mode_of)"
setup_dir; state 5 88 240 85 518400          # other window still strict
assert_eq "relaxing one window doesn't hide the other" WRAP-UP "$(mode_of)"

echo "usage-status: spend_limit window"
setup_dir; state 5 10 3600 10 86400 85 864060
out=$(bash "$US")
assert_contains "spend shown" "spend: 15% left, resets 10d0h" "$out"
assert_eq "spend decides mode" WRAP-UP "$(mode_of)"
setup_dir; state 5 null 0 null 0 120 864000
assert_contains "exceeded spend floors at 0" "spend: 0% left" "$(bash "$US")"
assert_eq "spend-only data has a mode" WRAP-UP "$(mode_of)"
setup_dir; state 5 10 3600 10 86400
assert_not_contains "absent spend not shown" "spend" "$(bash "$US")"

echo "usage-status: retries a half-written state file"
setup_dir; printf '{"updated_at":' >"$USAGE_AWARE_DIR/state.json"
( sleep 0.03; state 5 10 3600 10 86400 ) &
out=$(bash "$US"); wait
assert_contains "read after retry" "mode: NORMAL" "$out"

echo "usage-status: speed"
setup_dir; state 5 10 3600 10 86400
t0=$(date +%s%N); bash "$US" >/dev/null; t1=$(date +%s%N)
ms=$(( (t1-t0)/1000000 ))
assert_true "under 100ms (${ms}ms)" test "$ms" -lt 100


echo "usage-status: token estimate"
setup_dir; now=$(date +%s)
printf '{"updated_at":%d,"five_hour":{"used_percentage":66,"resets_at":%d,"tokens_per_pct":120000},"seven_day":{"used_percentage":20,"resets_at":%d,"tokens_per_pct":1500000},"context_tokens":85000}\n' \
  "$((now-40))" "$((now+6630))" "$((now+300060))" >"$USAGE_AWARE_DIR/state.json"
line1=$(bash "$US" | head -1)
assert_eq "tokens beside %, steps from tighter window" \
  "[usage] mode: CONSERVE · 5h: 34% left (~4.1M tok), resets 1h50m, pace: out in 1h37m · 7d: 80% left (~120M tok), resets 3d11h · ≈48 steps at 85k context · 40s old" "$line1"

setup_dir
printf '{"updated_at":%d,"five_hour":{"used_percentage":95,"resets_at":%d,"tokens_per_pct":20000},"seven_day":{"used_percentage":10,"resets_at":%d},"context_tokens":40000}\n' \
  "$now" "$((now+16000))" "$((now+300060))" >"$USAGE_AWARE_DIR/state.json"
line1=$(bash "$US" | head -1)
assert_contains "k formatting" "5h: 5% left (~100k tok)" "$line1"
assert_contains "window without estimate stays plain" "7d: 90% left, resets" "$line1"
assert_contains "steps use the window that has an estimate" "≈2 steps at 40k context" "$line1"

setup_dir
printf '{"updated_at":%d,"five_hour":{"used_percentage":50,"resets_at":%d,"tokens_per_pct":900}}\n' "$now" "$((now-5))" >"$USAGE_AWARE_DIR/state.json"
line1=$(bash "$US" | head -1)
assert_contains "reset window: full estimate" "5h: 100% left (~90k tok) (reset)" "$line1"
assert_not_contains "no context: no steps" "steps" "$line1"

finish
