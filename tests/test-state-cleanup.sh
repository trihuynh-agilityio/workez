#!/usr/bin/env bash
# next-phase.sh (one state per feature) and cleanup-feature.sh, in a throwaway repository.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/app"; cd "$T/app"
git config user.email t@example.com; git config user.name test
mkdir -p .claude/workflow
jq '.github.remote = "origin" | .branches.base = "main" | .docs_dir = "specs"' "$SRC/templates/workflow.example.json" >.claude/workflow.json
printf '.claude/workflow/\n.claude/worktrees/\n' >.gitignore
echo base >README.md; git add -A; git commit -q -m init
git remote add origin "$T/remote.git"
seed() { git --git-dir="$T/remote.git" fetch -q "$T/app" "+$1:$1"; git fetch -q origin "$1" 2>/dev/null; }
seed main
W=.claude/workflow
# The notification it runs on an allowed stop goes to $T/notify.out (the transcript ran a workez skill).
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"workez:plan-feature"}}]}}' >"$T/wz.jsonl"
hook() { echo "{\"stop_hook_active\": ${1:-false}, \"transcript_path\": \"$T/wz.jsonl\"}" | bash $SRC/hooks/next-phase.sh 2>"$T/notify.out"; }

# ---- next-phase.sh ----
[[ -z "$(hook)" ]] && ok "hook: no state, stop allowed" || ko "hook: no state"
[[ "$(head -n 1 "$T/notify.out")" == "app: finished" ]] && ok "hook: an allowed stop notifies" || ko "hook: notify: $(cat "$T/notify.out")"

mkdir -p $W/alpha $W/beta $W/gamma
echo '{"feature":"alpha","phase":"build","status":"waiting_review","handed_off":true}' >$W/alpha/state.json
[[ -z "$(hook)" ]] && ok "hook: waiting_review never advances" || ko "hook: waiting_review"

echo '{"feature":"beta","phase":"plan","status":"done","handed_off":false}' >$W/beta/state.json
sleep 1
echo '{"feature":"gamma","phase":"design","status":"done","handed_off":false}' >$W/gamma/state.json
out="$(hook | jq -r .reason)"
[[ "$out" == *'"beta"'*design-feature* ]] && ok "hook: oldest ready feature first (beta -> design-feature)" || ko "hook: first: $out"
[[ ! -s "$T/notify.out" ]] && ok "hook: a hand-off does not notify" || ko "hook: hand-off notified: $(cat "$T/notify.out")"
[[ "$(jq .handed_off $W/beta/state.json)" == true ]] && ok "hook: beta marked handed off" || ko "hook: mark"
[[ "$(jq .handed_off $W/gamma/state.json)" == false ]] && ok "hook: gamma untouched" || ko "hook: gamma touched"
[[ -z "$(hook true)" ]] && ok "hook: stop_hook_active lets the stop through" || ko "hook: stop_hook_active"
out="$(hook | jq -r .reason)"
[[ "$out" == *'"gamma"'*write-plan* ]] && ok "hook: next stop hands off gamma -> write-plan" || ko "hook: second: $out"
[[ -z "$(hook)" ]] && ok "hook: nothing left" || ko "hook: repeat"

rm -rf $W/alpha $W/beta $W/gamma
echo '{"feature":"legacy","phase":"build","status":"done","handed_off":false}' >$W/state.json
[[ -z "$(hook)" && "$(jq .handed_off $W/state.json)" == false ]] && ok "hook: a state.json outside a feature folder is ignored" || ko "hook: top-level state read"
rm -f $W/state.json
grep -q 'block:handoff-to-write-plan state={"feature":"gamma"' $W/hook.log && ok "hook: log names the feature" || ko "hook: log"
n="$(wc -l <$W/hook.log)"; hook >/dev/null
(($(wc -l <$W/hook.log) == n + 1)) && ok "hook: a short log is only appended to" || ko "hook: short log"
for i in $(seq 1 1200); do echo "old line $i"; done >$W/hook.log
hook >/dev/null
[[ "$(wc -l <$W/hook.log | tr -d ' ')" == 500 && "$(tail -n 1 $W/hook.log)" == *"decision=allow:not-ready"* ]] \
  && grep -q '^old line 702$' $W/hook.log && ! grep -q '^old line 701$' $W/hook.log \
  && ok "hook: a log past 1000 lines keeps its last 500" || ko "hook: log trim ($(wc -l <$W/hook.log) lines)"
[[ -z "$(ls $W/hook.log.* 2>/dev/null)" ]] && ok "hook: no temp file left" || ko "hook: temp file left"

