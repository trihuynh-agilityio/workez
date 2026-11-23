#!/usr/bin/env bash
# lane-result.sh (the per-lane result file), build-position.sh's LANE lines and doctor's lane_runner check,
# in a throwaway repository.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; cd "$T/app"
mkdir -p .claude
cp "$SRC/templates/workflow.example.json" .claude/workflow.json
lr() { bash "$SRC/scripts/lane-result.sh" "$@" 2>&1; }
F=.claude/workflow/demo/lane-T1.json

out="$(lr set demo T1 status=running issue=12)"; rc=$?
[[ $rc == 0 && "$out" == "SET "*".claude/workflow/demo/lane-T1.json" ]] && ok "lane: set prints SET and path" || ko "lane: set: $out"
[[ "$(jq -r .task $F)" == T1 && "$(jq -r .status $F)" == running && "$(jq -r .issue $F)" == 12 ]] && ok "lane: task and string fields" || ko "lane: fields: $(cat $F)"
[[ "$(jq -r .updated $F)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && ok "lane: updated is UTC time" || ko "lane: updated"
[[ "$(jq -r '.issue|type' $F)" == string ]] && ok "lane: = stores a string" || ko "lane: string type"

lr set demo T1 fix_rounds:=2 'settled:=["a","b"]' pr:=7 >/dev/null
[[ "$(jq -c '[.fix_rounds,.settled,.pr]' $F)" == '[2,["a","b"],7]' ]] && ok "lane: := stores json (number, array)" || ko "lane: json: $(cat $F)"
[[ "$(jq -r .status $F)" == running && "$(jq -r .issue $F)" == 12 ]] && ok "lane: merge keeps earlier fields" || ko "lane: merge"

before="$(cat $F)"
lr set demo T1 'settled:={bad' >/dev/null; rc=$?
[[ $rc == 2 && "$(cat $F)" == "$before" ]] && ok "lane: invalid json exits 2, file unchanged" || ko "lane: invalid json rc=$rc"
lr set demo T1 status=blocked 'x:=nope' >/dev/null; rc=$?
[[ $rc == 2 && "$(cat $F)" == "$before" ]] && ok "lane: one bad field writes nothing" || ko "lane: partial write"
[[ -z "$(ls -A .claude/workflow/demo | grep -v '^lane-T1.json$')" ]] && ok "lane: no temp files left" || ko "lane: leftovers: $(ls -A .claude/workflow/demo)"

lr set demo T1 Bad=x >/dev/null; [[ $? == 2 ]] && ok "lane: bad field name exits 2" || ko "lane: field name"
lr set demo T1 'a-b=x' >/dev/null; [[ $? == 2 ]] && ok "lane: field name with dash exits 2" || ko "lane: field dash"
lr set demo T1 novalue >/dev/null; [[ $? == 2 ]] && ok "lane: field without = exits 2" || ko "lane: no ="
for bad in "a/b" ".." ".hidden" ""; do
  lr set "$bad" T1 status=x >/dev/null; rc=$?
  [[ $rc == 2 ]] && ok "lane: bad feature '$bad' exits 2" || ko "lane: bad feature '$bad' rc=$rc"
done
for bad in 3 t1 T T1x; do
  lr set demo "$bad" status=x >/dev/null; rc=$?
  [[ $rc == 2 ]] && ok "lane: bad task '$bad' exits 2" || ko "lane: bad task '$bad' rc=$rc"
done
[[ "$(ls .claude/workflow)" == demo && "$(ls .claude/workflow/demo)" == lane-T1.json ]] && ok "lane: bad args create nothing" || ko "lane: created: $(ls -R .claude/workflow)"
lr set demo T1 >/dev/null; [[ $? == 2 ]] && ok "lane: set without fields exits 2" || ko "lane: no fields"

[[ "$(lr get demo T1)" == "$(jq -c . $F)" ]] && ok "lane: get prints compact json" || ko "lane: get"
[[ "$(lr get demo T1 status)" == running ]] && ok "lane: get field raw" || ko "lane: get field"
[[ "$(lr get demo T1 settled)" == '["a","b"]' ]] && ok "lane: get array as compact json" || ko "lane: get array"
out="$(lr get demo T1 reason)"; [[ $? == 0 && -z "$out" ]] && ok "lane: get missing field is empty" || ko "lane: missing field: '$out'"
lr get demo T9 >/dev/null; [[ $? == 1 ]] && ok "lane: get missing file exits 1" || ko "lane: get missing file"

# states: ordered by task number, - for missing values
out="$(lr states demo)"; [[ "$out" == "LANE T1 running 7 -" ]] && ok "lane: states line with - placeholder" || ko "lane: states: $out"
lr set demo T10 status=merged pr:=40 merge_sha=abc123 >/dev/null
lr set demo T2 pr:=9 >/dev/null
[[ "$(lr states demo | tr '\n' '|')" == "LANE T1 running 7 -|LANE T2 - 9 -|LANE T10 merged 40 abc123|" ]] && ok "lane: states sorted by task number" || ko "lane: order: $(lr states demo)"
out="$(lr states nothing)"; [[ $? == 0 && -z "$out" ]] && ok "lane: states with no lanes prints nothing" || ko "lane: empty states"

# From a linked worktree it writes to the main checkout.
echo x >f.txt; git add -A -f .; git commit -q -m init
git worktree add -q -b feat/wt "$T/wt"
( cd "$T/wt" && bash "$SRC/scripts/lane-result.sh" set wtfeat T1 status=starting >/dev/null 2>&1 )
[[ -f "$T/app/.claude/workflow/wtfeat/lane-T1.json" && ! -e "$T/wt/.claude/workflow/wtfeat" ]] && ok "lane: worktree writes to the main checkout" || ko "lane: worktree"

# ---- build-position with LANE lines ----
cat >plan.md <<'PLAN'
# Plan: Demo
Status: approved.

## Wave 0

## T1: One  [ ]
- **Lane**: A
- **Issue**: #8
- **Branch**: `feat/8-one`

## T2: Two  [ ]
- **Lane**: B
- **Issue**: #9
- **Branch**: `feat/9-two`

## Risks
PLAN
bp() { bash "$SRC/scripts/build-position.sh" plan.md "$S" | tail -2 | tr '\n' ' '; }
S="$T/s.tsv"
printf 'feat/8-one NONE\nfeat/9-two NONE\n' >"$S"
base="$(bash "$SRC/scripts/build-position.sh" plan.md "$S")"
[[ "$(bp)" == "ACTION=start TASKS=T1 T2 " ]] && ok "bp: no LANE lines, start both" || ko "bp: base $(bp)"
printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T3 running - -\n' >"$S"
[[ "$(bash "$SRC/scripts/build-position.sh" plan.md "$S")" == "$base" ]] && ok "bp: unrelated LANE line changes nothing" || ko "bp: unrelated LANE"

printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T1 running - -\n' >"$S"
[[ "$(bp)" == "ACTION=start TASKS=T2 " ]] && ok "bp: a running lane is not started again" || ko "bp: one running: $(bp)"
bash "$SRC/scripts/build-position.sh" plan.md "$S" | grep -q '^T1 .* status=running ' && ok "bp: task status running" || ko "bp: status running"
printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T1 starting - -\nLANE T2 running - -\n' >"$S"
[[ "$(bp)" == "ACTION=wait TASKS=T1 T2 " ]] && ok "bp: both lanes active, wait" || ko "bp: both: $(bp)"
printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T1 running - -\nLANE T2 blocked - -\n' >"$S"
[[ "$(bp)" == "ACTION=blocked TASKS=T2 (lane blocked or failed) " ]] && ok "bp: blocked lane blocks" || ko "bp: blocked: $(bp)"
printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T1 failed - -\n' >"$S"
[[ "$(bp)" == "ACTION=blocked TASKS=T1 (lane blocked or failed) " ]] && ok "bp: failed lane blocks" || ko "bp: failed: $(bp)"
printf 'feat/8-one CLOSED 5\nfeat/9-two NONE\nLANE T2 blocked - -\n' >"$S"
[[ "$(bp)" == "ACTION=blocked TASKS=T1 (PR closed without merge) " ]] && ok "bp: closed PR reported before lane_blocked" || ko "bp: closed first: $(bp)"
printf 'feat/8-one MERGED 5\nfeat/9-two MERGED 6\nLANE T1 running - -\nLANE T2 blocked - -\n' >"$S"
[[ "$(bp)" == "CURRENT_WAVE=none ACTION=finish " ]] && ok "bp: GitHub MERGED beats LANE" || ko "bp: merged: $(bp)"
printf 'feat/8-one OPEN 5\nfeat/9-two NONE\nLANE T1 blocked - -\n' >"$S"
[[ "$(bp)" == "ACTION=start TASKS=T2 " ]] && ok "bp: GitHub OPEN beats LANE" || ko "bp: open: $(bp)"
printf 'feat/8-one NONE\nfeat/9-two NONE\nLANE T1 stale - -\nLANE T2 pr_open 3 -\n' >"$S"
[[ "$(bp)" == "ACTION=start TASKS=T1 T2 " ]] && ok "bp: stale and pr_open lanes are ignored" || ko "bp: stale: $(bp)"

# ---- doctor: lane_runner ----
doc() { bash "$SRC/scripts/doctor.sh" --offline 2>&1 | grep 'lane_runner'; }
[[ "$(doc)" == "OK    lane_runner"*agent* ]] && ok "doctor: missing lane_runner means agent" || ko "doctor: default: $(doc)"
cp .claude/workflow.json "$T/wf.json"
jq '.lane_runner = "session"' "$T/wf.json" >.claude/workflow.json
[[ "$(doc)" == "OK    lane_runner"*session* ]] && ok "doctor: lane_runner session" || ko "doctor: session: $(doc)"
jq '.lane_runner = "pigeon"' "$T/wf.json" >.claude/workflow.json
[[ "$(doc)" == "FAIL  lane_runner"*"'pigeon'"* ]] && ok "doctor: invalid lane_runner fails" || ko "doctor: invalid: $(doc)"

done_tests
