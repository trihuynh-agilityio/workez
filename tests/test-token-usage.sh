#!/usr/bin/env bash
# token-usage.sh: tokens and API-equivalent cost of a feature from fake transcripts, in a throwaway project.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; cd "$T/app"
mkdir -p .claude
cp "$SRC/templates/workflow.example.json" .claude/workflow.json
export WF_CLAUDE_PROJECTS="$T/claude/projects"
P="$WF_CLAUDE_PROJECTS/-proj"; mkdir -p "$P/s1/subagents"
T0=1767225600   # 2026-01-01T00:00:00Z

# line <id> <iso time> <model> <usage json>: one assistant transcript line.
line() { jq -n -c --arg id "$1" --arg ts "$2" --arg m "$3" --argjson u "$4" \
  '{type: "assistant", timestamp: $ts, message: {id: $id, model: $m, role: "assistant", usage: $u}}'; }
{
  line msg_before 2025-12-31T23:59:00.000Z claude-opus-4-8 '{"input_tokens":7000,"output_tokens":7000}'
  line msg_1 2026-01-01T00:00:10.000Z claude-opus-4-8 '{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10000}'
  line msg_1 2026-01-01T00:00:10.500Z claude-opus-4-8 '{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10000}'
  line msg_2 2026-01-01T00:02:30.000Z claude-sonnet-4-6 '{"input_tokens":50,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":600},"cache_read_input_tokens":2000}'
  line msg_3 2026-01-01T00:02:40.000Z claude-mystery-1 '{"input_tokens":10,"output_tokens":20}'
  line msg_syn 2026-01-01T00:02:45.000Z "<synthetic>" '{"input_tokens":9000,"output_tokens":9000}'
  echo '{"type":"user","timestamp":"2026-01-01T00:02:46.000Z","message":{"content":"hi"}}'
  line msg_late 2026-01-01T00:06:40.000Z claude-opus-4-8 '{"input_tokens":1000000,"output_tokens":0}'
  printf '{"type":"assistant","message":{"usage":'   # a line cut short, like a live transcript
} >"$P/s1.jsonl"
line sub_1 2026-01-01T00:02:00.000Z claude-haiku-4-5 '{"input_tokens":1000,"output_tokens":500}' >"$P/s1/subagents/agent-a1.jsonl"
echo '{"agentType":"workez:github-ops","model":"haiku"}' >"$P/s1/subagents/agent-a1.meta.json"

W=.claude/workflow
mkdir -p $W/alpha $W/beta
printf '%s\ts1\tplan\t%s\n%s\ts1\tbuild\t%s\n' "$T0" "$P/s1.jsonl" $((T0 + 100)) "$P/s1.jsonl" >$W/alpha/sessions.tsv
printf '%s\ts1\tplan\t%s\n' $((T0 + 300)) "$P/s1.jsonl" >$W/beta/sessions.tsv
tu() { bash "$SRC/scripts/token-usage.sh" "$@" 2>&1; }

# alpha: opus 25300 (msg_before, before the first mark, counts for the first marked feature) + sonnet 3150 + haiku subagent 1500 + unknown model 30; the late message is beta's.
j="$(tu alpha --json)"
[[ "$(jq -r '.total.total' <<<"$j")" == 29980 ]] && ok "tokens: total (deduplicated, window, before the first mark, no synthetic)" || ko "tokens total: $j"
[[ "$(jq -r '[.total.input, .total.output, .total.cache_write, .total.cache_read] | join(" ")' <<<"$j")" == "8160 7820 2000 12000" ]] \
  && ok "tokens: input, output, cache write (5m+1h), cache read" || ko "tokens parts: $(jq -c .total <<<"$j")"
[[ "$(jq -r '.rows | length' <<<"$j")" == 4 ]] && ok "tokens: one row per phase x agent x model" || ko "tokens rows: $(jq -c .rows <<<"$j")"
[[ "$(jq -r '.rows[] | select(.agent == "workez:github-ops") | "\(.phase) \(.model) \(.total)"' <<<"$j")" == "build claude-haiku-4-5 1500" ]] \
  && ok "tokens: subagent row named from its meta.json, phase from the marks" || ko "tokens subagent"
