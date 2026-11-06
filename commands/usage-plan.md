---
description: Create this session's usage plan through a short Q&A (or add to, show, clear it)
argument-hint: create [idea] | add [idea] | show | clear
allowed-tools: Bash(~/.claude/usage-aware/usage-plan *), AskUserQuestion
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
- **`create [idea]`:** interview the user (below), then save a new plan that replaces the current one. Any text after `create` is their starting idea.
- **`add [idea]`:** the same interview, but focused on what to add. Keep the current plan's rules.
- **Anything else:** reply only with: `Usage: /usage-aware:usage-plan create [idea] | add [idea] | show | clear`. Don't build a plan from it.

## Interview (2–3 rounds)

Use the AskUserQuestion tool for every round. Each round asks 1–4 questions, and each question offers 2–4 concrete options (the user can always type their own answer). Don't ask about anything the starting idea already answers. Stop as soon as you can write every rule without guessing.

1. **Goals.** What the plan should do, for example: stop and write a handoff at some point, get a warning first, pace work so the 5h or 7d window lasts until it resets, or habits such as estimating each subagent's cost before dispatching it. Use multiSelect here.
2. **Numbers and actions.** For each goal that needs a threshold, ask for the number and offer options sized from the current measurements above (for example, if 12M tokens are left, offer 3M / 5M / 8M). Ask what to do once it triggers (for example: hand off and stop, ask before new work, or switch to small steps with no subagents).
3. **Confirm (only if something is still ambiguous, or the plan has 3 or more rules).** Show the rules you'll save as plain lines (`when … → do …`), and offer Save / Change something. If the user picks Change, apply their notes, then save without another round.

Never invent a threshold the user didn't choose or type.

## Writing the plan

Build it with one shell command per step. Don't write JSON or files yourself; the script does that. Run each command as its own Bash call, with the literal path and session id: no shell variables, `&&`, `;` or line continuations. Only plain single commands are pre-approved.
1. `~/.claude/usage-aware/usage-plan begin ${CLAUDE_SESSION_ID} "<one-sentence summary of what the user chose>"` starts a draft. For `add`, use `begin ${CLAUDE_SESSION_ID} --add "<summary>"` to keep the current rules.
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
- Use the smallest set of rules that covers what the user chose, at most 12. Each `do` is under 300 characters, concrete, and says what to do, not why.
- Use only the numbers the user chose in the interview.
- Intent that no measurement can trigger (habits like "estimate each task's tokens before dispatching subagents") becomes an `always` rule, with `--subagent` when it's about subagents.
- The current measurements above show the scale (for example, how many tokens are left now). Use them to sanity-check numbers, but not to change what the user asked for.
- If `rule` or `commit` reports errors, fix that rule with another `rule` command (same id), then `commit` again.

After saving, reply with `commit`'s output. If anything the user asked for couldn't be expressed as a rule, add one line saying what.
