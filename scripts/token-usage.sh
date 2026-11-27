#!/usr/bin/env bash
# Tokens and API-equivalent cost of one feature (or standalone task), from Claude Code's own transcripts.
# Pure shell + jq: no model tokens. Never fails a workflow step (exit 0 when there is nothing to report).
#   token-usage.sh <feature> [--md|--json] [--out <file>]
#   --md     (default) a Markdown report: phase x agent x model table, per-model subtotals, a Total line.
#   --json   the raw aggregates (rows, models, total, unknown_models, partial, sessions).
#   --out    also writes the output to <file> (its folder is created); nothing is written when there is no data.
# Where the numbers come from:
#   - .claude/workflow/<feature>/sessions.tsv, written by the claim-feature.sh hook: one line per phase
#     change of a session, `<unix ts> <session id> <phase> <transcript path>`. Without it the single session
#     in the `owner` file is used, found under $WF_CLAUDE_PROJECTS (default ~/.claude/projects), and the
#     report says it is partial.
#   - the session's transcript <session>.jsonl and its subagents <session>/subagents/agent-*.jsonl
#     (agent-*.meta.json names the agent type). A message written on several lines is counted once (its id).
# A message counts for this feature when the latest mark of its session, at or before the message, is a
# mark of this feature: after the session marks another feature it no longer counts here. The phase of a
# message is the phase of that mark. A message before the session's first mark goes to the feature of
# that first mark (plan-feature writes the first state.json only at the end of Phase 1).
# Prices are USD per 1M tokens, matched by the longest model-id prefix. Built in below; `pricing` in
# .claude/workflow.json overrides or adds entries of the same shape:
#   {"<model prefix>": {"input": n, "output": n, "cache_write_5m": n, "cache_write_1h": n, "cache_read": n}}
# An unknown model has no cost ("?"); the report names it. The result is an estimate at API list prices:
# a Claude subscription is billed differently.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

usage() { echo "usage: token-usage.sh <feature> [--md|--json] [--out <file>]" >&2; exit 2; }
feature="${1:-}"; shift 2>/dev/null
mode=md; out=""
while (($#)); do
  case "$1" in
    --md) mode=md; shift ;;
    --json) mode=json; shift ;;
    --out) [[ -n "${2:-}" ]] || usage; out="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$feature" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage

DIR="$WF_PROJECT/.claude/workflow"
PROJECTS="${WF_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wf-tokens.XXXXXX")" || exit 0
trap 'rm -rf "$tmp"' EXIT

# ---- Marks: every session's phase marks in every feature, this feature's last (ties go to it) ----
partial=false
: >"$tmp/marks.tsv"
for f in "$DIR"/*/sessions.tsv; do
  [[ -f "$f" ]] || continue
  name="$(basename "$(dirname "$f")")"
  [[ "$name" == "$feature" ]] && continue
  awk -F'\t' -v f="$name" 'NF >= 3 { print $1 "\t" $2 "\t" f "\t" $3 "\t" $4 }' "$f" >>"$tmp/marks.tsv"
done
if [[ -s "$DIR/$feature/sessions.tsv" ]]; then
  awk -F'\t' -v f="$feature" 'NF >= 3 { print $1 "\t" $2 "\t" f "\t" $3 "\t" $4 }' "$DIR/$feature/sessions.tsv" >>"$tmp/marks.tsv"
elif [[ -s "$DIR/$feature/owner" ]]; then
  partial=true
  printf '0\t%s\t%s\t-\t-\n' "$(head -n 1 "$DIR/$feature/owner" | tr -d '[:space:]')" "$feature" >>"$tmp/marks.tsv"
fi

# ---- Records: one jq pass per transcript file ----
extract() { # <file> <agent> <session>
  grep -h '"usage"' "$1" 2>/dev/null | jq -R -c --arg agent "$2" --arg session "$3" '
    fromjson? | select(.type == "assistant" and (.message.usage | type) == "object"
      and (.message.model // "") != "" and .message.model != "<synthetic>")
    | .message.usage as $u | ($u.cache_creation | if type == "object" then . else null end) as $cc
    | { session: $session, agent: $agent, id: (.message.id // ""), model: .message.model,
        ts: ((.timestamp // "") | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null),
        input: ($u.input_tokens // 0), output: ($u.output_tokens // 0),
        cw5: (if $cc then ($cc.ephemeral_5m_input_tokens // 0) else ($u.cache_creation_input_tokens // 0) end),
        cw1: (if $cc then ($cc.ephemeral_1h_input_tokens // 0) else 0 end),
        cr: ($u.cache_read_input_tokens // 0) }
    | select(.ts != null)' 2>/dev/null
}
: >"$tmp/recs.jsonl"
sessions=0
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  tp="$(awk -F'\t' -v s="$s" -v f="$feature" '$2 == s && $3 == f && $5 != "-" && $5 != "" { p = $5 } END { print p }' "$tmp/marks.tsv")"
  if [[ -z "$tp" || ! -f "$tp" ]]; then
    tp=""
    for c in "$PROJECTS"/*/"$s".jsonl; do [[ -f "$c" ]] && { tp="$c"; break; }; done
  fi
  [[ -n "$tp" ]] || continue
  sessions=$((sessions + 1))
  extract "$tp" "(main)" "$s" >>"$tmp/recs.jsonl"
  for a in "$(dirname "$tp")/$s"/subagents/agent-*.jsonl; do
    [[ -f "$a" ]] || continue
    label="$(jq -r '.agentType // empty' "${a%.jsonl}.meta.json" 2>/dev/null)"
    extract "$a" "${label:-subagent}" "$s" >>"$tmp/recs.jsonl"
  done
