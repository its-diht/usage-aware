#!/usr/bin/env bash
# Run every tests/test_*.sh, then the mod's tests; non-zero exit if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do bash "$t" || rc=1; done
if command -v claude >/dev/null; then
  echo "mod tests (claude plugin test):"
  out="$(claude plugin test .. 2>&1)" || rc=1
  tail -4 <<<"$out"
else
  echo "mod tests skipped: claude CLI not found"
fi
exit $rc
