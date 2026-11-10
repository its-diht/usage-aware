# usage-aware

Keeps Claude Code aware of your remaining **5-hour** and **7-day** plan usage, as plain facts on every prompt, and lets you tell it what to do about usage with a **usage plan** written in your own words.

```
[usage] 5h: 34% left (~4.1M tok), resets 1h50m, at recent rate out in 1h18m · 7d: 80% left (~120M tok), resets 3d11h · ≈48 steps (~$0.36/step) · 40s old
Usage plan (active):
- [handoff] Finish the current unit, write HANDOFF.md (done / next / open issues), then stop and report.
```

## Requirements

- **bash** and **jq** (`sudo apt install jq` / `sudo pacman -S jq` / `brew install jq`). Developed and tested on Linux.
- A **Claude subscription** (Pro, Max, …) or a spend-limited Claude gateway. Claude Code only reports rate limits to these; API-key accounts see "usage unknown".
- **Claude Code with plugin mods** (function hooks, early access): the bundled mod is the data source. If the mod can't load, Claude still gets the hooks' output, and you're told once per session that data isn't updating.
- The **Claude Code CLI**. UserPromptSubmit context has been reported not to reach the model in the VS Code extension.

## Install

1. Load the plugin, either from GitHub:
   ```sh
   claude plugin marketplace add its-diht/usage-aware
   claude plugin install usage-aware@usage-aware
   ```
   or from a local checkout, by adding its path to `CLAUDE_CODE_PLUGIN_DIRS` (`:`-separated) in the `env` block of `~/.claude/settings.json`, or with `claude --plugin-dir <path>`.
