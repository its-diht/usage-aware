#!/usr/bin/env bash
# Testing step 3: set-thresholds
source "$(dirname "$0")/helpers.sh"
ST="$SCRIPTS/set-thresholds.sh"
cfg() { cat "$USAGE_AWARE_DIR/config.json" 2>/dev/null; }

echo "set-thresholds: no args shows defaults"
setup_dir
out=$(bash "$ST"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_contains "shows conserve" "CONSERVE below 50%" "$out"
assert_contains "shows wrap-up" "WRAP-UP below 20%" "$out"
assert_contains "marks defaults" "(defaults)" "$out"
assert_true "no config written" test ! -e "$USAGE_AWARE_DIR/config.json"

echo "set-thresholds: valid set"
out=$(bash "$ST" 60 25); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "config written" '{"conserve":60,"wrapup":25}' "$(jq -c . <<<"$(cfg)")"
assert_contains "confirms" "CONSERVE below 60%" "$out"
assert_contains "applies next prompt" "next prompt" "$out"
assert_contains "show reflects config" "WRAP-UP below 25%" "$(bash "$ST")"
assert_eq "no temp files" 1 "$(ls -A "$USAGE_AWARE_DIR" | wc -l)"
bash "$ST" 100 0 >/dev/null
assert_eq "edges 100 0 accepted" '{"conserve":100,"wrapup":0}' "$(jq -c . <<<"$(cfg)")"

echo "set-thresholds: single string arg (as \$ARGUMENTS may arrive)"
bash "$ST" "70 30" >/dev/null
assert_eq "space-joined arg parsed" '{"conserve":70,"wrapup":30}' "$(jq -c . <<<"$(cfg)")"

echo "set-thresholds: reset"
out=$(bash "$ST" reset); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "defaults restored" '{"conserve":50,"wrapup":20}' "$(jq -c . <<<"$(cfg)")"

echo "set-thresholds: bad input changes nothing"
bash "$ST" 60 25 >/dev/null
for args in "101 20" "50 -1" "20 50" "50 50" "abc 20" "50" "50 20 10" "5.5 2" "foo"; do
  out=$(bash "$ST" $args); rc=$?
  assert_contains "'$args' prints usage" "Usage:" "$out"
  assert_eq "'$args' config unchanged" '{"conserve":60,"wrapup":25}' "$(jq -c . <<<"$(cfg)")"
done

finish
