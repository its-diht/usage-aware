#!/usr/bin/env bash
# Backs /usage-aware:thresholds. Args: none | reset | <conserve> <wrapup>
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() {
  cat <<USAGE
Usage:
  /usage-aware:thresholds            show current thresholds
  /usage-aware:thresholds 60 25      CONSERVE below 60% left, WRAP-UP below 25% left
  /usage-aware:thresholds reset      restore defaults ($UA_DEFAULT_CONSERVE / $UA_DEFAULT_WRAPUP)
Values are integers 0-100, and WRAP-UP must be lower than CONSERVE. Nothing was changed.
USAGE
  exit 0
}
show() {
  local c w tag=""
  read -r c w < <(ua_thresholds)
  [[ -f "$UA_CONFIG" ]] || tag=" (defaults)"
  echo "usage-aware thresholds$tag: CONSERVE below ${c}% left, WRAP-UP below ${w}% left."
}
save() {
  ua_write_atomic "$UA_CONFIG" "{\"conserve\":$1,\"wrapup\":$2}" || { echo "usage-aware: could not write $UA_CONFIG"; exit 0; }
  show; echo "Applies from the next prompt."
  exit 0
}

ua_have_jq || { echo "usage-aware: jq not found, plugin inactive. Install jq (e.g. sudo apt install jq)."; exit 0; }

# $ARGUMENTS may arrive as one string; re-split on whitespace.
read -r -a args <<<"$*"
case ${#args[@]} in
  0) show ;;
  1) [[ ${args[0]} == reset ]] && save "$UA_DEFAULT_CONSERVE" "$UA_DEFAULT_WRAPUP"; usage ;;
  2) c=${args[0]} w=${args[1]}
     [[ $c =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]] || usage
     c=$((10#$c)) w=$((10#$w))
     ((c <= 100 && w < c)) || usage
     save "$c" "$w" ;;
  *) usage ;;
esac
exit 0
