#!/usr/bin/env bash
# The base branch: one resolver (wf_base), worktrees cut from <remote>/<base>, the preflight, and the
# doctor checks. The repository's default branch is main; workflow.json's base is dev, 3 commits ahead.
source "$(dirname "$0")/lib.sh"
W="$SRC/scripts/worktree.sh"

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
cd "$T/repo" || exit 1
mkdir -p .claude
cat >.claude/workflow.json <<'JSON'
{"github": {"repo": "o/r", "remote": "origin"}, "branches": {"base": "dev", "protected": ["main", "dev"]},
 "conventions": {"commit_types": ["feat", "fix"]}, "docs_dir": "docs"}
JSON
printf '.claude/workflow/\n.claude/worktrees/\n' >.gitignore
git add -A && git commit -qm "chore: init" && git push -q origin main
git switch -qc dev
for i in 1 2 3; do echo "$i" >"dev-$i.txt"; git add -A; git commit -qm "feat: dev $i"; done
git push -q origin dev
git switch -q main
git remote set-head origin main >/dev/null
# A stale local dev, behind origin/dev: the worktree must still come from origin/dev.
git branch -f dev main

# ---- wf_base ----
got="$(source "$SRC/scripts/lib/config.sh" && wf_base)"
[[ "$got" == dev ]] && ok "wf_base reads branches.base" || ko "wf_base reads branches.base (got $got)"
cp .claude/workflow.json "$T/wf.json"
jq 'del(.branches.base)' "$T/wf.json" >.claude/workflow.json
got="$(source "$SRC/scripts/lib/config.sh" && wf_base)"
[[ "$got" == main ]] && ok "wf_base falls back to the remote default" || ko "wf_base fallback (got $got)"
out="$(bash "$W" base)"
grep -q '^SOURCE=default' <<<"$out" && ok "worktree.sh base says default" || ko "worktree.sh base source: $out"
cp "$T/wf.json" .claude/workflow.json
out="$(bash "$W" base)"
grep -q '^BASE=dev$' <<<"$out" && grep -q '^REF=origin/dev$' <<<"$out" && ok "worktree.sh base" || ko "worktree.sh base: $out"

# ---- create: cut from origin/dev ----
out="$(bash "$W" create fix/one 2>&1)"; rc=$?
wt="$T/repo/.claude/worktrees/fix-one"
((rc == 0)) && [[ "$(git -C "$wt" rev-parse HEAD)" == "$(git rev-parse origin/dev)" ]] \
  && ok "create cuts from origin/dev, not the stale local dev" || ko "create from origin/dev (rc $rc): $out"
[[ -f "$wt/dev-3.txt" ]] && ok "worktree has the base's files" || ko "worktree misses dev-3.txt"
grep -q '^CREATED=yes' <<<"$out" && ok "create reports a new worktree" || ko "CREATED line: $out"
out="$(bash "$W" create fix/one 2>&1)"; rc=$?
((rc == 0)) && grep -q '^CREATED=no' <<<"$out" && ok "create resumes an existing worktree" || ko "resume (rc $rc): $out"
bash "$W" check "$wt" >/dev/null 2>&1 && ok "check passes on a good worktree" || ko "check on a good worktree"

# ---- the preflight fails loudly on a worktree cut from main ----
git worktree add -q -b fix/two .claude/worktrees/fix-two origin/main
out="$(bash "$W" check .claude/worktrees/fix-two 2>&1)"; rc=$?
((rc == 3)) && ok "check fails on a worktree cut from main" || ko "check exit $rc: $out"
grep -q 'origin/dev' <<<"$out" && grep -q 'misses 3 commit' <<<"$out" && grep -q "HEAD $(git rev-parse --short origin/main)" <<<"$out" \
  && ok "the message names the base, HEAD and the missing commits" || ko "message: $out"
grep -qi 'reset' <<<"$out" && grep -q 'Do not reset' <<<"$out" && ok "the message says recreate, not reset" || ko "remedy: $out"
out="$(bash "$W" create fix/two 2>&1)"; rc=$?
((rc == 3)) && [[ -d .claude/worktrees/fix-two ]] && ok "create refuses to build in a bad existing worktree, keeps it" || ko "bad resume (rc $rc): $out"
out="$(bash "$W" check fix/two 2>&1)"; rc=$?
((rc == 3)) && ok "check works on a branch name too" || ko "check branch (rc $rc): $out"

# ---- a feature task: cut from its integration branch, checked against it ----
git branch --no-track feat/demo origin/dev
out="$(bash "$W" create fix/three --from feat/demo 2>&1)"; rc=$?
((rc == 0)) && [[ "$(git -C .claude/worktrees/fix-three rev-parse HEAD)" == "$(git rev-parse feat/demo)" ]] \
  && ok "create --from an unpushed integration branch" || ko "create --from (rc $rc): $out"

# ---- doctor: plans and worktrees against branches.base ----
mkdir -p .claude/workflow/one .claude/workflow/two
plan() { printf '# Task: x\nStatus: approved.\n\n## T1: x  [ ]\n- **Branch**: `%s`\n- **PR target**: `%s`\n' "$1" "$2"; }
plan fix/one dev >.claude/workflow/one/plan.md
plan fix/two dev >.claude/workflow/two/plan.md
out="$(bash "$SRC/scripts/doctor.sh" --offline 2>&1)"
grep -q '^FAIL  task worktrees .*fix-two.*misses 3 commit' <<<"$out" && ok "doctor fails a task worktree cut from main" || ko "doctor worktree: $(grep 'task worktrees' <<<"$out")"
grep -q '^OK    plan PR targets' <<<"$out" && ok "doctor accepts plans that target the base" || ko "doctor plans: $(grep 'plan PR' <<<"$out")"
plan fix/two main >.claude/workflow/two/plan.md
out="$(bash "$SRC/scripts/doctor.sh" --offline 2>&1)"
grep -q '^FAIL  plan PR targets .*(main)' <<<"$out" && ok "doctor fails a standalone plan that targets main" || ko "doctor main plan: $(grep 'plan PR' <<<"$out")"
git worktree remove --force .claude/worktrees/fix-two && git branch -qD fix/two
plan fix/two dev >.claude/workflow/two/plan.md
out="$(bash "$SRC/scripts/doctor.sh" --offline 2>&1)"
grep -q '^OK    task worktrees' <<<"$out" && ok "doctor passes once the worktree is recreated" || ko "doctor after fix: $(grep 'task worktrees' <<<"$out")"

# ---- no script reads the base around wf_base, and nothing hard-codes main as a base ----
# (Only asking whether the key is set, as doctor.sh and worktree.sh do, is fine.)
hits="$(grep -rn 'cfg \.branches\.base' "$SRC/scripts" "$SRC/hooks" --include=*.sh | grep -v 'scripts/lib/config.sh:' |
  grep -vF -- '-n "$(cfg .branches.base)"' || true)"
[[ -z "$hits" ]] && ok "scripts take the base from wf_base" || ko "scripts read branches.base directly: $hits"
hits="$(grep -rnE 'origin/(main|master)|--base (main|master)' "$SRC/scripts" "$SRC/hooks" "$SRC/skills" "$SRC/agents" || true)"
[[ -z "$hits" ]] && ok "no hard-coded origin/main" || ko "hard-coded main: $hits"

done_tests
