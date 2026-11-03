#!/usr/bin/env bash
# Conventional Commits: the helpers, the check-conventions hook, check-task.sh on a task's commits,
# and the behaviour without conventions (branches.prefix only).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; mkdir -p "$T/app/.claude"; cd "$T/app"
jq '.github.remote = "origin" | .branches.base = "main" | .docs_dir = "specs"' \
  "$SRC/templates/workflow.example.json" >.claude/workflow.json
echo x >README.md; git add -A; git commit -q -m "chore: init"

# 1. The helpers.
c() { bash -c 'source "$SRC/scripts/lib/config.sh" && wf_commit_ok "$1"' _ "$1" >/dev/null; echo $?; }
for s in "feat: add the save button" "fix(api): reject empty queries" "feat(ui)!: drop the old dialog" \
  "docs: add approved intent, spec" "revert: undo the save button" "Merge branch 'main' into feat/1-x"; do
  [[ "$(c "$s")" == 0 ]] && ok "commit ok: $s" || ko "commit rejected: $s"
done
for s in "Add the save button" "feature: add form" "feat:add form" "feat(UI): add form" "feat: add form." \
  "feat: $(printf 'x%.0s' {1..80})"; do
  [[ "$(c "$s")" == 1 ]] && ok "commit rejected: ${s:0:40}" || ko "commit accepted: $s"
done
b() { bash -c 'source "$SRC/scripts/lib/config.sh" && wf_branch_ok "$1"' _ "$1" >/dev/null; echo $?; }
[[ "$(b feat/12-save-button)" == 0 && "$(b fix/13-x)" == 0 && "$(b test/14-acceptance)" == 0 ]] && ok "branch ok: <type>/..." || ko "branch types"
[[ "$(b feature/12-x)" == 1 && "$(b my-branch)" == 1 && "$(b feat/)" == 1 ]] && ok "branch rejected: unknown type, no type, empty name" || ko "branch rejects"

# 2. The hook.
h() { jq -n --arg c "$1" --arg d "$T/app" '{tool_input:{command:$c},cwd:$d}' | bash "$SRC/hooks/check-conventions.sh" >/dev/null 2>&1; echo $?; }
expect() { [[ "$(h "$2")" == "$1" ]] && ok "hook: $2 -> $1" || ko "hook: $2 -> expected $1"; }
expect 0 'git commit -m "feat(api): add searches route" -m "Body." -m "Refs: #12"'
expect 2 'git commit -m "Add searches route"'
expect 2 "git -C /tmp/x commit -q -m 'wip'"
expect 0 'git commit -F msg.txt'
expect 0 'git commit -m "$(cat msg.txt)"'
expect 0 'git checkout -b fix/12-negative-amounts'
expect 2 'git checkout -b my-feature'
expect 2 'git switch -c hotfix-1'
expect 0 'git worktree add -q -b test/9-acceptance .claude/worktrees/x feat/7-demo'
expect 2 'git worktree add -b wip .claude/worktrees/x main'
expect 0 'git branch -d old-branch'
expect 2 'git branch stuff'
expect 0 'git status && git log --oneline'
expect 0 'echo "git commit -m bad"'

# 3. check-task.sh: branch and commit subjects of a task.
cat >"$T/plan.md" <<'P'
## T1: add notes  [ ]
- **Files**: `notes.txt` (new)
- **Branch**: `feat/12-notes`
- **PR target**: `main`
P
git checkout -q -b feat/12-notes
echo hi >notes.txt; git add notes.txt; git commit -q -m "Add notes"
out="$("$SRC/scripts/check-task.sh" T1 "$T/plan.md" 2>&1)"
[[ "$out" == *"commit subject 'Add notes' must be"* ]] && ok "check-task: non-conventional commit fails" || ko "check-task bad commit: $out"
git commit -q --amend -m "feat: add notes"
out="$("$SRC/scripts/check-task.sh" T1 "$T/plan.md" 2>&1)"
[[ "$out" == *PASS* ]] && ok "check-task: conventional commit passes" || ko "check-task good commit: $out"
# A stale local base: the task is cut from the newer origin/main, so the newer commits are not the task's.
git checkout -q main; git update-ref refs/remotes/origin/main main
git checkout -q -b tmp-ahead; echo a >other.txt; git add other.txt; git commit -q -m "feat: add other"
git update-ref refs/remotes/origin/main HEAD; git checkout -q main; git branch -q -D tmp-ahead
git checkout -q -b feat/13-notes origin/main
echo hi >notes.txt; git add notes.txt; git commit -q -m "feat: add notes"
sed 's#feat/12-notes#feat/13-notes#' "$T/plan.md" >"$T/plan2.md"
out="$("$SRC/scripts/check-task.sh" T1 "$T/plan2.md" 2>&1)"
[[ "$out" == *PASS*"against origin/main"* ]] && ok "check-task: a stale local base compares with the remote one" || ko "check-task stale base: $out"
git checkout -q feat/12-notes

# 4. setup-project.sh and doctor.sh with conventions: a push rule per type, naming checked.
bash "$SRC/scripts/setup-project.sh" >/dev/null
jq -e '.permissions.allow | (index("Bash(git push origin fix/*)") and index("Bash(git push -u origin test/*)"))' .claude/settings.json >/dev/null \
  && ok "setup: push rules for every type" || ko "setup push rules: $(jq -c .permissions.allow .claude/settings.json)"
out="$(bash "$SRC/scripts/doctor.sh" --offline 2>&1)"
[[ "$out" == *"OK    conventions"* && "$out" == *"OK    branch naming"* && "$out" == *"OK    commit and PR titles"* ]] \
  && ok "doctor: conventions, branch naming, titles" || ko "doctor conventions: $out"
cp .claude/workflow.json "$T/keep.json"
jq '.naming.task_commit = "{task_title}" | .naming.task_branch = "task/{task_issue}"' "$T/keep.json" >.claude/workflow.json
out="$(bash "$SRC/scripts/doctor.sh" --offline 2>&1)"
[[ "$out" == *"FAIL  branch naming"*task_branch* && "$out" == *"FAIL  commit and PR titles"*task_commit* ]] \
  && ok "doctor: non-conventional naming fails" || ko "doctor bad naming: $out"
cp "$T/keep.json" .claude/workflow.json

# 5. Without conventions: branches.prefix only, commit subjects free.
git checkout -q main
jq 'del(.conventions) | .branches.prefix = "feat/" | .naming.task_branch = "feat/{task_issue}-{task_slug}"' .claude/workflow.json >"$T/w" && mv "$T/w" .claude/workflow.json
expect 0 'git commit -m "Add anything"'
expect 0 'git checkout -b my-feature'
[[ "$(c "Add anything")" == 0 && "$(b feat/1-x)" == 0 && "$(b fix/1-x)" == 1 ]] && ok "no conventions: prefix branches, free subjects" || ko "no conventions"

done_tests
