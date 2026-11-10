# usage-aware shared library. Sourced, never executed.
# Runtime data belongs to one account, so each Claude config dir gets its own: ~/.claude/usage-aware
# by default, $CLAUDE_CONFIG_DIR/usage-aware for any other config dir. The scripts Claude runs
# (UA_BIN_DIR) stay at one fixed path for every account, so the permission rule and the
# /usage-aware:usage-plan command don't depend on the account.
# USAGE_AWARE_DIR overrides both (tests use this).
UA_BIN_DIR="${USAGE_AWARE_DIR:-$HOME/.claude/usage-aware}"
if [[ -n ${USAGE_AWARE_DIR:-} ]]; then
  UA_DIR="$USAGE_AWARE_DIR"
elif [[ -n ${CLAUDE_CONFIG_DIR:-} && "${CLAUDE_CONFIG_DIR%/}" != "$HOME/.claude" ]]; then
  UA_DIR="${CLAUDE_CONFIG_DIR%/}/usage-aware"
else
  UA_DIR="$HOME/.claude/usage-aware"
fi
UA_CONTEXTS="$UA_DIR/contexts"     # per-session figures from the mod: <session_id>.json
UA_STATE="$UA_DIR/state.json"
UA_PLANS="$UA_DIR/plans"           # per-session usage plans: <session_id>.json (+ .state.json)
UA_HEARTBEAT="$UA_DIR/mod.json"   # touched by the bundled mod
UA_HEARTBEAT_MAX=86400
UA_STALE_SECS=1800
UA_PLAN_MAX_RULES=12
UA_PLAN_MAX_DO=300
UA_SYNC_FILES=(usage-status usage-plan ua-lib.sh)

ua_have_jq() { command -v jq >/dev/null 2>&1; }

# Atomic write: ua_write_atomic <dest> <content>
ua_write_atomic() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# jq helper: human duration (1d2h, 1h50m, 5m, 40s)
UA_JQ_DUR='def dur: (if . < 0 then 0 else floor end) as $s
  | if $s >= 86400 then "\($s/86400|floor)d\($s%86400/3600|floor)h"
    elif $s >= 3600 then "\($s/3600|floor)h\($s%3600/60|floor)m"
    elif $s >= 60 then "\($s/60|floor)m"
    else "\($s)s" end;'

# jq: usage facts from state.json. Needs $now, $sid (session id or "") and $sessraw (ua_session_file). Defines:
#   facts -> {vars: {name: number}, line: "[usage] ..."}   (unset vars are absent)
# Window lengths for the average-rate runway, which is only judged once 10% of a window has passed.
# The recent rate compares the % used now with the reading about an hour ago (from the window's
# "recent" [time, %] history; at least 15 minutes back), measured against the clock, so idle time counts.
UA_JQ_FACTS='
def pos: if type == "number" and . > 0 then . else null end;
def ftok: if . >= 1e7 then "\(. / 1e6 | round)M" elif . >= 1e6 then "\((. / 1e5 | round) / 10)M"
          elif . >= 1e3 then "\(. / 1e3 | round)k" else "\(round)" end;