[[ "$(jq -r '.rows[0] | "\(.phase) \(.agent) \(.model)"' <<<"$j")" == "plan (main) claude-opus-4-8" ]] && ok "tokens: rows start with the first phase" || ko "tokens order: $(jq -c '.rows[0]' <<<"$j")"
[[ "$(jq -r '.total.cost * 1000000 | round' <<<"$j")" == 237600 ]] && ok "cost: built-in prices (unknown model left out)" || ko "cost: $(jq -c .total <<<"$j")"
[[ "$(jq -c '.unknown_models' <<<"$j")" == '["claude-mystery-1"]' && "$(jq -r '.rows[] | select(.model == "claude-mystery-1") | .cost' <<<"$j")" == null ]] \
  && ok "cost: an unknown model has no cost and is named" || ko "unknown model: $(jq -c .unknown_models <<<"$j")"
[[ "$(jq -r '.models | length' <<<"$j")" == 4 && "$(jq -r '.partial' <<<"$j")" == false ]] && ok "tokens: per-model subtotals, not partial" || ko "models: $(jq -c .models <<<"$j")"

# The session moved on to beta at T0+300: its later message counts there.
jb="$(tu beta --json)"
[[ "$(jq -r '.total.total' <<<"$jb")" == 1000000 && "$(jq -r '.total.cost' <<<"$jb")" == 5 ]] && ok "window: a message after the take-over counts for the new feature only" || ko "beta: $jb"

# .pricing in workflow.json prices the unknown model and overrides a built-in one.
jq '.pricing = {"claude-mystery": {"input": 2, "output": 4, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0}}' .claude/workflow.json >"$T/w.json" && mv "$T/w.json" .claude/workflow.json
j="$(tu alpha --json)"
[[ "$(jq -r '.total.cost * 1000000 | round' <<<"$j")" == 237700 && "$(jq -c '.unknown_models' <<<"$j")" == '[]' ]] && ok "pricing: .pricing adds a model by prefix" || ko "pricing add: $(jq -c .total <<<"$j")"
jq '.pricing["claude-opus-4"] = {"input": 1, "output": 1, "cache_write_5m": 1, "cache_write_1h": 1, "cache_read": 1}' .claude/workflow.json >"$T/w.json" && mv "$T/w.json" .claude/workflow.json
j="$(tu alpha --json)"   # claude-opus-4-8 keeps its own, longer prefix
[[ "$(jq -r '.total.cost * 1000000 | round' <<<"$j")" == 237700 ]] && ok "pricing: the longest model prefix wins" || ko "pricing longest: $(jq -c .total <<<"$j")"

# Markdown report and --out.
OUT="$T/app/.claude/token-usage/alpha.md"
stdout="$(tu alpha --out "$OUT")"
md="$(cat "$OUT" 2>&1)"
[[ "$md" == "## Token usage: alpha"* && "$md" == *"| Phase | Agent | Model | Input | Output | Cache write | Cache read | Total | Cost |"* \
  && "$md" == *"**Total:** 30k tokens"* && "$md" == *'$0.24'* && "$md" == *"| plan | (main) | claude-opus-4-8 | 7.1k | 7.2k | 1k | 10k | 25.3k | \$0.23 |"* ]] \
  && ok "md: heading, table header, Total line, readable numbers (in the file)" || ko "md: $md"
[[ "$md" == *"API list prices"* && "$md" != *"Partial"* ]] && ok "md: says it is an estimate" || ko "md: estimate"
[[ "$stdout" == "$(grep '^\*\*Total:\*\*' "$OUT")" && "$stdout" == "**Total:** 30k tokens"* && "$stdout" != *"|"* ]] \
  && ok "out: stdout is only the Total line, the file has the report" || ko "out stdout: $stdout"
