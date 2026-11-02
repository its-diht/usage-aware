# usage-aware

Keeps Claude Code aware of your remaining **5-hour** and **7-day** plan usage, and makes it budget work against what's left.

```
[usage] mode: CONSERVE · 5h: 34% left, resets 1h50m · 7d: 71% left, resets 4d3h · 40s old
        → small verifiable steps, no fan-outs/subagents, checkpoint often
```

## Requirements

- **bash** and **jq** (`sudo apt install jq` / `sudo pacman -S jq` / `brew install jq`). GNU or BSD userland both work.
- A **Claude subscription** (Pro, Max, …). Claude Code only reports `rate_limits` to subscribers; API-key accounts get no data and see "usage unknown".
- The **Claude Code CLI**. UserPromptSubmit context has been reported not to reach the model in the VS Code extension.

## Install

1. Add the plugin:
   ```sh
   claude plugin marketplace add its-diht/usage-aware
   claude plugin install usage-aware@usage-aware
   ```
2. Run the one-time setup. It copies the scripts to `~/.claude/usage-aware/` and **prints** the settings to add. It never edits your settings file.
   ```sh
   git clone https://github.com/its-diht/usage-aware && bash usage-aware/scripts/install.sh
   ```
   (Skipping this is fine too: the scripts are synced at every session start; you just need the snippet.)
3. Merge the printed snippet into `~/.claude/settings.json`. It looks like:
   ```json
   {
     "statusLine": { "type": "command", "command": "~/.claude/usage-aware/tap-statusline" },
     "permissions": { "allow": ["Bash(~/.claude/usage-aware/usage-status *)"] }
   }
   ```
   If you already have a statusline, the snippet wraps it: `USAGE_AWARE_NEXT='<your old command>' ~/.claude/usage-aware/tap-statusline` runs your old statusline with the same input and shows its output.
4. Restart Claude Code. Usage appears after Claude's first response in a session.

## Commands

| Command | Effect |
|---|---|
| `/usage-aware:thresholds` | Show current thresholds |
| `/usage-aware:thresholds 60 25` | CONSERVE below 60% left, WRAP-UP below 25% left |
| `/usage-aware:thresholds reset` | Restore defaults (50 / 20) |

Values are integers 0–100 and WRAP-UP must be lower than CONSERVE. Changes apply from the next prompt.

Anytime, in a shell: `~/.claude/usage-aware/usage-status`.

## How it works

```
Claude Code ──stdin JSON──▶ tap-statusline ──writes──▶ ~/.claude/usage-aware/state.json
                                                              │
                                     usage-status ◀──reads────┘  (+ config.json)
                                      ▲        ▲
                 UserPromptSubmit hook          Claude runs it via Bash
                 (push, every prompt)           (pull, mid-turn)
```

`rate_limits` is only handed to statusline commands, so the statusline saves it. Claude then sees usage in three layers:

1. **Session start** (also after `/clear`, `/compact`, resume): the budgeting policy and modes table.
2. **Every prompt:** the current usage line and that mode's rule.
3. **Mid-turn:** during long work, Claude runs `usage-status` before major steps and before spawning subagents.

The mode comes from whichever window has less left:

| Mode | When (defaults) | Rule |
|---|---|---|
| NORMAL | ≥ 50% left | Work normally, but still size plans against remaining usage. |
| CONSERVE | 20–50% left | Small verifiable steps. Avoid fan-outs and subagents. Checkpoint often. |
| WRAP-UP | < 20% left | Finish the current unit, write a handoff note, ask before starting new work. |

Details: a window whose reset time has passed counts as 100% left; data older than 30 minutes is tagged `stale`. The statusline refreshes on each assistant message, so data refreshes between tool calls but not during a single long tool run.

## Uninstall

1. Remove the `statusLine` (or restore your old command from `USAGE_AWARE_NEXT`) and the permission rule from `~/.claude/settings.json`.
2. `claude plugin uninstall usage-aware@usage-aware`
3. `rm -r ~/.claude/usage-aware`

## Development

```sh
bash tests/run.sh                     # unit tests (bash + jq only)
claude plugin validate .
claude --plugin-dir .                 # load this checkout
claude --plugin-dir . --settings '{"statusLine":{"type":"command","command":"~/.claude/usage-aware/tap-statusline"}}'
                                      # try the statusline without touching settings.json
```