def fusd: (. * 100 | round) as $c | "$\($c / 100 | floor).\($c % 100 | if . < 10 then "0\(.)" else "\(.)" end)";
def win($len):
  if type != "object" or (.used_percentage | type) != "number" then null
  else .resets_at as $r
    | ((($r | type) == "number") and $r <= $now) as $reset
    | (if $reset then 100 else ([100 - .used_percentage, 0] | max) end) as $left
    | (if ($r | type) == "number" and ($reset | not) then $r - $now else null end) as $ttr
    | (if (.tokens_per_pct | pos) != null then $left * .tokens_per_pct else null end) as $tok
    | (if (.usd_per_pct | pos) != null then $left * .usd_per_pct else null end) as $usd
    | (if $reset or $ttr == null or $len == null then null
       elif $left <= 0 then 0
       elif .used_percentage > 0 and ($len - $ttr) >= 0.1 * $len then $left * ($len - $ttr) / .used_percentage
       else null end) as $runway
    | (if $reset or $ttr == null then null
       else [(.recent // []) | arrays | .[] | select(type == "array" and length == 2 and (.[0] | type) == "number"
               and (.[1] | type) == "number" and .[0] >= $now - 7200)] as $pts
         | (([$pts[] | select(.[0] <= $now - 3600)] | last) // ([$pts[] | select(.[0] <= $now - 900)] | first)) as $b
         | if $b == null then null else ([.used_percentage - $b[1], 0] | max) / ($now - $b[0]) end
       end) as $rate
    | (if $rate == null then null elif $left <= 0 then 0 elif $rate > 0 then $left / $rate else null end) as $recent
    | {left: $left, reset: $reset, ttr: $ttr, tok: $tok, usd: $usd, runway: $runway, out: (if $runway == null then null elif $runway < $ttr then 1 else 0 end),
       rate_known: ($rate != null), recent_runway: $recent}
  end;
def wtxt($label):
  if . == null then "\($label): n/a"
  elif .reset then "\($label): 100% left" + (if .tok != null then " (~\(.tok | ftok) tok)" else "" end) + " (reset)"
  else "\($label): \(.left | floor)% left"
    + (if .tok != null then " (~\(.tok | ftok) tok)" else "" end)
    + (if .left <= 0 then " (limit reached)" else "" end)
    + (if .ttr != null then ", resets \(.ttr | dur)" else "" end)
    + (if .left <= 0 then ""
       elif .rate_known then (if .recent_runway != null and .recent_runway < .ttr then ", at recent rate out in \(.recent_runway | dur)" else "" end)
       elif .out == 1 then ", at avg rate out in \(.runway | dur)" else "" end)
  end;
def facts:
  . as $s
  | ($sessraw | try fromjson catch null | if type == "object" then . else {} end) as $sess
  | (.five_hour | win(18000)) as $h | (.seven_day | win(604800)) as $d
  | (if (.spend_limit | type) == "object" then (.spend_limit | win(null)) else null end) as $sp
  | ([$h.tok, $d.tok] | map(select(. != null)) | min) as $tl
  | ([$h.usd, $d.usd] | map(select(. != null)) | min) as $ul
  # Context and cost per step are per session: the session file, else state.json only if this session
  # wrote it (or no session is named, or an older mod did not record the writer).
  | ($sid == "" or ($s.session_id // $sid) == $sid) as $mine
  | (($sess.context_tokens | pos) // (if $mine then $s.context_tokens | pos else null end)) as $ctx
  | (($sess.usd_per_step | pos) // (if $mine then $s.usd_per_step | pos else null end)) as $ups
  # Steps: dollars left / dollars per step once this session has a step cost, else tokens left / context.
  | (if $ul != null and $ups != null then {n: ($ul / $ups | floor), txt: "(~\($ups | fusd)/step)"}
     elif $tl != null and $ctx != null then {n: ($tl / $ctx | floor), txt: "at \($ctx | ftok) context"}
     else null end) as $steps
  | ($now - ($s.updated_at // $now)) as $age
  | {vars: ({pct_5h: $h.left, pct_7d: $d.left, pct_spend: $sp.left, tok_5h: $h.tok, tok_7d: $d.tok,
             tokens_left: $tl, context: $ctx, steps: $steps.n,
             reset_5h_min: (if $h.ttr != null then $h.ttr / 60 else null end),
             reset_7d_min: (if $d.ttr != null then $d.ttr / 60 else null end),
             runway_5h_min: (if $h.runway != null then $h.runway / 60 else null end),
             runway_7d_min: (if $d.runway != null then $d.runway / 60 else null end),
             runway_recent_5h_min: (if $h.recent_runway != null then $h.recent_runway / 60 else null end),
             runway_recent_7d_min: (if $d.recent_runway != null then $d.recent_runway / 60 else null end),
             out_before_reset_5h: $h.out, out_before_reset_7d: $d.out, age_min: ($age / 60)}
            | with_entries(select(.value != null))),
     known: ([$h, $d, $sp] | map(select(. != null)) | length),
     line: ("[usage] " + ([($h | wtxt("5h")), ($d | wtxt("7d"))] + (if $sp != null then [$sp | wtxt("spend")] else [] end) | join(" · "))
            + (if $steps != null then " · ≈\($steps.n) steps \($steps.txt)" else "" end)
            + " · \($age | dur) old" + (if $age > '"$UA_STALE_SECS"' then " · stale" else "" end))};
'

# jq: usage-plan conditions. Grammar: always | cmp ((and|or) cmp)*, "and" binds tighter;
# cmp = var op number[k|M], op in < <= > >= ==. An unset var makes its comparison false.
UA_JQ_RULES='
def VARS: ["pct_5h","pct_7d","pct_spend","tok_5h","tok_7d","tokens_left","steps","context",
           "reset_5h_min","reset_7d_min","runway_5h_min","runway_7d_min","runway_recent_5h_min","runway_recent_7d_min",
           "out_before_reset_5h","out_before_reset_7d","age_min"];
def cmpparse: [capture("^\\s*(?<var>[a-z0-9_]+)\\s*(?<op><=|>=|==|<|>)\\s*(?<n>-?[0-9]+(\\.[0-9]+)?)(?<sfx>[kM]?)\\s*$")] | first;
def terms: [splits("\\s+or\\s+") | [splits("\\s+and\\s+")]];
def when_errors:
  if type != "string" or (gsub("\\s"; "") == "") then ["when must be a non-empty string"]
  elif test("^\\s*always\\s*$") then []
  else [terms[][] | . as $t | cmpparse as $m
        | if $m == null then "bad comparison: \"\($t)\" (want: var op number, e.g. tokens_left < 5M)"
          elif (VARS | index($m.var)) == null then "unknown variable: \($m.var)"
          else empty end]
  end;
def when_true($v):
  if test("^\\s*always\\s*$") then true
  else [terms[] | [.[] | cmpparse as $m | ($m.n | tonumber) * ({"k": 1e3, "M": 1e6}[$m.sfx] // 1) as $n | $v[$m.var] as $x
                  | if $x == null then false
                    else {"<": ($x < $n), "<=": ($x <= $n), ">": ($x > $n), ">=": ($x >= $n), "==": ($x == $n)}[$m.op] end]
              | all] | any
  end;
def plan_errors:
  if type != "object" or (.rules | type) != "array" then ["plan must be an object with a \"rules\" array"]
  else (if (.rules | length) == 0 then ["plan has no rules"] else [] end)
     + (if (.rules | length) > '"$UA_PLAN_MAX_RULES"' then ["too many rules: \(.rules | length) (max '"$UA_PLAN_MAX_RULES"')"] else [] end)
     + ([.rules | to_entries[] | .key as $i | .value as $r
         | (if ($r | type) != "object" then ["rule \($i + 1): not an object"]
            else ($r.when | when_errors | map("rule \($i + 1): " + .))
               + (if ($r.do | type) != "string" or ($r.do | length) == 0 then ["rule \($i + 1): missing \"do\""]
                  elif ($r.do | length) > '"$UA_PLAN_MAX_DO"' then ["rule \($i + 1): \"do\" over '"$UA_PLAN_MAX_DO"' characters"] else [] end)
               + (if ($r.on // "prompt") | IN("prompt", "subagent") then [] else ["rule \($i + 1): \"on\" must be prompt or subagent"] end)
               + (if ($r.once // false) | type == "boolean" then [] else ["rule \($i + 1): \"once\" must be true or false"] end)
               + (if ($r.do | type) == "string" and ($r.do | test("[\u0001-\u001f\u007f]")) then ["rule \($i + 1): \"do\" must be one line, without control characters"] else [] end)
               + (if ($r.id // "x") | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$") then [] else ["rule \($i + 1): \"id\" must be 1-40 letters, digits, - or _"] end)
            end)[]])
  end;
def rid($i): (.id // "rule\($i + 1)");
'

# Path as Claude should type it. Permission rules match literal text, so keep "~/".
if [[ -z "${USAGE_AWARE_DIR:-}" ]]; then UA_DISPLAY_DIR="~/.claude/usage-aware"; else UA_DISPLAY_DIR="$UA_DIR"; fi

# Path of this session's figures from the mod (contexts/<sid>.json), or /dev/null when there are none.
# Callers pass it to the facts jq as --rawfile sessraw, so reading it costs no extra process.
ua_session_file() {
  local f="$UA_CONTEXTS/$1.json"
  if [[ $1 =~ ^[A-Za-z0-9_-]{1,128}$ && -f $f ]]; then printf '%s\n' "$f"; else echo /dev/null; fi
}

# Copy plugin scripts to the fixed runtime path when they differ. Arg: plugin root.
ua_sync() {
  local root="$1" name src dest tmp
  mkdir -p "$UA_BIN_DIR" || return 1
  for name in "${UA_SYNC_FILES[@]}"; do
    case $name in ua-lib.sh) src="$root/scripts/lib.sh" ;; *) src="$root/scripts/$name.sh" ;; esac
    dest="$UA_BIN_DIR/$name"
    [[ -f "$src" ]] || continue
    cmp -s "$src" "$dest" && continue
    tmp="$(mktemp "$dest.XXXXXX")" && cp "$src" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dest" || rm -f "$tmp"
  done
}
