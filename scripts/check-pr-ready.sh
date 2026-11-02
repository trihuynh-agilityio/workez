#!/usr/bin/env bash
# PR gate for one task. Exits 1, printing every problem, unless the task is ready for its pull request.
#   check-pr-ready.sh <task-id> [plan-path]
# Run from the task's worktree, inside its project folder. The plan is not in the worktree
# while it is untracked, so pass its path.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
docs="$(cfg .docs_dir)"; remote="$(cfg .github.remote)"

task="${1:-}"
plan="${2:-}"
[[ -n "$task" ]] || { echo "usage: check-pr-ready.sh <task-id> [plan-path]" >&2; exit 2; }
if [[ -z "$plan" ]]; then
  plan="$(grep -l -E "^## ${task}: " "$docs"/*/plan.md "$docs"/*/plan-fix.md 2>/dev/null | head -1)"
fi
[[ -f "$plan" ]] || { echo "check-pr-ready: plan not found; pass its path as the second argument" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
feature="$(basename "$(dirname "$plan")")"

block="$(awk -v t="$task" 'index($0, "## " t ": ") == 1 { f = 1; next } f && /^## / { exit } f' "$plan")"
[[ -n "$block" ]] || { echo "check-pr-ready: task $task not found in $plan" >&2; exit 2; }

field() { grep -m1 "^- \*\*$1\*\*:" <<<"$block" | sed -E 's/^- \*\*[^*]+\*\*: *//'; }
ticks() { grep -o '`[^`]*`' | tr -d '`'; }

branch="$(field Branch | ticks | head -1)"
base="$(field 'PR target' | ticks | head -1)"
issue="$(field Issue)"

fail=0
bad() { echo "NOT READY: $1" >&2; fail=1; }

# 1. Branch and a clean tree.
current="$(git rev-parse --abbrev-ref HEAD)"
[[ "$current" == "$branch" ]] || bad "branch is $current; the plan says $branch"
# The review report and the UI evidence (result.md included) are never committed; a task branch cut
# before .gitignore covered them shows them as untracked.
dirty="$(git status --porcelain --untracked-files=all | grep -vE "^\?\? (.*/)?$docs/[^/]+/reviews/$task\.md$" |
  grep -vE "^\?\? (.*/)?$docs/[^/]+/evidence/$task/" || true)"
[[ -z "$dirty" ]] || bad "the working tree is not clean (commit or remove: $(head -3 <<<"$dirty" | tr '\n' ' '))"

# 2. The sub-issue exists.
[[ "$issue" =~ ^#[0-9]+$ ]] || bad "Issue is '${issue:-missing}', not a sub-issue number; run create-task-issues first"

# 3. Size and file guard.
out="$("$here/check-task.sh" "$task" "$plan" 2>&1)" || bad "check-task.sh failed: $out"

# 4. Review gate.
out="$("$here/check-review.sh" "$task" "$plan" 2>&1)" || bad "check-review.sh failed: $out"

# 5. UI check evidence, only for a task that has one.
if grep -q '^- \*\*UI check\*\*' <<<"$block"; then
  result="$docs/$feature/evidence/$task/result.md"
  if [[ ! -f "$result" ]]; then
    bad "the task has a UI check but $result does not exist"
  elif git ls-files --error-unmatch "$result" >/dev/null 2>&1; then
    bad "$result is committed; it stays local and its content goes into the PR description"
  else
    overall="$(grep -m1 -E '^Overall:' "$result" | sed -E 's/^Overall: *//')"
    ui_commit="$(grep -m1 -E '^Commit:' "$result" | sed -E 's/^Commit: *//')"
    code_head="$("$here/code-head.sh" 2>/dev/null)"
    [[ "$overall" == "PASS" ]] || bad "UI check result is '${overall:-missing}', not PASS"
    if [[ -z "$ui_commit" || -z "$code_head" || "$code_head" != "$ui_commit"* ]]; then
      bad "UI check ran on ${ui_commit:-an unknown commit}, not CODE_HEAD ${code_head:0:10}; run it again"
    fi
  fi
fi

# 6. The PR base must exist on GitHub.
git ls-remote --exit-code --heads "$remote" "$base" >/dev/null 2>&1 || bad "base branch $base is not on the $remote remote; push it first (it is never pushed from here)"

if ((fail)); then
  echo "check-pr-ready $task: NOT READY" >&2
  exit 1
fi
echo "check-pr-ready $task: READY (branch $branch, base $base, issue $issue)"
