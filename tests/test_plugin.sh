#!/usr/bin/env bash
# Plugin wiring: manifests parse, hook/command script references exist.
source "$(dirname "$0")/helpers.sh"
echo "plugin wiring"
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  assert_true "$j parses" jq -e . "$ROOT/$j" >/dev/null
done
while read -r s; do
  assert_true "hook script exists: $s" test -f "$ROOT/$s"
done < <(jq -r '.hooks[][].hooks[].command | capture("ROOT}/(?<p>[^\"]+)").p' "$ROOT/hooks/hooks.json")
assert_eq "SessionStart matcher" "startup|resume|clear|compact|fork" "$(jq -r '.hooks.SessionStart[0].matcher' "$ROOT/hooks/hooks.json")"
cmdmd="$(cat "$ROOT/commands/usage-plan.md")"
assert_contains "usage-plan command reads context with the session id" '!`~/.claude/usage-aware/usage-plan context ${CLAUDE_SESSION_ID}`' "$cmdmd"
assert_contains "context block is covered by allowed-tools" 'Bash(~/.claude/usage-aware/usage-plan *)' "$cmdmd"
assert_true "user request never reaches a shell line" bash -c '! grep -q "^!.*ARGUMENTS" "$0"' "$ROOT/commands/usage-plan.md"
assert_true "thresholds command removed" test ! -e "$ROOT/commands/thresholds.md"
assert_eq "PreToolUse matcher" "Agent|Task" "$(jq -r '.hooks.PreToolUse[0].matcher' "$ROOT/hooks/hooks.json")"
assert_true "SessionEnd hook wired" jq -e '.hooks.SessionEnd[0].hooks[0].command | test("carry-plan.sh")' "$ROOT/hooks/hooks.json"
for f in "$ROOT"/scripts/*.sh; do
  assert_true "syntax ok: $(basename "$f")" bash -n "$f"
done
assert_eq "hooks.json names the mod module" "./register.tsx" "$(jq -r '.modules[0]' "$ROOT/hooks/hooks.json")"
assert_true "mod module exists" test -f "$ROOT/hooks/register.tsx"
assert_eq "plugin.json types contract" "./types/index.d.ts" "$(jq -r .types "$ROOT/.claude-plugin/plugin.json")"
assert_eq "versions match" "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" "$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")"
finish
