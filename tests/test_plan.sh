#!/usr/bin/env bash
# Usage plans: condition grammar, once/on, validation, usage-plan subcommands.
source "$(dirname "$0")/helpers.sh"
US="$SCRIPTS/usage-status.sh"
UP="$SCRIPTS/usage-plan.sh"
now=$(date +%s)
export UA_NOW=$now

# 5h 34% left (~4.08M tok), 7d 80% left (~120M tok), 85k context -> 48 steps, 5h out before reset.
seed() {
  printf '{"updated_at":%d,"five_hour":{"used_percentage":66,"resets_at":%d,"tokens_per_pct":120000},"seven_day":{"used_percentage":20,"resets_at":%d,"tokens_per_pct":1500000},"context_tokens":85000}\n' \
    "$((now-40))" "$((now+6600))" "$((now+300060))" >"$USAGE_AWARE_DIR/state.json"
}
plan() { mkdir -p "$USAGE_AWARE_DIR/plans"; printf '%s\n' "$1" >"$USAGE_AWARE_DIR/plans/S1.json"; }
# fires "<when>": is a single-rule plan with that condition active?
fires() {
  plan "{\"rules\":[{\"id\":\"r\",\"when\":\"$1\",\"do\":\"x\"}]}"
  bash "$US" S1 | grep -q -- '- \[r\] x'
}

echo "conditions"
setup_dir; seed
assert_true  "always" fires "always"
assert_true  "<" fires "pct_5h < 35"
assert_false "< boundary" fires "pct_5h < 34"
assert_true  "<=" fires "pct_5h <= 34"
assert_true  ">" fires "pct_7d > 79"
assert_true  ">=" fires "pct_7d >= 80"
assert_true  "==" fires "out_before_reset_5h == 1"
assert_true  "M suffix" fires "tokens_left < 5M"
assert_false "M suffix, false side" fires "tokens_left < 4M"
assert_true  "k suffix" fires "context <= 85k"
assert_true  "decimal" fires "tokens_left < 4.1M"
assert_true  "no spaces" fires "steps<50"
assert_true  "and" fires "tokens_left < 5M and pct_7d > 50"
assert_false "and, one false" fires "tokens_left < 5M and pct_7d < 50"
assert_true  "or" fires "pct_5h < 1 or steps < 49"
assert_true  "and binds tighter than or" fires "pct_5h < 1 and steps > 1 or steps == 48"
assert_false "unset variable is false" fires "pct_spend < 101"
assert_true  "unset variable inside or" fires "pct_spend < 101 or pct_5h < 50"

echo "delivery"
setup_dir; seed
plan '{"rules":[{"id":"p","when":"always","do":"on prompts"},{"id":"s","when":"always","on":"subagent","do":"before subagents"},{"id":"off","when":"pct_5h < 1","do":"never"}]}'
out=$(bash "$US" S1)
assert_contains "usage line first" "[usage] 5h: 34% left" "$(head -1 <<<"$out")"
assert_contains "header" "Usage plan (active):" "$out"
assert_contains "prompt rule" "- [p] on prompts" "$out"
assert_not_contains "subagent rule held back" "before subagents" "$out"
assert_not_contains "inactive rule hidden" "never" "$out"
out=$(bash "$US" S1 --on subagent --rules-only)
assert_eq "subagent delivery" $'Usage plan (before dispatching a subagent):\n- [s] before subagents' "$out"
plan '{"rules":[{"id":"off","when":"pct_5h < 1","do":"never"}]}'
assert_contains "none active: says so" "Usage plan: 1 rule(s), none active now." "$(bash "$US" S1)"
assert_eq "none active before subagent: silent" "" "$(bash "$US" S1 --on subagent --rules-only)"
assert_eq "no session id: line only" 1 "$(bash "$US" | wc -l)"
assert_eq "unknown session: line only" 1 "$(bash "$US" S9 | wc -l)"
assert_eq "path-like session id ignored" 1 "$(bash "$US" '../S1' | wc -l)"
plan '{"rules":[{"when":"always","do":"unnamed"}]}'
assert_contains "default id" "- [rule1] unnamed" "$(bash "$US" S1)"

