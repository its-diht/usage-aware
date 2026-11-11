# usage-aware v0.4: usage facts and per-session usage plans (spec)

Status: implemented in v0.4.0 (2026-11-05). Since v0.5.0, data is per account (`$CLAUDE_CONFIG_DIR/usage-aware` for a non-default config dir), context and cost per step are per session (`contexts/<session_id>.json`), `steps` is cost-based, and a recent-rate runway was added; the measurement rows below are updated for that, and the README is the current reference. Open questions resolved: `${CLAUDE_SESSION_ID}` is substituted in command files; PreToolUse `additionalContext` reaches the model; plugin commands need the full `/usage-aware:usage-plan` name; `/clear` changes the session id (SessionEnd reason `clear`), so the plan is carried via a pointer keyed by working directory; forks start without a plan.

## Goal

Replace the three fixed modes (NORMAL / CONSERVE / WRAP-UP) with two things:

1. **Facts.** Every prompt gets plain usage measurements, with no advice attached. They include anything simple code can compute without using any usage.
2. **A plan the user writes.** `/usage-plan <prompt>` has the model turn the user's free-form intent into a small rule file for the current session. Each rule has a machine-checkable condition, and a script injects a rule only while its condition holds.

The plugin stops deciding what Claude should do. The user decides, and the plugin keeps the numbers current and hands the right instruction to Claude at the right time.

## 1. Facts

### Usage line

The UserPromptSubmit hook and `usage-status` produce the same line:

```
[usage] 5h: 29% left (~17M tok), resets 30m · 7d: 46% left (~284M tok), resets 5d9h, at recent rate out in 1d2h · ≈105 steps (~$0.36/step) · 1m old
```

### Measurements

All of these come from state.json and the clock. Each is also exposed as a variable that conditions can use (§2.3).

| Variable | Meaning | Source |
|---|---|---|
| `pct_5h`, `pct_7d`, `pct_spend` | % left in each window (100 once the reset time has passed) | `used_percentage` |
| `tok_5h`, `tok_7d` | estimated tokens left in each window | % left × `tokens_per_pct` (from v0.3) |
| `tokens_left` | min of `tok_5h` and `tok_7d`; unset if neither has an estimate | |
| `steps` | dollars left / this session's cost per main-loop call; `tokens_left` / `context_tokens` until known | `usd_per_pct`, `usd_per_step` (v0.5) |
| `context` | current context size, in tokens | `context_tokens` |
| `reset_5h_min`, `reset_7d_min` | minutes until each window resets | `resets_at` |
| `runway_5h_min`, `runway_7d_min` | minutes until the window runs out at its average rate so far; unset before 10% of the window has elapsed | the existing pace math |
| `runway_recent_5h_min`, `runway_recent_7d_min` | minutes until the window runs out at its rate over about the last hour (unset while idle or with under 15 minutes of history) | the window's `recent` history (v0.5) |
| `out_before_reset_5h`, `out_before_reset_7d` | 1 if the runway is shorter than the time to reset, else 0 | |
| `age_min` | age of the data, in minutes | `updated_at` |

These display rules carry over from v0.3:
- A variable is unset when its data is missing (no calibration yet, an API-key account, or the window is absent). A condition that uses an unset variable is false.
- "usage unknown (…)" when there's no state at all.
- `stale` after 30 minutes.
- `(limit reached)` at 0%.

### What gets removed

- The modes, the mode rules and the `→ …` line.
- The `(pace: …)` and `(… resets soon)` adjustments. "Out before reset" is now a fact and a variable, not a mode bump.
- `/usage-aware:thresholds`, `set-thresholds.sh` and `config.json`. Leave existing config files in place and ignore them.

## 2. Usage plans

### 2.1 Scope: one plan per session

Plans are stored at `~/.claude/usage-aware/plans/<session_id>.json`.

- **Hooks** read `session_id` from their stdin JSON.
- **`usage-status`**: when Claude runs it from Bash, it doesn't know the session. The usage line therefore tells Claude its own command, `~/.claude/usage-aware/usage-status <session_id>`. The existing permission rule `Bash(~/.claude/usage-aware/usage-status *)` already allows the argument.
- **Resume:** the session id is unchanged, so the plan carries over.
- **`/clear`, compact and fork:** see Open question 1.
- **Cleanup:** SessionStart prunes plan files that haven't been modified in 14 days, like the session cost files.

### 2.2 `/usage-plan`

The command lives in `commands/usage-plan.md` and is invoked as `/usage-aware:usage-plan`. Open question 3 covers whether the short `/usage-plan` form works.

| Form | Effect |
|---|---|
| `/usage-plan <prompt>` | The model writes or replaces this session's plan from the prompt, validates it (§2.4), and replies with a short summary of the rules. |
| `/usage-plan` | Shows the current plan in a readable form, plus which rules are active right now. |
| `/usage-plan clear` | Deletes this session's plan. |
| `/usage-plan add <prompt>` | Adds rules to the existing plan instead of replacing it. |

The command body gives the model three things:
- the file path, with the session id substituted (Open question 2);
- the schema and the variable table;
- the instruction to translate the user's intent into the smallest set of rules that covers it. Anything that can't be expressed as a condition goes in as an `always` rule. Don't invent thresholds the user didn't ask for. Ask instead if the intent is unclear.

`show` and `clear` are plain bash via `` !`…` `` with a verbatim reply, like the current thresholds command, so they don't use the model beyond the reply.

### 2.3 Plan file format

The file is JSON, so jq can read it and bash needs no YAML parser.

