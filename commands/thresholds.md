---
description: Show or set usage-aware mode thresholds (e.g. 60 25, or reset)
argument-hint: "[<conserve> <wrapup> | reset]"
allowed-tools: Bash(bash:*)
---
<usage-aware-output>
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/set-thresholds.sh" $ARGUMENTS`
</usage-aware-output>

Reply with exactly the text inside <usage-aware-output>, unchanged, and nothing else: no preamble, no commentary, no suggestions, no tool calls.
