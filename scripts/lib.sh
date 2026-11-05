# usage-aware shared library. Sourced, never executed.
# Override USAGE_AWARE_DIR to relocate runtime data (tests use this).
UA_DIR="${USAGE_AWARE_DIR:-$HOME/.claude/usage-aware}"
UA_STATE="$UA_DIR/state.json"
UA_PLANS="$UA_DIR/plans"           # per-session usage plans: <session_id>.json (+ .state.json)
UA_HEARTBEAT="$UA_DIR/mod.json"   # touched by the bundled mod
UA_HEARTBEAT_MAX=86400
UA_STALE_SECS=1800
UA_PLAN_MAX_RULES=12
UA_PLAN_MAX_DO=300
UA_SYNC_FILES=(usage-status usage-plan lib.sh)

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

# jq: usage facts from state.json. Needs $now. Defines:
#   facts -> {vars: {name: number}, line: "[usage] ..."}   (unset vars are absent)
# Window lengths for the average-rate runway, which is only judged once 10% of a window has passed.
UA_JQ_FACTS='
def ftok: if . >= 1e7 then "\(. / 1e6 | round)M" elif . >= 1e6 then "\((. / 1e5 | round) / 10)M"
          elif . >= 1e3 then "\(. / 1e3 | round)k" else "\(round)" end;
def win($len):
  if type != "object" or (.used_percentage | type) != "number" then null
  else .resets_at as $r
    | ((($r | type) == "number") and $r <= $now) as $reset
    | (if $reset then 100 else ([100 - .used_percentage, 0] | max) end) as $left
    | (if ($r | type) == "number" and ($reset | not) then $r - $now else null end) as $ttr
    | (if (.tokens_per_pct | type) == "number" and .tokens_per_pct > 0 then $left * .tokens_per_pct else null end) as $tok
    | (if $reset or $ttr == null or $len == null then null
       elif $left <= 0 then 0
       elif .used_percentage > 0 and ($len - $ttr) >= 0.1 * $len then $left * ($len - $ttr) / .used_percentage
       else null end) as $runway
    | {left: $left, reset: $reset, ttr: $ttr, tok: $tok, runway: $runway,
       out: (if $runway == null then null elif $runway < $ttr then 1 else 0 end)}
  end;
def wtxt($label):
  if . == null then "\($label): n/a"
  elif .reset then "\($label): 100% left" + (if .tok != null then " (~\(.tok | ftok) tok)" else "" end) + " (reset)"
  else "\($label): \(.left | floor)% left"
    + (if .tok != null then " (~\(.tok | ftok) tok)" else "" end)
    + (if .left <= 0 then " (limit reached)" else "" end)
    + (if .ttr != null then ", resets \(.ttr | dur)" else "" end)
    + (if .out == 1 and .left > 0 then ", at avg rate out in \(.runway | dur)" else "" end)
  end;
def facts:
  . as $s
  | (.five_hour | win(18000)) as $h | (.seven_day | win(604800)) as $d
  | (if (.spend_limit | type) == "object" then (.spend_limit | win(null)) else null end) as $sp
  | ([$h.tok, $d.tok] | map(select(. != null)) | min) as $tl
  | (if ($s.context_tokens | type) == "number" and $s.context_tokens > 0 then $s.context_tokens else null end) as $ctx
  | ($now - ($s.updated_at // $now)) as $age
  | {vars: ({pct_5h: $h.left, pct_7d: $d.left, pct_spend: $sp.left, tok_5h: $h.tok, tok_7d: $d.tok,
             tokens_left: $tl, context: $ctx,
             steps: (if $tl != null and $ctx != null then ($tl / $ctx | floor) else null end),
             reset_5h_min: (if $h.ttr != null then $h.ttr / 60 else null end),
             reset_7d_min: (if $d.ttr != null then $d.ttr / 60 else null end),
             runway_5h_min: (if $h.runway != null then $h.runway / 60 else null end),
             runway_7d_min: (if $d.runway != null then $d.runway / 60 else null end),
             out_before_reset_5h: $h.out, out_before_reset_7d: $d.out, age_min: ($age / 60)}
            | with_entries(select(.value != null))),
     known: ([$h, $d, $sp] | map(select(. != null)) | length),
     line: ("[usage] " + ([($h | wtxt("5h")), ($d | wtxt("7d"))] + (if $sp != null then [$sp | wtxt("spend")] else [] end) | join(" · "))
            + (if $tl != null and $ctx != null then " · ≈\($tl / $ctx | floor) steps at \($ctx | ftok) context" else "" end)
            + " · \($age | dur) old" + (if $age > '"$UA_STALE_SECS"' then " · stale" else "" end))};
'

# jq: usage-plan conditions. Grammar: always | cmp ((and|or) cmp)*, "and" binds tighter;
# cmp = var op number[k|M], op in < <= > >= ==. An unset var makes its comparison false.
UA_JQ_RULES='
def VARS: ["pct_5h","pct_7d","pct_spend","tok_5h","tok_7d","tokens_left","steps","context",
           "reset_5h_min","reset_7d_min","runway_5h_min","runway_7d_min",
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
               + (if ($r.id // "x") | type == "string" then [] else ["rule \($i + 1): \"id\" must be a string"] end)
            end)[]])
  end;
def rid($i): (.id // "rule\($i + 1)");
'

# Path as Claude should type it. Permission rules match literal text, so keep "~/".
if [[ -z "${USAGE_AWARE_DIR:-}" ]]; then UA_DISPLAY_DIR="~/.claude/usage-aware"; else UA_DISPLAY_DIR="$UA_DIR"; fi

# Copy plugin scripts to the fixed runtime path when they differ. Arg: plugin root.
ua_sync() {
  local root="$1" name src dest tmp
  mkdir -p "$UA_DIR" || return 1
  for name in "${UA_SYNC_FILES[@]}"; do
    case $name in *.sh) src="$root/scripts/$name" ;; *) src="$root/scripts/$name.sh" ;; esac
    dest="$UA_DIR/$name"
    [[ -f "$src" ]] || continue
    cmp -s "$src" "$dest" && continue
    tmp="$(mktemp "$dest.XXXXXX")" && cp "$src" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dest" || rm -f "$tmp"
  done
}
