---
description: Set this session's usage plan from a prompt (or show / clear it)
argument-hint: <what you want> | show | clear | add <more>
allowed-tools: Bash(~/.claude/usage-aware/usage-plan *), Bash(bash:*)
---
<usage-plan-context>
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-plan.sh" context "${CLAUDE_SESSION_ID}"`
</usage-plan-context>

<user-request>
$ARGUMENTS
</user-request>

You manage this session's usage plan: rules whose conditions a script checks against live usage measurements, so you're handed each instruction exactly when it applies. Session id: `${CLAUDE_SESSION_ID}`.

Do one of these, depending on the request:

- **Empty or `show`:** run `~/.claude/usage-aware/usage-plan show ${CLAUDE_SESSION_ID}` and reply with its output verbatim, nothing else.
- **`clear`:** run `~/.claude/usage-aware/usage-plan clear ${CLAUDE_SESSION_ID}` and reply with its output verbatim, nothing else.
- **Anything else** is the user's intent for a plan. Translate it into rules and save them (below). If it starts with `add`, keep the current plan's rules and add to them. Otherwise replace the plan.

## Writing the plan

Save it in one command, with the JSON on stdin:

```
~/.claude/usage-aware/usage-plan set ${CLAUDE_SESSION_ID} <<'PLAN'
{"source": "<the user's request, verbatim>", "rules": [ ... ]}
PLAN
```

Each rule is `{"id": "short-kebab-name", "when": "<condition>", "do": "<instruction to yourself>"}`, with two optional fields:
- `"on": "subagent"`: deliver the rule only right before you dispatch a subagent, instead of with every prompt.
- `"once": true`: deliver the rule only when its condition first becomes true. It re-arms if the condition turns false again.

A condition is `always`, or comparisons joined with `and` / `or` (no parentheses; `and` binds tighter). A comparison is `<variable> <op> <number>`, where `<op>` is one of `<`, `<=`, `>`, `>=`, `==`, and the number may end in `k` or `M`, e.g. `tokens_left < 5M and reset_5h_min > 30`. A comparison on a variable that's currently unset is false.

| Variable | Meaning |
|---|---|
| `pct_5h`, `pct_7d`, `pct_spend` | % left in the window |
| `tok_5h`, `tok_7d` | estimated tokens left in the window |
| `tokens_left` | the smaller of `tok_5h` and `tok_7d` |
| `steps` | `tokens_left` ÷ current context (about one model call each) |
| `context` | current context size, in tokens |
| `reset_5h_min`, `reset_7d_min` | minutes until the window resets |
| `runway_5h_min`, `runway_7d_min` | minutes until the window runs out at its average rate so far |
| `out_before_reset_5h`, `out_before_reset_7d` | 1 if the window runs out before it resets at that rate, else 0 |
| `age_min` | age of the usage reading, in minutes |

Guidelines:
- Use the smallest set of rules that covers the request, at most 12. Each `do` is under 300 characters, concrete, and says what to do, not why.
- Use the user's own numbers. Don't invent thresholds they didn't ask for. If a number is needed and the request doesn't give one, ask instead of guessing.
- Intent that no measurement can trigger (habits like "estimate each task's tokens before dispatching subagents") becomes an `always` rule, with `"on": "subagent"` when it's about subagents.
- The current measurements above show the scale (for example, how many tokens are left now). Use them to sanity-check numbers, but not to change what the user asked for.
- If `set` reports errors, fix the JSON and run it again.

After saving, reply with `set`'s output, then one line on anything you interpreted or couldn't express as a rule.