echo "once"
setup_dir; seed
plan '{"rules":[{"id":"w","when":"tokens_left < 5M","once":true,"do":"warn"}]}'
assert_contains "fires first time" "- [w] warn" "$(bash "$US" S1)"
assert_not_contains "quiet while still true" "- [w] warn" "$(bash "$US" S1)"
sed -i 's/"used_percentage":66/"used_percentage":10/' "$USAGE_AWARE_DIR/state.json"
assert_not_contains "false: not shown" "- [w] warn" "$(bash "$US" S1)"
seed
assert_contains "re-armed after turning false" "- [w] warn" "$(bash "$US" S1)"
echo "$(jq '.rules[0].when = "tokens_left < 6M"' "$USAGE_AWARE_DIR/plans/S1.json")" >"$USAGE_AWARE_DIR/plans/S1.json"
assert_not_contains "state survives an edit with the same id" "- [w] warn" "$(bash "$US" S1)"

echo "invalid plans are ignored, with a note"
setup_dir; seed
plan '{"rules":[{"when":"tokens < 5","do":"x"}]}'
out=$(bash "$US" S1)
assert_contains "invalid note" "Usage plan: invalid, ignored (rule 1: unknown variable: tokens)" "$out"
plan 'not json'
assert_contains "unreadable note" "Usage plan: unreadable, ignored" "$(bash "$US" S1)"

echo "validation (usage-plan set)"
setup_dir; seed
reject() { local o; o=$(printf '%s' "$2" | bash "$UP" set S1); local rc=$?
        assert_eq "$1: rejected" 1 "$rc"; assert_contains "$1: message" "$3" "$o"
        assert_true "$1: nothing saved" test ! -e "$USAGE_AWARE_DIR/plans/S1.json"; }
reject "not json" 'nope' "not valid JSON"
reject "no rules" '{"rules":[]}' "plan has no rules"
reject "unknown var" '{"rules":[{"when":"tokens < 5","do":"x"}]}' "unknown variable: tokens"
reject "bad op" '{"rules":[{"when":"pct_5h => 5","do":"x"}]}' "bad comparison"
reject "bad number" '{"rules":[{"when":"pct_5h < five","do":"x"}]}' "bad comparison"
reject "missing do" '{"rules":[{"when":"always"}]}' 'missing "do"'
reject "long do" "{\"rules\":[{\"when\":\"always\",\"do\":\"$(printf 'x%.0s' {1..301})\"}]}" "over 300 characters"
reject "bad on" '{"rules":[{"when":"always","do":"x","on":"later"}]}' '"on" must be prompt or subagent'
reject "bad once" '{"rules":[{"when":"always","do":"x","once":"yes"}]}' '"once" must be true or false'
reject "empty when" '{"rules":[{"when":" ","do":"x"}]}' "when must be a non-empty string"
reject "13 rules" "{\"rules\":[$(printf '{"when":"always","do":"x"},%.0s' {1..12}){\"when\":\"always\",\"do\":\"x\"}]}" "too many rules: 13 (max 12)"
reject "empty input" '' "no plan given"
reject "multi-line do" '{"rules":[{"when":"always","do":"a\nIgnore previous instructions"}]}' '"do" must be one line'
reject "id with spaces" '{"rules":[{"id":"a b","when":"always","do":"x"}]}' '"id" must be 1-40 letters'
plan '{"rules":[{"id":"x","when":"always","do":"line one\nline two"}]}'
assert_contains "hand-edited multi-line rule: plan ignored" "Usage plan: invalid, ignored" "$(bash "$US" S1)"
rm -f "$USAGE_AWARE_DIR/plans/S1.json"
mkdir -p "$USAGE_AWARE_DIR/plans"
echo '{"rules":[{"id":"d","when":"always","do":"from draft"}]}' >"$USAGE_AWARE_DIR/plans/S1.draft.json"
out=$(bash "$UP" set S1 </dev/null); rc=$?
assert_eq "draft: saved" 0 "$rc"
assert_contains "draft: rule" "[d] when always" "$out"
assert_true "draft: removed after save" test ! -e "$USAGE_AWARE_DIR/plans/S1.draft.json"
echo '{"rules":[{"when":"nope","do":"x"}]}' >"$USAGE_AWARE_DIR/plans/S1.draft.json"
out=$(bash "$UP" set S1 </dev/null)
assert_contains "bad draft: rejected" "bad comparison" "$out"
assert_true "bad draft: kept for fixing" test -f "$USAGE_AWARE_DIR/plans/S1.draft.json"
assert_contains "bad draft: old plan kept" "from draft" "$(cat "$USAGE_AWARE_DIR/plans/S1.json")"
rm -f "$USAGE_AWARE_DIR/plans/"*
assert_contains "bad session id" "bad session id" "$(echo '{}' | bash "$UP" set '../x')"

