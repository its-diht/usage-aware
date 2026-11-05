#!/usr/bin/env bash
# SessionEnd hook: on /clear, leave a pointer so the next session in this directory keeps the plan.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
input="$(cat)"
ua_have_jq || exit 0
[[ "$(jq -r '.reason // ""' <<<"$input")" == clear ]] || exit 0
sid="$(jq -r '.session_id // ""' <<<"$input")"
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ && -f "$UA_PLANS/$sid.json" ]] || exit 0
cwd="$(jq -r '.cwd // ""' <<<"$input")"
ua_write_atomic "$UA_PLANS/.carry-$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)" "$sid"
exit 0
