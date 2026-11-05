# Minimal assert helpers. Source from a test file.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
PASS=0 FAIL=0

setup_dir() {  # fresh isolated runtime dir per test
  export USAGE_AWARE_DIR; USAGE_AWARE_DIR="$(mktemp -d)"
  unset USAGE_AWARE_NEXT
}

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

assert_eq() { # name expected actual
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected: $2 | got: $3"; }
assert_contains() { # name needle haystack
  [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2 | got: $3"; }
assert_not_contains() {
  [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "unexpected: $2 | got: $3"; }
assert_true() { # name cmd...
  local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n" "command failed: $*"; fi; }
assert_false() { # name cmd...
  local n="$1"; shift; if "$@"; then bad "$n" "command succeeded: $*"; else ok "$n"; fi; }

finish() { printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"; [[ $FAIL -eq 0 ]]; }