done < <(awk -F'\t' -v f="$feature" '$3 == f { print $2 }' "$tmp/marks.tsv" | sort -u)

# ---- Prices ----
defaults='{
  "claude-fable-5-2": {"input": 8, "output": 40, "cache_write_5m": 10, "cache_write_1h": 16, "cache_read": 0.20},
  "claude-fable-5-1": {"input": 10, "output": 50, "cache_write_5m": 12.5, "cache_write_1h": 20, "cache_read": 1.00},
  "claude-fable-5": {"input": 10, "output": 50, "cache_write_5m": 12.5, "cache_write_1h": 20, "cache_read": 1.00},
  "claude-opus-5-5": {"input": 4, "output": 20, "cache_write_5m": 5, "cache_write_1h": 8, "cache_read": 0.20},
  "claude-opus-5": {"input": 5, "output": 25, "cache_write_5m": 6.25, "cache_write_1h": 10, "cache_read": 0.50},
  "claude-opus-4-8": {"input": 5, "output": 25, "cache_write_5m": 6.25, "cache_write_1h": 10, "cache_read": 0.50},
  "claude-opus-4-7": {"input": 5, "output": 25, "cache_write_5m": 6.25, "cache_write_1h": 10, "cache_read": 0.50},
  "claude-opus-4-6": {"input": 5, "output": 25, "cache_write_5m": 6.25, "cache_write_1h": 10, "cache_read": 0.50},
  "claude-sonnet-5-5": {"input": 2, "output": 10, "cache_write_5m": 2.5, "cache_write_1h": 4, "cache_read": 0.10},
  "claude-sonnet-5": {"input": 2, "output": 10, "cache_write_5m": 2.5, "cache_write_1h": 4, "cache_read": 0.20},
  "claude-sonnet-4-6": {"input": 3, "output": 15, "cache_write_5m": 3.75, "cache_write_1h": 6, "cache_read": 0.30},
  "claude-haiku-5-5": {"input": 0.10, "output": 0.50, "cache_write_5m": 0.125, "cache_write_1h": 0.20, "cache_read": 0.01},
  "claude-haiku-4-5": {"input": 1, "output": 5, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.10}
}'
user="$(jq -c 'if (.pricing | type) == "object" then .pricing else {} end' "$WF_CONFIG" 2>/dev/null || echo '{}')"
prices="$(jq -n -c --argjson d "$defaults" --argjson u "$user" '$d * $u' 2>/dev/null || echo "$defaults")"