# ---- cleanup-feature.sh ----
# Integration branch with three tasks: T1 merged (clean worktree, with untracked review/evidence
# records), T2 merged but with uncommitted work, T3 not merged.
git branch -q feat/7-demo main
mkdir -p specs/demo
cat >specs/demo/plan.md <<'EOF'
# Plan: Demo
Status: approved.

## Wave 0

## T1: One  [ ]
- **Branch**: `feat/8-one`
- **PR target**: `feat/7-demo`

## T2: Two  [ ]
- **Branch**: `feat/9-two`
- **PR target**: `feat/7-demo`

## T3: Three  [ ]
- **Branch**: `feat/10-three`
- **PR target**: `feat/7-demo`
EOF
wt() { bash -c "source $SRC/scripts/lib/config.sh && wf_worktree_path $1"; }
for b in feat/8-one feat/9-two feat/10-three; do
  git worktree add -q -b "$b" "$(wt "$b")" feat/7-demo
  echo "$b" >"$(wt "$b")/${b##*/}.txt"; git -C "$(wt "$b")" add -A; git -C "$(wt "$b")" commit -q -m "$b"
done
W1="$(wt feat/8-one)"; W2="$(wt feat/9-two)"; W3="$(wt feat/10-three)"
mkdir -p "$W1/specs/demo/reviews" "$W1/specs/demo/evidence/T1"; echo r >"$W1/specs/demo/reviews/T1.md"; echo p >"$W1/specs/demo/evidence/T1/01.png"
git worktree add -q "$T/int" feat/7-demo
git -C "$T/int" merge -q --no-ff -m "merge one" feat/8-one; git -C "$T/int" merge -q --no-ff -m "merge two" feat/9-two
git worktree remove "$T/int"
seed feat/7-demo
echo dirty >>"$W2/9-two.txt"

out="$($SRC/scripts/cleanup-feature.sh demo --task T1 --dry-run)"
[[ "$out" == *"WOULD REMOVE worktree"*"WOULD REMOVE branch feat/8-one"* && -d "$W1" ]] && ok "cleanup --dry-run: lists, removes nothing" || ko "dry-run: $out"
out="$($SRC/scripts/cleanup-feature.sh demo --task T1)"
[[ ! -d "$W1" ]] && ! git show-ref -q --verify refs/heads/feat/8-one && ok "cleanup --task T1: merged clean task removed (records ignored)" || ko "task T1: $out"
out="$($SRC/scripts/cleanup-feature.sh demo --task T2)"
[[ -d "$W2" && "$out" == *"KEPT worktree"*"uncommitted"* ]] && git show-ref -q --verify refs/heads/feat/9-two && ok "cleanup --task T2: dirty worktree and its branch kept" || ko "task T2: $out"
git -C "$W2" checkout -q -- 9-two.txt
out="$($SRC/scripts/cleanup-feature.sh demo --task T3)"
[[ ! -d "$W3" && "$out" == *"KEPT branch feat/10-three"*"not contained"* ]] && git show-ref -q --verify refs/heads/feat/10-three && ok "cleanup --task T3: clean worktree removed, unmerged branch kept" || ko "task T3: $out"

# Whole feature: evidence worktree (pushed), runtime, local evidence and reviews, Playwright output.
EV="$(wt feat/7-demo-evidence)"
git worktree add -q --orphan -b feat/7-demo-evidence "$EV"; echo s >"$EV/s.png"; git -C "$EV" add -A; git -C "$EV" commit -q -m shots
seed feat/7-demo-evidence
mkdir -p $W/demo $W/playwright-a specs/demo/evidence/verify specs/demo/reviews
echo '{"feature":"demo","phase":"verify","status":"in_progress","handed_off":true}' >$W/demo/state.json
echo x >$W/playwright-a/shot.png; echo v >specs/demo/evidence/verify/verification.md
mkdir -p $W/other; echo '{"feature":"other","phase":"plan","status":"in_progress","handed_off":true}' >$W/other/state.json
out="$($SRC/scripts/cleanup-feature.sh demo)"
[[ ! -d "$W2" ]] && ! git show-ref -q --verify refs/heads/feat/9-two && ok "cleanup feature: remaining merged task removed" || ko "feature T2: $out"
[[ ! -d "$EV" ]] && ! git show-ref -q --verify refs/heads/feat/7-demo-evidence && ok "cleanup feature: pushed evidence worktree and branch removed" || ko "feature evidence: $out"
[[ ! -d $W/demo && ! -d specs/demo/evidence && ! -d specs/demo/reviews ]] && ok "cleanup feature: runtime, evidence, reviews removed" || ko "feature dirs: $out"
[[ -f $W/playwright-a/shot.png && "$out" == *"KEPT Playwright output"* ]] && ok "cleanup feature: Playwright output kept while another feature runs" || ko "playwright kept: $out"
[[ -d $W/other ]] && ok "cleanup feature: other feature's state untouched" || ko "other state"
git ls-remote --heads origin | grep -q 'feat/7-demo$' && git ls-remote --heads origin | grep -q 'feat/7-demo-evidence' \
  && ok "cleanup feature: remote branches untouched" || ko "remote branches"