2. Optional, so Claude's mid-turn checks don't stop for approval: add this permission rule to `~/.claude/settings.json` (for an account with its own `CLAUDE_CONFIG_DIR`, to that directory's `settings.json`; the path in the rule stays the same).
   ```json
   { "permissions": { "allow": ["Bash(~/.claude/usage-aware/usage-status *)"] } }
   ```
   `bash scripts/install.sh` prints the same snippet, tailored to your settings. It never edits the file.
3. Restart Claude Code. Usage appears after Claude's first response in a session.

No statusline setup is needed. If you used v0.1's `tap-statusline`, remove that `statusLine` entry (install.sh flags it).

## Usage plans

By default Claude just gets the numbers and uses its own judgment. To decide yourself how it should handle usage, set a plan for the session:

```
/usage-aware:usage-plan create
```

Claude asks you two or three rounds of multiple-choice questions: what the plan should do, which thresholds to use (with options sized from your current usage), and, for larger plans, a final check of the rules. You can add a starting idea, e.g. `create stop at 5M tokens left and write a handoff`, and Claude will skip questions it already answers. Your answers become a few rules, each with a condition that a script checks against live measurements:

```
  ○ inactive  [estimate-subagents] when always, before subagents
      → Before dispatching a subagent, estimate its token cost (steps × its expected context) and state it.
  ○ inactive  [handoff] when tokens_left < 5M
      → Finish the current unit, write HANDOFF.md (done / next / open issues), then stop and report.
```

A rule is handed to Claude only while its condition holds, on every prompt and when Claude checks usage mid-turn. Rules marked "before subagents" are listed under their own header, so Claude applies them before it dispatches a subagent, and they are repeated when the subagent is dispatched. Checking the conditions is plain `jq`, so it uses no usage.

| Command | Effect |
|---|---|
| `/usage-aware:usage-plan create [idea]` | Build this session's plan through a short Q&A (replaces the old one) |
| `/usage-aware:usage-plan add [idea]` | The same Q&A, adding rules to the plan |
| `/usage-aware:usage-plan` or `… show` | Show the plan, each rule marked active or inactive |
| `/usage-aware:usage-plan clear` | Remove the plan |
| `/usage-color #ff8800` | Color of the usage bars above the prompt (`reset` for the default) |

Typing `/usage-plan` autocompletes to the full name.

**Conditions** are `always`, or comparisons joined by `and` / `or` (`and` binds tighter), like `tokens_left < 5M and reset_5h_min > 30`. Numbers can end in `k` or `M`. A comparison on a measurement that's currently unknown is false. A rule can also be `once`, meaning it's delivered only when its condition first becomes true.

| Measurement | Meaning |
|---|---|
| `pct_5h`, `pct_7d`, `pct_spend` | % left in the window |
| `tok_5h`, `tok_7d` | estimated tokens left in the window |
| `tokens_left` | the smaller of the two |
| `steps` | ≈ Claude's own model calls left: dollars left ÷ this session's cost per call (see [Steps](#steps)) |
| `context` | current context size, in tokens |
| `reset_5h_min`, `reset_7d_min` | minutes until the window resets |
| `runway_5h_min`, `runway_7d_min` | minutes until it runs out at its average rate so far |
| `runway_recent_5h_min`, `runway_recent_7d_min` | minutes until it runs out at its rate over about the last hour |
| `out_before_reset_5h`, `out_before_reset_7d` | 1 if it runs out before resetting at that rate |
| `age_min` | age of the reading, in minutes |

Plans are per session and live in `~/.claude/usage-aware/plans/<session id>.json` (see [Several accounts](#several-accounts) for other config dirs). They survive resume and `/clear`, are not copied to forks, and are deleted after two weeks unused. You can edit the JSON by hand: `~/.claude/usage-aware/usage-plan check <session id>` validates it, and an invalid plan is ignored with a note to Claude.

Anytime, in a shell: `~/.claude/usage-aware/usage-status [session id]`.

## How it works

```
Claude Code ──session.measure──▶ bundled mod ──writes──▶ ~/.claude/usage-aware/state.json
                    │                                              │
                    └─▶ usage bars above the prompt   usage-status ◀┘  (+ plans/<session>.json)
                                                        ▲        ▲        ▲
                                   UserPromptSubmit hook          │        PreToolUse hook (Agent)
                                   (every prompt)       Claude via Bash    (before subagents)
                                                         (mid-turn)
```

The mod receives Claude Code's own rate-limit readings after each turn, and mid-turn whenever a window moves by a whole point. It writes them to `state.json` with the time of the reading, so the age shown is the age of real data. It also draws the remaining-usage bars above the prompt. Claude sees usage in four layers:

1. **Session start** (also after `/clear`, `/compact`, resume, fork): how to read the numbers, and whether a plan is set.
2. **Every prompt:** the usage line, plus the plan's active rules.
3. **Mid-turn:** during long work, Claude runs `usage-status <session id>` before major steps and before spawning subagents.
4. **Before a subagent:** the plan's active "before subagents" rules.

"at recent rate out in X" appears when, at the rate the window moved over about the last hour, it would run out before resetting. The mod keeps two hours of readings per window in its store (per account, shared by its sessions), and `usage-status` compares the % used now with the reading about an hour back, against the clock, so idle time lowers the rate. It needs 15 minutes of history; until then, "at avg rate out in X" uses the window's average rate since it began, judged once 10% of the window has passed. A window whose reset time has passed counts as 100% left. Data older than 30 minutes is tagged `stale`.

### Token estimate

The same % is a very different amount of work on Pro, Max and Ultra, so the plugin estimates **tokens left** in each window and shows it in parentheses: `34% left (~4.1M tok)`. Claude Code doesn't report a token allowance, so the mod learns one:

- It samples the cost of every Claude Code session on this machine (price-weighted, subagents included) each time a window moves at least 1 point: dollars per 1% of the window.
- It counts the tokens of every model response, subagents included, to get tokens per dollar.
- Tokens left = % left × dollars per 1% × tokens per dollar.

Samples are smoothed (EMA), outliers are clamped after a few samples, a window reset re-anchors instead of sampling, and the calibration is saved across sessions in the mod's store. Tokens per dollar depends a lot on the model, so each session's figure is blended into the saved one (30%) rather than replacing it. Claude is told to size work in tokens/steps.

### Steps

`≈N steps (~$0.36/step)` estimates how many more of Claude's own model calls fit in the tighter window: dollars left in the window (% left × dollars per 1%) divided by what this session has spent per main-loop call, measured every 3 calls and smoothed. A subagent's calls aren't steps, but what they cost is charged to the main-loop calls, so a session that spawns heavy subagents sees its steps fall faster. Cached context is cheap, so this follows real cost better than counting tokens.

Until a session has 3 calls to go on (and again after `/clear`), it shows `≈N steps at 85k context`: the tighter window's tokens divided by the current context size, since each call reads about one context. Context and cost per step are per session (`contexts/<session id>.json`), so parallel sessions each see their own.

Caveats: no estimate appears until the first whole point of movement. Each session writes its running cost to `~/.claude/usage-aware/sessions/`, and calibration sums all of them, so parallel Claude Code sessions of this account on this machine are accounted for. Use elsewhere (claude.ai, other devices) moves the % with no cost seen, so the estimate can run low, which errs on the safe side; after 3 samples such outliers are clamped.

### Several accounts

Usage, plans and session costs belong to one account, so each Claude config dir keeps its own data: `~/.claude/usage-aware/` for the default one, and `$CLAUDE_CONFIG_DIR/usage-aware/` when you run Claude Code with another `CLAUDE_CONFIG_DIR` (e.g. a second account in `~/.claude-alt`). The scripts Claude runs (`usage-status`, `usage-plan`) stay in `~/.claude/usage-aware/` for every account and pick the data dir from `CLAUDE_CONFIG_DIR`, so the permission rule and `/usage-aware:usage-plan` are the same everywhere. The calibration lives in the mod's store, which is already per config dir.

## Upgrading from 0.4

0.5 changes `steps` to a cost-based estimate (see [Steps](#steps)); plans that use it keep working, but the number can differ from before. It also moves a non-default account's data to `$CLAUDE_CONFIG_DIR/usage-aware/`, so that account starts with fresh usage data and without its old plans; its calibration is kept. Before 0.5, two accounts on one machine shared `~/.claude/usage-aware/`, and their readings and costs mixed.

## Upgrading from 0.3

0.4 removes the NORMAL / CONSERVE / WRAP-UP modes and `/usage-aware:thresholds`. Claude now gets facts only, plus whatever plan you set. To get the old behaviour back, set it as a plan, e.g. `/usage-aware:usage-plan create below 50% left in either window: small steps and no subagents; below 20%: finish the current unit, write a handoff note and ask before new work`. A leftover `~/.claude/usage-aware/config.json` is ignored and can be deleted.

## Uninstall

1. Remove the permission rule (and the plugin path from `CLAUDE_CODE_PLUGIN_DIRS`, if you used that) from `~/.claude/settings.json`.
2. `claude plugin uninstall usage-aware@usage-aware`
3. `rm -r ~/.claude/usage-aware` (this includes any plans), plus `$CLAUDE_CONFIG_DIR/usage-aware` for any other account you used it with

## Development

```sh
bash tests/run.sh                     # bash tests + mod tests (claude plugin test)
claude plugin validate .
claude --plugin-dir .                 # load this checkout
```

## Credits

Built by its-diht with [Claude Code](https://claude.com/claude-code) (Claude Opus 5.5) as co-author.
