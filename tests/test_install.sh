#!/usr/bin/env bash
# install.sh
source "$(dirname "$0")/helpers.sh"
IN="$SCRIPTS/install.sh"
settings=$(mktemp)

echo "install: no existing statusLine"
setup_dir; echo '{"env":{}}' >"$settings"; cp "$settings" "$settings.orig"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN"); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_true "synced usage-status" test -x "$USAGE_AWARE_DIR/usage-status"
assert_true "synced tap-statusline" test -x "$USAGE_AWARE_DIR/tap-statusline"
assert_true "settings file not modified" cmp -s "$settings" "$settings.orig"
snip=$(sed -n '/^{$/,/^}$/p' <<<"$out")   # the printed JSON snippet
assert_eq "snippet is valid JSON" 0 "$(jq -e . <<<"$snip" >/dev/null; echo $?)"
assert_eq "plain statusline command" "$USAGE_AWARE_DIR/tap-statusline" "$(jq -r .statusLine.command <<<"$snip")"
assert_eq "permission rule" "Bash($USAGE_AWARE_DIR/usage-status *)" "$(jq -r '.permissions.allow[0]' <<<"$snip")"

echo "install: wraps existing statusLine (with quotes)"
setup_dir
jq -n '{statusLine:{type:"command",command:"bash ~/my status.sh --fmt '\''%s'\''"}}' >"$settings"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN")
cmd=$(sed -n '/^{$/,/^}$/p' <<<"$out" | jq -r .statusLine.command)
assert_contains "uses USAGE_AWARE_NEXT" "USAGE_AWARE_NEXT=" "$cmd"
# Prove the shell quoting round-trips: eval the prefix and read the var back.
next=$(bash -c "${cmd% *}"' bash -c '\''printf %s "$USAGE_AWARE_NEXT"'\''')
assert_eq "old command round-trips" "bash ~/my status.sh --fmt '%s'" "$next"

echo "install: already wrapped"
setup_dir; jq -n '{statusLine:{type:"command",command:"USAGE_AWARE_NEXT='\''x'\'' ~/.claude/usage-aware/tap-statusline"}}' >"$settings"
out=$(CLAUDE_SETTINGS="$settings" bash "$IN")
assert_contains "detects existing setup" "already" "$out"

echo "install: default dir uses literal ~/ in snippets"
fakehome=$(mktemp -d); echo '{}' >"$settings"
out=$(env -u USAGE_AWARE_DIR HOME="$fakehome" CLAUDE_SETTINGS="$settings" bash "$IN")
snip=$(sed -n '/^{$/,/^}$/p' <<<"$out")
assert_eq "~ statusline path" "~/.claude/usage-aware/tap-statusline" "$(jq -r .statusLine.command <<<"$snip")"
assert_eq "~ permission rule" "Bash(~/.claude/usage-aware/usage-status *)" "$(jq -r '.permissions.allow[0]' <<<"$snip")"
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
