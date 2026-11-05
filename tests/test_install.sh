#!/usr/bin/env bash
# install.sh
source "$(dirname "$0")/helpers.sh"
IN="$SCRIPTS/install.sh"
settings=$(mktemp)
snippet() { sed -n '/^{$/,/^}$/p' <<<"$1"; }

echo "install: syncs and prints the permission rule only"
setup_dir; echo '{"statusLine":{"type":"command","command":"x"}}' >"$settings"; cp "$settings" "$settings.orig"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_true "synced usage-status" test -x "$USAGE_AWARE_DIR/usage-status"
assert_true "synced ua-lib.sh" test -f "$USAGE_AWARE_DIR/ua-lib.sh"
assert_true "settings file not modified" cmp -s "$settings" "$settings.orig"
snip=$(snippet "$out")
assert_eq "snippet is valid JSON" 0 "$(jq -e . <<<"$snip" >/dev/null; echo $?)"
assert_eq "no statusLine in snippet" null "$(jq -r .statusLine <<<"$snip")"
assert_eq "permission rule" "Bash($USAGE_AWARE_DIR/usage-status *)" "$(jq -r '.permissions.allow[0]' <<<"$snip")"

echo "install: rule already present"
setup_dir; jq -n --arg r "Bash($USAGE_AWARE_DIR/usage-status *)" '{permissions:{allow:[$r]}}' >"$settings"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN")
assert_contains "says nothing to add" "already" "$out"
assert_eq "no snippet printed" "" "$(snippet "$out")"

echo "install: leftover usage-aware statusLine is flagged"
setup_dir; jq -n '{statusLine:{type:"command",command:"~/.claude/usage-aware/tap-statusline"}}' >"$settings"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN")
assert_contains "tells user to remove it" "remove" "$out"

echo "install: default dir uses literal ~/ in snippet"
fakehome=$(mktemp -d); echo '{}' >"$settings"
out=$(env -u USAGE_AWARE_DIR HOME="$fakehome" CLAUDE_SETTINGS="$settings" bash "$IN")
assert_eq "~ permission rule" "Bash(~/.claude/usage-aware/usage-status *)" "$(snippet "$out" | jq -r '.permissions.allow[0]')"
assert_true "synced under HOME" test -x "$fakehome/.claude/usage-aware/usage-status"

echo "install: missing jq"
fake=$(mktemp -d)
for b in bash cat cmp cp chmod date dirname mkdir mktemp mv readlink rm sed; do ln -s "$(command -v $b)" "$fake/$b"; done
setup_dir
out=$(PATH="$fake" CLAUDE_SETTINGS="$settings" "$fake/bash" "$IN" 2>&1); rc=$?
assert_true "non-zero exit" test "$rc" -ne 0
assert_contains "install hint" "jq" "$out"
assert_true "nothing synced" test ! -e "$USAGE_AWARE_DIR/usage-status"

finish
