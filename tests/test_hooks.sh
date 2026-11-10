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
for f in usage-status ua-lib.sh; do
  assert_true "synced $f" test -f "$USAGE_AWARE_DIR/$f"
done
assert_true "no statusline script synced" test ! -e "$USAGE_AWARE_DIR/tap-statusline"
assert_true "usage-status executable" test -x "$USAGE_AWARE_DIR/usage-status"
echo "UA_PLANS=" >"$USAGE_AWARE_DIR/lib.sh"   # a pre-0.4 session syncing its own lib.sh
assert_contains "synced usage-plan ignores a stale lib.sh" "Plan file: $USAGE_AWARE_DIR/plans/S1.json" "$(bash "$USAGE_AWARE_DIR/usage-plan" context S1)"
assert_eq "synced usage-status runs standalone" "$(bash "$SCRIPTS/usage-status.sh")" "$("$USAGE_AWARE_DIR/usage-status")"
ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$out")
assert_eq "hookEventName" SessionStart "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
for needle in "plain measurements" "(~N tok)" "steps at" "No usage plan is set" "/usage-aware:usage-plan" \
              "$USAGE_AWARE_DIR/usage-status" "before spawning subagents" "[usage] 5h: 34% left"; do
  assert_contains "policy mentions: $needle" "$needle" "$ctx"
done
assert_not_contains "no modes" "CONSERVE" "$ctx"
assert_true "no systemMessage when healthy" test "$(jq -r '.systemMessage // "none"' <<<"$out")" = none

echo "inject-policy: session id, plan note"
mkdir -p "$USAGE_AWARE_DIR/plans"
echo '{"rules":[{"id":"h","when":"pct_5h < 50","do":"hand off"}]}' >"$USAGE_AWARE_DIR/plans/S1.json"
ctx=$(echo '{"session_id":"S1","source":"resume"}' | bash "$IP" | jq -r .hookSpecificOutput.additionalContext)
assert_contains "per-session status command" "$USAGE_AWARE_DIR/usage-status S1" "$ctx"
assert_contains "plan note" "This session has a usage plan" "$ctx"
assert_contains "plan framed as usage-only" "A plan is only about usage" "$ctx"
assert_contains "active rule shown" "- [h] hand off" "$ctx"

echo "plan carried across /clear"
cc='{"session_id":"S1","reason":"clear","cwd":"/proj"}'
echo "$cc" | bash "$SCRIPTS/carry-plan.sh"
ctx=$(echo '{"session_id":"S2","source":"clear","cwd":"/other"}' | bash "$IP" | jq -r .hookSpecificOutput.additionalContext)
assert_true "other directory: not carried" test ! -e "$USAGE_AWARE_DIR/plans/S2.json"
ctx=$(echo '{"session_id":"S3","source":"clear","cwd":"/proj"}' | bash "$IP" | jq -r .hookSpecificOutput.additionalContext)
assert_true "same directory: carried" cmp -s "$USAGE_AWARE_DIR/plans/S1.json" "$USAGE_AWARE_DIR/plans/S3.json"
assert_contains "says carried" "carried over from before /clear" "$ctx"
assert_true "pointer consumed" test -z "$(ls -A "$USAGE_AWARE_DIR/plans" | grep carry)"
echo '{"session_id":"S1","reason":"other","cwd":"/proj"}' | bash "$SCRIPTS/carry-plan.sh"
assert_true "non-clear end leaves no pointer" test -z "$(ls -A "$USAGE_AWARE_DIR/plans" | grep carry)"
echo "$cc" | bash "$SCRIPTS/carry-plan.sh"; touch -d '2 minutes ago' "$USAGE_AWARE_DIR"/plans/.carry-*
echo '{"session_id":"S4","source":"clear","cwd":"/proj"}' | bash "$IP" >/dev/null
assert_true "stale pointer ignored" test ! -e "$USAGE_AWARE_DIR/plans/S4.json"

echo "inject-usage: plan rules"
setup_dir; seed; mkdir -p "$USAGE_AWARE_DIR/plans"
echo '{"rules":[{"id":"h","when":"pct_5h < 50","do":"hand off"},{"id":"sa","when":"always","on":"subagent","do":"estimate first"}]}' \
  >"$USAGE_AWARE_DIR/plans/S1.json"
ctx=$(echo '{"session_id":"S1"}' | bash "$IU" | jq -r .hookSpecificOutput.additionalContext)
assert_contains "active prompt rule" "- [h] hand off" "$ctx"
assert_contains "subagent rule listed ahead of dispatch" "before the call):"$'\n'"- [sa] estimate first" "$ctx"
ctx=$(echo '{"session_id":"S9"}' | bash "$IU" | jq -r .hookSpecificOutput.additionalContext)
assert_not_contains "other session: no plan" "Usage plan" "$ctx"

echo "inject-subagent (PreToolUse)"
out=$(echo '{"session_id":"S1","tool_name":"Agent"}' | bash "$SCRIPTS/inject-subagent.sh"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "hookEventName" PreToolUse "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
assert_contains "subagent rule" "- [sa] estimate first" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
assert_contains "with usage line" "[usage] 5h:" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
assert_eq "never decides permission" null "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
out=$(echo '{"session_id":"S9","tool_name":"Agent"}' | bash "$SCRIPTS/inject-subagent.sh")
assert_eq "no plan: silent" "" "$out"
export CLAUDE_PLUGIN_ROOT="$plugin"; setup_dir; seed; echo '{}' | bash "$IP" >/dev/null

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
mkdir -p "$USAGE_AWARE_DIR/contexts"
echo '{}' >"$USAGE_AWARE_DIR/contexts/old.json"; touch -d '8 days ago' "$USAGE_AWARE_DIR/contexts/old.json"
echo '{}' >"$USAGE_AWARE_DIR/contexts/new.json"
echo '{}' | bash "$IP" >/dev/null
assert_true "old file pruned" test ! -e "$USAGE_AWARE_DIR/sessions/old.json"
assert_true "recent file kept" test -f "$USAGE_AWARE_DIR/sessions/new.json"
assert_true "old context file pruned" test ! -e "$USAGE_AWARE_DIR/contexts/old.json"
assert_true "recent context file kept" test -f "$USAGE_AWARE_DIR/contexts/new.json"
unset CLAUDE_PLUGIN_ROOT

echo "step 4: missing jq"
fake=$(mktemp -d)
for b in bash cat cmp cp chmod date dirname mkdir mktemp mv readlink rm sed find stat cksum cut; do ln -s "$(command -v $b)" "$fake/$b"; done
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
out=$(PATH="$fake" "$fake/bash" "$SCRIPTS/usage-plan.sh" show S1 2>&1)
assert_contains "usage-plan says jq missing" "jq not found" "$out"
out=$(echo '{"session_id":"S1"}' | PATH="$fake" "$fake/bash" "$SCRIPTS/inject-subagent.sh" 2>&1)
assert_eq "inject-subagent silent" "" "$out"

finish
