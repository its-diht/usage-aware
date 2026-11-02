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
assert_contains "command calls set-thresholds" 'scripts/set-thresholds.sh" $ARGUMENTS' "$(cat "$ROOT/commands/thresholds.md")"
for f in "$ROOT"/scripts/*.sh; do
  assert_true "syntax ok: $(basename "$f")" bash -n "$f"
done
assert_eq "hooks.json names the mod module" "./register.tsx" "$(jq -r '.modules[0]' "$ROOT/hooks/hooks.json")"
assert_true "mod module exists" test -f "$ROOT/hooks/register.tsx"
assert_eq "plugin.json types contract" "./types/index.d.ts" "$(jq -r .types "$ROOT/.claude-plugin/plugin.json")"
assert_eq "versions match" "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" "$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")"
finish
