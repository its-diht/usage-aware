#!/usr/bin/env bash
# inject-usage / inject-policy, plus testing step 4 (missing jq)
source "$(dirname "$0")/helpers.sh"
IU="$SCRIPTS/inject-usage.sh"
IP="$SCRIPTS/inject-policy.sh"
now=$(date +%s)
seed() { printf '{"updated_at":%d,"five_hour":{"used_percentage":66,"resets_at":%d},"seven_day":{"used_percentage":29,"resets_at":%d}}\n' \
  "$now" "$((now+6600))" "$((now+356400))" >"$USAGE_AWARE_DIR/state.json"; }

echo "inject-usage"
setup_dir; seed
out=$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' | bash "$IU"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "hookEventName" UserPromptSubmit "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
assert_eq "context == usage-status output" "$(bash "$SCRIPTS/usage-status.sh")" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
setup_dir
out=$(echo '{}' | bash "$IU")
assert_contains "no state -> unknown still injected" "usage unknown" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"

echo "inject-usage: warns once when the mod isn't feeding data"
setup_dir; seed
out=$(echo '{"session_id":"s1"}' | bash "$IU")
assert_contains "warning when no heartbeat" "mod isn't running" "$(jq -r '.systemMessage // ""' <<<"$out")"
assert_contains "context still injected" "[usage]" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
out=$(echo '{"session_id":"s1"}' | bash "$IU")
assert_eq "same session: not repeated" "" "$(jq -r '.systemMessage // ""' <<<"$out")"
out=$(echo '{"session_id":"s2"}' | bash "$IU")
assert_contains "new session: warned again" "mod isn't running" "$(jq -r '.systemMessage // ""' <<<"$out")"
setup_dir; seed; echo "{\"heartbeat\":$now}" >"$USAGE_AWARE_DIR/mod.json"
out=$(echo '{"session_id":"s1"}' | bash "$IU")
assert_eq "fresh heartbeat: no warning" "" "$(jq -r '.systemMessage // ""' <<<"$out")"
setup_dir; seed; echo "{\"heartbeat\":$((now-90000))}" >"$USAGE_AWARE_DIR/mod.json"
out=$(echo '{"session_id":"s1"}' | bash "$IU")
assert_contains "day-old heartbeat: warning" "mod isn't running" "$(jq -r '.systemMessage // ""' <<<"$out")"

echo "inject-policy: sync + policy"
setup_dir; seed
plugin=$(mktemp -d); cp -r "$ROOT/scripts" "$plugin/"
export CLAUDE_PLUGIN_ROOT="$plugin"
out=$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$IP"); rc=$?
assert_eq "exit 0" 0 "$rc"
for f in usage-status lib.sh; do
  assert_true "synced $f" test -f "$USAGE_AWARE_DIR/$f"
done
assert_true "no statusline script synced" test ! -e "$USAGE_AWARE_DIR/tap-statusline"
assert_true "usage-status executable" test -x "$USAGE_AWARE_DIR/usage-status"
assert_eq "synced usage-status runs standalone" "$(bash "$SCRIPTS/usage-status.sh")" "$("$USAGE_AWARE_DIR/usage-status")"
ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$out")
assert_eq "hookEventName" SessionStart "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
for needle in NORMAL CONSERVE WRAP-UP "Account for usage in every plan" "defer or split" "7d" \
              "$USAGE_AWARE_DIR/usage-status" "before spawning subagents" "[usage] mode: CONSERVE" \
              "on pace to run out" "resets soon" "spend"; do
  assert_contains "policy mentions: $needle" "$needle" "$ctx"
done
assert_true "no systemMessage when healthy" test "$(jq -r '.systemMessage // "none"' <<<"$out")" = none

echo "inject-policy: thresholds reflected in policy"
bash "$SCRIPTS/set-thresholds.sh" 60 25 >/dev/null
ctx=$(echo '{}' | bash "$IP" | jq -r .hookSpecificOutput.additionalContext)
assert_contains "custom conserve in table" "25–60% left" "$ctx"

echo "inject-policy: sync only when changed"
m1=$(stat -c %Y.%i "$USAGE_AWARE_DIR/usage-status")
sleep 1; echo '{}' | bash "$IP" >/dev/null
assert_eq "identical file not rewritten" "$m1" "$(stat -c %Y.%i "$USAGE_AWARE_DIR/usage-status")"
echo '# plugin update' >>"$plugin/scripts/usage-status.sh"
echo '{}' | bash "$IP" >/dev/null
assert_true "changed file re-synced" cmp -s "$plugin/scripts/usage-status.sh" "$USAGE_AWARE_DIR/usage-status"

echo "inject-policy: prunes week-old session cost files"
mkdir -p "$USAGE_AWARE_DIR/sessions"
echo '{}' >"$USAGE_AWARE_DIR/sessions/old.json"; touch -d '8 days ago' "$USAGE_AWARE_DIR/sessions/old.json"
echo '{}' >"$USAGE_AWARE_DIR/sessions/new.json"
echo '{}' | bash "$IP" >/dev/null
assert_true "old file pruned" test ! -e "$USAGE_AWARE_DIR/sessions/old.json"
assert_true "recent file kept" test -f "$USAGE_AWARE_DIR/sessions/new.json"
unset CLAUDE_PLUGIN_ROOT

echo "step 4: missing jq"
fake=$(mktemp -d)
for b in bash cat cmp cp chmod date dirname mkdir mktemp mv readlink rm sed; do ln -s "$(command -v $b)" "$fake/$b"; done
setup_dir; seed
out=$(echo '{}' | PATH="$fake" "$fake/bash" "$IP" 2>&1); rc=$?
assert_eq "policy exit 0" 0 "$rc"
assert_eq "systemMessage" "usage-aware: jq not found, plugin inactive. Install jq (e.g. sudo apt install jq)." \
  "$(jq -r .systemMessage <<<"$out")"
assert_eq "no additionalContext" null "$(jq -r .hookSpecificOutput <<<"$out")"
assert_true "nothing synced" test ! -e "$USAGE_AWARE_DIR/usage-status"
out=$(echo '{}' | PATH="$fake" "$fake/bash" "$IU" 2>&1); rc=$?
assert_eq "inject-usage exit 0" 0 "$rc"
assert_eq "inject-usage silent" "" "$out"
out=$(PATH="$fake" "$fake/bash" "$SCRIPTS/usage-status.sh" 2>&1); rc=$?
assert_eq "usage-status exit 0" 0 "$rc"
assert_contains "usage-status says jq missing" "jq not found" "$out"
out=$(PATH="$fake" "$fake/bash" "$SCRIPTS/set-thresholds.sh" 60 25 2>&1)
assert_contains "set-thresholds says jq missing" "jq not found" "$out"

finish
