#!/usr/bin/env bash
# Runtime dirs: data per account (CLAUDE_CONFIG_DIR), scripts at one fixed path.
source "$(dirname "$0")/helpers.sh"

# dirs [env assignments...]: "<UA_DIR> <UA_BIN_DIR> <UA_DISPLAY_DIR>" as lib.sh sets them
dirs() { env -u USAGE_AWARE_DIR -u CLAUDE_CONFIG_DIR HOME=/h "$@" bash -c \
  'source "$1"; echo "$UA_DIR $UA_BIN_DIR $UA_DISPLAY_DIR"' _ "$SCRIPTS/lib.sh"; }

echo "lib.sh: runtime dirs"
assert_eq "default account" "/h/.claude/usage-aware /h/.claude/usage-aware ~/.claude/usage-aware" "$(dirs)"
assert_eq "other config dir: own data, shared scripts" \
  "/h/.claude-alt/usage-aware /h/.claude/usage-aware ~/.claude/usage-aware" "$(dirs CLAUDE_CONFIG_DIR=/h/.claude-alt)"
assert_eq "trailing slash ignored" "/h/.claude-alt/usage-aware" "$(dirs CLAUDE_CONFIG_DIR=/h/.claude-alt/ | cut -d' ' -f1)"
assert_eq "config dir = default dir" "/h/.claude/usage-aware" "$(dirs CLAUDE_CONFIG_DIR=/h/.claude/ | cut -d' ' -f1)"
assert_eq "USAGE_AWARE_DIR overrides both" "/x /x /x" "$(dirs USAGE_AWARE_DIR=/x CLAUDE_CONFIG_DIR=/h/.claude-alt)"

echo "accounts don't see each other's data"
home=$(mktemp -d)
run() { env -u USAGE_AWARE_DIR HOME="$home" "$@"; }
mkdir -p "$home/.claude/usage-aware" "$home/.claude-alt/usage-aware"
printf '{"updated_at":%d,"five_hour":{"used_percentage":10,"resets_at":%d}}\n' "$(date +%s)" "$(( $(date +%s) + 3600 ))" \
  >"$home/.claude/usage-aware/state.json"
printf '{"updated_at":%d,"five_hour":{"used_percentage":70,"resets_at":%d}}\n' "$(date +%s)" "$(( $(date +%s) + 3600 ))" \
  >"$home/.claude-alt/usage-aware/state.json"
assert_contains "default account reads its own" "5h: 90% left" "$(run env -u CLAUDE_CONFIG_DIR bash "$SCRIPTS/usage-status.sh")"
assert_contains "alt account reads its own" "5h: 30% left" "$(run CLAUDE_CONFIG_DIR="$home/.claude-alt" bash "$SCRIPTS/usage-status.sh")"
run CLAUDE_CONFIG_DIR="$home/.claude-alt" bash "$SCRIPTS/usage-plan.sh" begin S1 test >/dev/null
assert_true "alt plan drafts under the alt dir" test -f "$home/.claude-alt/usage-aware/plans/S1.draft.json"

echo "inject-policy: alt account syncs scripts to the shared path"
plugin=$(mktemp -d); cp -r "$ROOT/scripts" "$plugin/"
ctx=$(echo '{"session_id":"S1"}' | run CLAUDE_CONFIG_DIR="$home/.claude-alt" CLAUDE_PLUGIN_ROOT="$plugin" bash "$SCRIPTS/inject-policy.sh" \
  | jq -r .hookSpecificOutput.additionalContext)
assert_true "scripts synced to ~/.claude/usage-aware" test -x "$home/.claude/usage-aware/usage-status"
assert_true "no scripts in the alt data dir" test ! -e "$home/.claude-alt/usage-aware/usage-status"
assert_contains "Claude is given the fixed path" "~/.claude/usage-aware/usage-status S1" "$ctx"
assert_contains "with the alt account's usage" "5h: 30% left" "$ctx"
assert_contains "synced copy reads the alt data" "5h: 30% left" \
  "$(run CLAUDE_CONFIG_DIR="$home/.claude-alt" "$home/.claude/usage-aware/usage-status")"

finish
