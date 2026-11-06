---
description: Set this session's usage plan from a prompt (or show / clear it)
argument-hint: <what you want> | show | clear | add <more>
allowed-tools: Bash(~/.claude/usage-aware/usage-plan *)
---
<usage-plan-context>
!`~/.claude/usage-aware/usage-plan context ${CLAUDE_SESSION_ID}`
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

Build it with one shell command per step. Don't write JSON or files yourself; the script does that. Run each command as its own Bash call, with the literal path and session id: no shell variables, `&&`, `;` or line continuations. Only plain single commands are pre-approved.
1. `~/.claude/usage-aware/usage-plan begin ${CLAUDE_SESSION_ID} "<the user's request, verbatim>"` starts a draft. For an `add` request, use `begin ${CLAUDE_SESSION_ID} --add "<request>"` to keep the current rules.
2. For each rule, run `~/.claude/usage-aware/usage-plan rule ${CLAUDE_SESSION_ID} <id> "<when>" "<do>" [--subagent] [--once]`. Use one command per rule and double-quote `when` and `do`. Reusing an id replaces that rule.
3. Run `~/.claude/usage-aware/usage-plan commit ${CLAUDE_SESSION_ID}`. It validates the draft and saves it as the plan.

`id` is a short kebab-case name. `when` is the condition and `do` is the one-line instruction to yourself. Two optional flags:
- `--subagent`: the rule is about dispatching subagents. It is listed under its own "when you dispatch a subagent" header instead of as a general instruction.
- `--once`: deliver the rule only when its condition first becomes true. It re-arms if the condition turns false again.

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
- Intent that no measurement can trigger (habits like "estimate each task's tokens before dispatching subagents") becomes an `always` rule, with `--subagent` when it's about subagents.
- The current measurements above show the scale (for example, how many tokens are left now). Use them to sanity-check numbers, but not to change what the user asked for.
- If `rule` or `commit` reports errors, fix that rule with another `rule` command (same id), then `commit` again.

After saving, reply with `commit`'s output, then one line on anything you interpreted or couldn't express as a rule.