```json
{
  "version": 1,
  "source": "try to predict token usage of each task before dispatching subagents, aim to stop at ~5M remaining tokens, in which case create a handoff doc",
  "created_at": 1793764476,
  "rules": [
    { "id": "estimate-subagents", "when": "always", "on": "subagent",
      "do": "Before dispatching a subagent, estimate its token cost (steps × its expected context) and state it." },
    { "id": "handoff", "when": "tokens_left < 5M",
      "do": "Finish the current unit, write HANDOFF.md (done / next / open issues), then stop and report." },
    { "id": "warn", "when": "tokens_left < 8M", "once": true,
      "do": "Tell the user you're within ~3M tokens of the handoff point." }
  ]
}
```

| Field | Rules |
|---|---|
| `when` | `always`, or comparisons joined by `and` / `or`, with no parentheses (`and` binds tighter). A comparison is `<var> <op> <number>`, where `<op>` is one of `< <= > >= ==`. A number may end in `k` or `M` (×1e3 / ×1e6). Examples: `pct_5h < 20`, `tokens_left < 5M and reset_5h_min > 30`, `out_before_reset_7d == 1`. |
| `on` | When the rule is delivered. `prompt` (the default) means every prompt and every `usage-status` run. `subagent` means only right before a subagent is dispatched (§2.5). |
| `once` | If true, the rule is injected only on the prompt where its condition becomes true, not again while it stays true. It is re-armed when the condition turns false. Per-rule state is kept in `plans/<session_id>.state.json`. |
| `do` | The instruction text, at most about 300 characters, so the injected block stays small. |
| `source` | The user's original prompt, kept so a later `/usage-plan add` has context. |

Limits: at most 12 rules per plan.

### 2.4 Evaluation and validation

- **Evaluator:** `scripts/plan-eval.sh <session_id> [prompt|subagent]` builds the variable table (§1) and evaluates every `when` in a single jq program. It prints the active rules as `- [id] do-text`.
- **Validator:** `plan-eval.sh --check <file>`. The model runs it right after writing the plan. It rejects unknown variables, bad operators or numbers, more than 12 rules, and a missing `do`, with one error per line. The command tells the model to fix the file and re-check until it passes.
- **At runtime:** an invalid plan is ignored. The usage line then says `plan: invalid (run /usage-plan to fix)`.

Time budget: still under 100 ms for status plus evaluation, the same as `usage-status` today.

### 2.5 Delivery

| When | Hook | What Claude gets |
|---|---|---|
| Session start | SessionStart | The facts glossary (what each number means, how the token and steps estimates work, their caveats), the per-session `usage-status <sid>` command, and the plan's `always`/`prompt` rules if a plan exists, which it does on resume. |
| Every prompt | UserPromptSubmit | The usage line, plus `Usage plan (active):` followed by the active `prompt` rules. Nothing extra when there's no plan or no rule is active. |
| Mid-turn | Claude runs `usage-status <sid>` | The same as every prompt. The glossary tells Claude to run it before major steps during long autonomous work. |
| Before a subagent | PreToolUse, matcher `Agent\|Task` | The active `subagent` rules plus the usage line, sent as additional context. Silent if none are active. Never blocks the tool. |

With no plan at all, Claude gets facts only. The glossary's one standing note: "No usage plan is set. Use your own judgment, and size work against the token/steps estimates."

## 3. Unchanged from v0.3

- **The bundled mod:** state.json, the calibration, cost pooling across sessions, the bars above the prompt, and `/usage-color`.
- **The runtime directory**, file syncing, `install.sh`, and the jq-missing message.

## 4. Tests

- **`test_status.sh`:** rewrite the line assertions for the facts-only format. Each variable gets a case, including unset variables, a reset that has already passed, and stale data.
- **`test_plan.sh` (new):**
  - condition parsing: every operator, the `k`/`M` suffixes, `and`/`or` precedence, unknown variables, an unset variable evaluating to false, `always`;
  - `once` transitions: fires, stays quiet, re-arms;
  - `on: subagent` filtering;
  - validation errors;
  - the 12-rule limit;
  - a missing or invalid file;
  - the time budget.
- **`test_hooks.sh`:** SessionStart with and without a plan; UserPromptSubmit injecting the active rules; PreToolUse output shape and staying silent; pruning of old plan files.
- **`test_plugin.sh`:** wiring for the new command and the PreToolUse hook; the thresholds command is gone.
- **Live:** run `/usage-plan` with the example prompt; check the file and the validator; lower a threshold in the file so a rule fires; dispatch a subagent and confirm the `subagent` rule arrives.

## 5. Open questions (verify before building)

1. **Session id across `/clear`, compact and fork.** Does SessionStart get a new `session_id` in these cases? If it does, copy the previous plan forward. That needs the previous id: fork may expose a parent id, and `/clear` may not expose one. The fallback is to keep the plan with the old id and have SessionStart offer "previous plan found: run /usage-plan to restore".
2. **Session id inside a command.** Can `commands/usage-plan.md` get it, for example through `${CLAUDE_SESSION_ID}` substitution or an environment variable in `` !`…` ``? If not, the mod can register `/usage-plan` instead and pass the id along with the prompt.
3. **Short name.** Can a plugin command be typed as `/usage-plan`, or only as `/usage-aware:usage-plan`?
4. **PreToolUse context.** Does a PreToolUse hook's `additionalContext` reach the model for the Agent tool? If not, `on: subagent` rules fall back to being delivered every prompt, with "(when dispatching subagents)" prepended.
5. **Plan template.** Should a plan written in one session be reusable as a starting template in the next, for example `/usage-plan reuse`? It's out of scope for v0.4 but cheap to add later.

## 6. Version

0.4.0 is a breaking change, since the modes and the thresholds command are removed. Add a README section on migrating from 0.3.
