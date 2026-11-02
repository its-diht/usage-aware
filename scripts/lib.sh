# usage-aware shared library. Sourced, never executed.
# Override USAGE_AWARE_DIR to relocate runtime data (tests use this).
UA_DIR="${USAGE_AWARE_DIR:-$HOME/.claude/usage-aware}"
UA_STATE="$UA_DIR/state.json"
UA_CONFIG="$UA_DIR/config.json"
UA_DEFAULT_CONSERVE=50   # CONSERVE when the tighter window has < this % left
UA_DEFAULT_WRAPUP=20     # WRAP-UP  when the tighter window has < this % left
UA_STALE_SECS=1800
UA_SYNC_FILES=(tap-statusline usage-status lib.sh)

ua_have_jq() { command -v jq >/dev/null 2>&1; }

# Atomic write: ua_write_atomic <dest> <content>
ua_write_atomic() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# Echo "conserve wrapup" from config.json, falling back to defaults.
ua_thresholds() {
  local c w
  if [[ -f "$UA_CONFIG" ]] && read -r c w < <(jq -r '"\(.conserve // empty) \(.wrapup // empty)"' "$UA_CONFIG" 2>/dev/null) \
     && [[ "$c" =~ ^[0-9]+$ && "$w" =~ ^[0-9]+$ ]]; then
    echo "$c $w"
  else
    echo "$UA_DEFAULT_CONSERVE $UA_DEFAULT_WRAPUP"
  fi
}

# jq helper: human duration (1d2h, 1h50m, 5m, 40s)
UA_JQ_DUR='def dur: (if . < 0 then 0 else floor end) as $s
  | if $s >= 86400 then "\($s/86400|floor)d\($s%86400/3600|floor)h"
    elif $s >= 3600 then "\($s/3600|floor)h\($s%3600/60|floor)m"
    elif $s >= 60 then "\($s/60|floor)m"
    else "\($s)s" end;'
