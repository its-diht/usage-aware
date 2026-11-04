# usage-aware

Keeps Claude Code aware of your remaining **5-hour** and **7-day** plan usage, and makes it budget work against what's left.

```
[usage] mode: CONSERVE · 5h: 34% left (~4.1M tok), resets 1h50m · 7d: 71% left (~107M tok), resets 4d3h · ≈48 steps at 85k context · 40s old
        → small verifiable steps, no fan-outs/subagents, checkpoint often
```

## Requirements

- **bash** and **jq** (`sudo apt install jq` / `sudo pacman -S jq` / `brew install jq`). Developed and tested on Linux.
- A **Claude subscription** (Pro, Max, …) or a spend-limited Claude gateway. Claude Code only reports rate limits to these; API-key accounts see "usage unknown".
- **Claude Code with plugin mods** (function hooks, early access): the bundled mod is the data source. If the mod can't load, Claude still gets the policy but tells you once per session that data isn't updating.
- The **Claude Code CLI**. UserPromptSubmit context has been reported not to reach the model in the VS Code extension.

## Install

1. Load the plugin, either from GitHub:
   ```sh
   claude plugin marketplace add its-diht/usage-aware
   claude plugin install usage-aware@usage-aware
   ```
   or from a local checkout, by adding its path to `CLAUDE_CODE_PLUGIN_DIRS` (`:`-separated) in the `env` block of `~/.claude/settings.json`, or with `claude --plugin-dir <path>`.
2. Optional, so Claude's mid-turn checks don't stop for approval: add this permission rule to `~/.claude/settings.json`.
   ```json
   { "permissions": { "allow": ["Bash(~/.claude/usage-aware/usage-status *)"] } }
   ```
   `bash scripts/install.sh` prints the same snippet, tailored to your settings. It never edits the file.
3. Restart Claude Code. Usage appears after Claude's first response in a session.

No statusline setup is needed. If you used v0.1's `tap-statusline`, remove that `statusLine` entry (install.sh flags it).

## Commands

| Command | Effect |
|---|---|
| `/usage-aware:thresholds` | Show current thresholds |
| `/usage-aware:thresholds 60 25` | CONSERVE below 60% left, WRAP-UP below 25% left |
| `/usage-aware:thresholds reset` | Restore defaults (50 / 20) |
| `/usage-color #ff8800` | Color of the usage bars above the prompt (`reset` for the default) |

Threshold values are integers 0–100, and WRAP-UP must be lower than CONSERVE. Changes apply from the next prompt.

Anytime, in a shell: `~/.claude/usage-aware/usage-status`.

## How it works

```
Claude Code ──session.measure──▶ bundled mod ──writes──▶ ~/.claude/usage-aware/state.json
                    │                                              │
                    └─▶ usage bars above the prompt   usage-status ◀┘  (+ config.json)
                                                        ▲        ▲
                                   UserPromptSubmit hook          Claude runs it via Bash
                                   (push, every prompt)           (pull, mid-turn)
```

The mod receives Claude Code's own rate-limit readings after each turn, and mid-turn whenever a window moves by a whole point. It writes them to `state.json` with the time of the reading, so the age shown is the age of real data. It also draws the remaining-usage bars above the prompt. Claude sees usage in three layers:

1. **Session start** (also after `/clear`, `/compact`, resume, fork): the budgeting policy and modes table.
2. **Every prompt:** the current usage line and that mode's rule.
3. **Mid-turn:** during long work, Claude runs `usage-status` before major steps and before spawning subagents.

The mode comes from whichever window (5h, 7d, or a spend limit) is tightest:

| Mode | When (defaults) | Rule |
|---|---|---|
| NORMAL | ≥ 50% left | Work normally, but still size plans against remaining usage. |
| CONSERVE | 20–50% left | Small verifiable steps. Avoid fan-outs and subagents. Checkpoint often. |
| WRAP-UP | < 20% left | Finish the current unit, write a handoff note, ask before starting new work. |

Two adjustments, shown after the mode:

- **Pace:** once 10% of a window has passed, if the average rate so far would use up what's left before the reset, the mode is at least CONSERVE: `mode: CONSERVE (pace: 7d) · 7d: 70% left, resets 6d0h, pace: out in 2d8h`.
- **Resets soon:** a window resetting within 15 min (5h) or 12 h (7d) counts one step less strict: `mode: CONSERVE (5h resets soon)`.

A window whose reset time has passed counts as 100% left. Data older than 30 minutes is tagged `stale`.

### Token estimate

The same % is a very different amount of work on Pro, Max and Ultra, so the plugin estimates **tokens left** in each window and shows it in parentheses: `34% left (~4.1M tok)`. Claude Code doesn't report a token allowance, so the mod learns one:

- It samples the cost of every Claude Code session on this machine (price-weighted, subagents included) each time a window moves at least 1 point: dollars per 1% of the window.
- It counts the tokens of every turn, including subagent turns, to get tokens per dollar.
- Tokens left = % left × dollars per 1% × tokens per dollar.

Samples are smoothed (EMA), outliers are clamped after a few samples, a window reset re-anchors instead of sampling, and the calibration is saved across sessions in the mod's store. `≈N steps at Xk context` divides the tighter window's tokens by the current context size, since each model call costs about one context. Claude is told to size work in tokens/steps and to treat the % and mode as the coarse gate.

Caveats: no estimate appears until the first whole point of movement. Each session writes its running cost to `~/.claude/usage-aware/sessions/`, and calibration sums all of them, so parallel Claude Code sessions on this machine are accounted for. Use elsewhere (claude.ai, other devices) moves the % with no cost seen, so the estimate can run low, which errs on the safe side; after 3 samples such outliers are clamped. Modes are still set by %.

## Uninstall

1. Remove the permission rule (and the plugin path from `CLAUDE_CODE_PLUGIN_DIRS`, if you used that) from `~/.claude/settings.json`.
2. `claude plugin uninstall usage-aware@usage-aware`
3. `rm -r ~/.claude/usage-aware`

## Development

```sh
bash tests/run.sh                     # bash tests + mod tests (claude plugin test)
claude plugin validate .
claude --plugin-dir .                 # load this checkout
```

## Credits

Built by its-diht with [Claude Code](https://claude.com/claude-code) (Claude Opus 5.5) as co-author.