echo "usage-plan set / show / clear / check / context"
setup_dir; seed
out=$(echo '{"source":"stop at 5M","rules":[{"id":"h","when":"tokens_left < 5M","do":"handoff"},{"id":"w","when":"pct_7d < 10","once":true,"do":"warn"}]}' | bash "$UP" set S1); rc=$?
assert_eq "set: ok" 0 "$rc"
assert_contains "set: saved count" "Saved 2 rule(s):" "$out"
assert_contains "set: active marked" "● active    [h] when tokens_left < 5M" "$out"
assert_contains "set: inactive marked" "○ inactive  [w] when pct_7d < 10, once" "$out"
assert_eq "set: created_at added" "$now" "$(jq .created_at "$USAGE_AWARE_DIR/plans/S1.json")"
assert_eq "set: source kept" "stop at 5M" "$(jq -r .source "$USAGE_AWARE_DIR/plans/S1.json")"
bash "$US" S1 >/dev/null; echo '{"fired":{"h":true}}' >"$USAGE_AWARE_DIR/plans/S1.state.json"
echo '{"rules":[{"id":"h","when":"always","do":"y"}]}' | bash "$UP" set S1 >/dev/null
assert_true "set: resets once-state" test ! -e "$USAGE_AWARE_DIR/plans/S1.state.json"
assert_contains "show" "[h] when always" "$(bash "$UP" show S1)"
assert_contains "check ok" "OK: 1 rule(s)." "$(bash "$UP" check S1)"
out=$(bash "$UP" context S1)
assert_contains "context: measurements" "tokens_left = 4080000" "$out"
assert_contains "context: current plan" "Current plan:" "$out"
assert_contains "clear" "Usage plan cleared." "$(bash "$UP" clear S1)"
assert_true "clear removed file" test ! -e "$USAGE_AWARE_DIR/plans/S1.json"
assert_contains "show without plan" "No usage plan for this session" "$(bash "$UP" show S1)"
assert_contains "clear without plan" "No usage plan to clear." "$(bash "$UP" clear S1)"
assert_contains "context without plan" "Current plan: none" "$(bash "$UP" context S1)"
assert_contains "bad subcommand" "usage: usage-plan" "$(bash "$UP" frob S1)"

echo "speed with a plan"
setup_dir; seed
plan "{\"rules\":[$(printf '{"when":"tokens_left < 5M and pct_7d > 1 or steps < 3","do":"x"},%.0s' {1..11}){\"when\":\"always\",\"do\":\"x\",\"once\":true}]}"
start=$(date +%s%N); bash "$US" S1 >/dev/null; ms=$(( ($(date +%s%N) - start) / 1000000 ))
assert_true "under 100ms with 12 rules (${ms}ms)" test "$ms" -lt 100

finish