git show-ref -q --verify refs/heads/feat/10-three && ok "cleanup feature: unmerged branch still kept" || ko "unmerged kept"
git show-ref -q --verify refs/heads/feat/7-demo && [[ "$out" == *"KEPT branch feat/7-demo "*"final PR not merged"* ]] \
  && ok "cleanup feature: integration branch kept before the final PR is merged" || ko "integration kept: $out"
rm -rf $W/other
$SRC/scripts/cleanup-feature.sh demo >/dev/null
[[ ! -f $W/playwright-a/shot.png ]] && ok "cleanup feature: Playwright output cleared when nothing else runs" || ko "playwright cleared"

# The final PR is merged into the base (a merge commit on the remote main): the local integration
# branch goes, the remote branches stay.
git merge -q --no-ff -m "Merge pull request" feat/7-demo; seed main   # main is checked out here
out="$($SRC/scripts/cleanup-feature.sh demo --dry-run)"
[[ "$out" == *"WOULD REMOVE branch feat/7-demo"* ]] && git show-ref -q --verify refs/heads/feat/7-demo \
  && ok "cleanup feature --dry-run: lists the merged integration branch" || ko "int dry-run: $out"
out="$($SRC/scripts/cleanup-feature.sh demo)"
! git show-ref -q --verify refs/heads/feat/7-demo && ok "cleanup feature: merged integration branch removed" || ko "int removed: $out"
git ls-remote --heads origin | grep -q 'feat/7-demo$' && ok "cleanup feature: remote integration branch untouched" || ko "remote int"
git show-ref -q --verify refs/heads/feat/10-three && [[ "$out" == *"KEPT branch feat/10-three"* ]] \
  && ok "cleanup feature: unmerged task branch still kept" || ko "unmerged after merge: $out"

# Squash merge: the base gets the change, not the commits, so the branch is kept.
git branch -q feat/11-sq main; git checkout -q feat/11-sq; echo sq >sq.txt; git add sq.txt; git commit -q -m sq; git checkout -q main
perl -pi -e 's#feat/7-demo#feat/11-sq#g' specs/demo/plan.md
git merge -q --squash feat/11-sq >/dev/null; git commit -q -m "squash"; seed main
out="$($SRC/scripts/cleanup-feature.sh demo)"
git show-ref -q --verify refs/heads/feat/11-sq && [[ "$out" == *"KEPT branch feat/11-sq"*"squash"* ]] \
  && ok "cleanup feature: squash-merged integration branch kept" || ko "squash: $out"

# A standalone task (build-task): the plan is in the runtime folder and the PR target is the base.
# Merged into main: the task goes, main and its runtime stay apart, the task's evidence branch goes.
git branch -q feat/20-solo main
SW="$(wt feat/20-solo)"; git worktree add -q "$SW" feat/20-solo
echo solo >"$SW/solo.txt"; git -C "$SW" add -A; git -C "$SW" commit -q -m solo
git merge -q --no-ff -m "Merge solo" feat/20-solo; seed main
SEV="$(wt feat/20-solo-evidence)"
git worktree add -q --orphan -b feat/20-solo-evidence "$SEV"; echo s >"$SEV/s.png"; git -C "$SEV" add -A; git -C "$SEV" commit -q -m shots
seed feat/20-solo-evidence
mkdir -p $W/solo
printf '# Task: Solo\nStatus: approved.\n\n## T1: solo  [ ]\n- **Branch**: `feat/20-solo`\n- **PR target**: `main`\n' >$W/solo/plan.md
echo '{"feature":"solo","phase":"task","status":"done","handed_off":true}' >$W/solo/state.json
[[ -z "$(hook)" ]] && ok "hook: a standalone task never advances" || ko "hook: task phase"
out="$($SRC/scripts/cleanup-feature.sh solo)"
[[ ! -d "$SW" ]] && ! git show-ref -q --verify refs/heads/feat/20-solo && ok "cleanup task: merged standalone task removed" || ko "solo task: $out"
git show-ref -q --verify refs/heads/main && [[ "$out" != *"branch main"* ]] && ok "cleanup task: the base branch is never removed" || ko "solo base: $out"
[[ ! -d "$SEV" ]] && ! git show-ref -q --verify refs/heads/feat/20-solo-evidence && ok "cleanup task: the task's evidence branch removed" || ko "solo evidence: $out"
[[ ! -d $W/solo ]] && ok "cleanup task: runtime folder with its plan removed" || ko "solo runtime: $out"

done_tests