# ---- Aggregate and format ----
result="$(jq -n -r --arg f "$feature" --arg mode "$mode" --argjson partial "$partial" --argjson sessions "$sessions" \
  --argjson prices "$prices" --rawfile raw "$tmp/marks.tsv" --slurpfile recs "$tmp/recs.jsonl" '
  def hn: if . < 1000 then tostring
    elif . < 999950 then (((. / 100 | round) / 10 | tostring) + "k")
    else (((. / 100000 | round) / 10 | tostring) + "M") end;
  def money: if . == null then "?" else
    (. * 100 | round) as $c | "$" + (($c / 100 | floor) | tostring) + "." + (($c % 100) | if . < 10 then "0" + tostring else tostring end) end;
  def price($m): [$prices | to_entries[] | select(.key as $k | $m | startswith($k))]
    | if length == 0 then null else (max_by(.key | length) | .value) end;
  def cost($p): if $p == null then null else
    ((.input * ($p.input // 0) + .output * ($p.output // 0) + .cw5 * ($p.cache_write_5m // 0)
      + .cw1 * ($p.cache_write_1h // 0) + .cr * ($p.cache_read // 0)) / 1000000) end;
  def sums: { input: (map(.input) | add // 0), output: (map(.output) | add // 0), cw5: (map(.cw5) | add // 0),
    cw1: (map(.cw1) | add // 0), cr: (map(.cr) | add // 0) };
  def fin: . + { cache_write: (.cw5 + .cw1), cache_read: .cr, total: (.input + .output + .cw5 + .cw1 + .cr) };
  def costsum: map(.cost) | map(select(. != null)) | add // 0;

  ([ $raw | split("\n")[] | select(length > 0) | split("\t")
     | { ts: (.[0] | tonumber), session: .[1], feature: .[2], phase: (.[3] // "-") } ] | sort_by(.ts)) as $marks
  | ($recs | to_entries | map(.value + { k: (if .value.id == "" then "n\(.key)" else .value.id end) })
     | group_by(.k) | map(max_by(.output))) as $msgs
  | [ $msgs[] | . as $r
      | ([ $marks[] | select(.session == $r.session) ]) as $sm
      | (([ $sm[] | select(.ts <= $r.ts) ] | last) // $sm[0]) as $m
      | select($m != null and $m.feature == $f) | . + { phase: $m.phase } ] as $kept
  | if ($kept | length) == 0 then
      (if $mode == "json" then
        { feature: $f, empty: true, partial: $partial, sessions: $sessions, rows: [], models: [], unknown_models: [],
          total: { input: 0, output: 0, cache_write: 0, cache_read: 0, total: 0, cost: 0 } }
       else "No token usage data found for \($f)." end)
    else
      ($kept | group_by(.phase) | map({ key: .[0].phase, value: (map(.ts) | min) }) | from_entries) as $pf
      | ($kept | group_by([.phase, .agent, .model])
         | map({ phase: .[0].phase, agent: .[0].agent, model: .[0].model } + sums | fin
                | . + { cost: cost(price(.model)) })
         | sort_by([$pf[.phase], -.total])) as $rows
      | ($rows | group_by(.model) | map({ model: .[0].model } + sums | fin
           | . as $x | . + { cost: ($rows | map(select(.model == $x.model)) | if (map(.cost) | index(null)) then null else costsum end) })) as $models
      | ($rows | sums | fin) as $t
      | ($rows | map(select(.cost == null) | .model) | unique) as $unknown
      | ($t + { cost: ($rows | costsum) }) as $total
      | if $mode == "json" then
          { feature: $f, partial: $partial, sessions: $sessions, messages: ($kept | length),
            rows: ($rows | map(del(.cw5, .cw1, .cr))), models: ($models | map(del(.cw5, .cw1, .cr))), unknown_models: $unknown,
            total: ($total | del(.cw5, .cw1, .cr)) }
        else
          ([ "## Token usage: \($f)", "",
             "Estimate at API list prices (a Claude subscription is billed differently)."
             + (if $partial then " Partial: no phase marks were recorded, so only the owner session is counted and it is not split by phase." else "" end),
             "",
             "| Phase | Agent | Model | Input | Output | Cache write | Cache read | Total | Cost |",
             "|---|---|---|---:|---:|---:|---:|---:|---:|" ]
           + [ $rows[] | "| \(.phase) | \(.agent) | \(.model) | \(.input | hn) | \(.output | hn) | \(.cache_write | hn) | \(.cache_read | hn) | \(.total | hn) | \(.cost | money) |" ]
           + [ "", "| Model | Input | Output | Cache write | Cache read | Total | Cost |", "|---|---:|---:|---:|---:|---:|---:|" ]
           + [ $models[] | "| \(.model) | \(.input | hn) | \(.output | hn) | \(.cache_write | hn) | \(.cache_read | hn) | \(.total | hn) | \(.cost | money) |" ]
           + [ "", "**Total:** \($total.total | hn) tokens (input \($total.input | hn), output \($total.output | hn), cache write \($total.cache_write | hn), cache read \($total.cache_read | hn)), about \($total.cost | money)"
               + (if ($unknown | length) > 0 then " (without the models that have no price)" else "" end) ]
           + [ $unknown[] | "", "Note: no price for model `\(.)`; its cost is not counted. Add it under `pricing` in `.claude/workflow.json`." ]
          ) | join("\n")
        end
    end' 2>/dev/null)" || result=""

[[ -n "$result" ]] || { echo "No token usage data found for $feature."; exit 0; }
printf '%s\n' "$result"
if [[ -n "$out" && "$result" != "No token usage data"* ]] && ! grep -q '"empty": true' <<<"$result"; then
  mkdir -p "$(dirname "$out")" 2>/dev/null && printf '%s\n' "$result" >"$out" 2>/dev/null
fi
exit 0
