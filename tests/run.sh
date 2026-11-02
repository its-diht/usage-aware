#!/usr/bin/env bash
# Run every tests/test_*.sh; non-zero exit if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do bash "$t" || rc=1; done
exit $rc