[[ "$(tu alpha)" == "$md" ]] && ok "md: without --out stdout is the full report" || ko "md: stdout without --out"

# --append: the saved report goes after a blank line, no recompute, silent.
printf 'close note\nKEPT x\n' >"$T/close.md"
ap="$(tu alpha --append "$T/close.md")"; rc=$?
[[ $rc == 0 && -z "$ap" ]] && ok "append: silent, exit 0" || ko "append: $rc $ap"
{ printf 'close note\nKEPT x\n\n'; cat "$OUT"; } >"$T/close.expect"
cmp -s "$T/close.md" "$T/close.expect" && ok "append: original content first, blank line, then the saved report" || ko "append: $(cat "$T/close.md")"
printf 'only\n' >"$T/close2.md"
mv $W/alpha/sessions.tsv "$T/sessions.tsv.bak"
tu alpha --append "$T/close2.md" >/dev/null; mv "$T/sessions.tsv.bak" $W/alpha/sessions.tsv
[[ "$(sed -n '3p' "$T/close2.md")" == "## Token usage: alpha" ]] && ok "append: works without sessions.tsv (no recompute)" || ko "append no tsv"
printf 'keep\n' >"$T/close3.md"
tu empty --append "$T/close3.md"; rc=$?
[[ $rc == 0 && "$(cat "$T/close3.md")" == "keep" ]] && ok "append: no saved report is a silent no-op" || ko "append none: $rc"
tu alpha --append x --json >/dev/null 2>&1; [[ $? == 2 ]] && ok "append: with --json exits 2" || ko "append --json"
tu alpha --append x --out y >/dev/null 2>&1; [[ $? == 2 ]] && ok "append: with --out exits 2" || ko "append --out"

# Owner fallback: one session, found by searching the projects folder, reported as partial.
mkdir -p $W/gamma
line g_1 2026-03-01T00:00:00.000Z claude-sonnet-4-6 '{"input_tokens":1000000,"output_tokens":0}' >"$WF_CLAUDE_PROJECTS/-other.jsonl.d" 2>/dev/null
mkdir -p "$WF_CLAUDE_PROJECTS/-other"; mv "$WF_CLAUDE_PROJECTS/-other.jsonl.d" "$WF_CLAUDE_PROJECTS/-other/s9.jsonl"
echo s9 >$W/gamma/owner
j="$(tu gamma --json)"
[[ "$(jq -r '"\(.partial) \(.total.total) \(.total.cost)"' <<<"$j")" == "true 1000000 3" ]] && ok "fallback: owner session, partial" || ko "fallback: $j"
[[ "$(tu gamma)" == *"Partial"* ]] && ok "fallback: the md report says partial" || ko "fallback md"

# Nothing to report: exit 0, a short message, no file.
mkdir -p $W/empty
out="$(tu empty --out "$T/app/.claude/token-usage/empty.md")"; rc=$?
[[ $rc == 0 && "$out" == "No token usage data"* && ! -e .claude/token-usage/empty.md ]] && ok "empty: exit 0, short message, no file" || ko "empty: $rc $out"
[[ "$(tu empty --json | jq -r .empty)" == true ]] && ok "empty: --json says so" || ko "empty json"

# Bad usage exits 2.
for args in "" "../x" ".hidden" "alpha --nope" "alpha --out"; do
  tu $args >/dev/null; [[ $? == 2 ]] && ok "usage: '$args' exits 2" || ko "usage: '$args'"
done

# status.sh shows the line when sessions.tsv exists.
echo '{"feature":"alpha","phase":"build","status":"in_progress","handed_off":true}' >$W/alpha/state.json
[[ "$(bash "$SRC/scripts/status.sh" alpha)" == *"tokens: 29980 (~\$0.24)"* ]] && ok "status: tokens line" || ko "status: $(bash "$SRC/scripts/status.sh" alpha)"

done_tests
