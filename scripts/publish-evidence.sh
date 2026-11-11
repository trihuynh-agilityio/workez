#!/usr/bin/env bash
# Publishes one task's UI-check screenshots to the feature's evidence branch and prints Markdown
# image lines for the PR description. The evidence branch is an orphan branch that is never merged,
# so task PRs carry no evidence files while reviewers still see the screenshots inline.
#   publish-evidence.sh <task-id> <evidence-dir> <integration-branch>
# Run from anywhere inside the repository. The branch is <integration-branch>-evidence, its
# worktree <repo root>/.claude/worktrees/<branch with / replaced by ->, and the task's files live
# in <task-id>/ there. Pushes only that branch, never with force.

set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
wf_local && { echo "publish-evidence: the local tracker keeps evidence local; list its files in the merge request text instead" >&2; exit 2; }
repo="$(cfg .github.repo)"; remote="$(wf_remote)"

task="${1:-}"; dir="${2:-}"; base="${3:-}"
[[ -n "$task" && -d "$dir" && -n "$base" ]] || { echo "usage: publish-evidence.sh <task-id> <evidence-dir> <integration-branch>" >&2; exit 2; }
why="$(wf_branch_ok "$base")" || { echo "publish-evidence: integration $why" >&2; exit 2; }

branch="$base-evidence"
top="$WF_TOP"
wt="$(wf_worktree_path "$branch")"

shopt -s nullglob
images=("$dir"/*.png "$dir"/*.jpg "$dir"/*.gif)
((${#images[@]})) || { echo "publish-evidence: no images in $dir" >&2; exit 1; }

if [[ ! -d "$wt" ]]; then
  if git -C "$top" ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    git -C "$top" fetch -q "$remote" "$branch:$branch"
    git -C "$top" worktree add -q "$wt" "$branch"
  else
    git -C "$top" worktree add -q --orphan -b "$branch" "$wt"
  fi
fi

# Replace this task's folder only; other tasks' screenshots stay.
rm -rf "${wt:?}/$task"
mkdir -p "$wt/$task"
cp "${images[@]}" "$wt/$task/"
git -C "$wt" add -A "$task"
if ! git -C "$wt" diff --cached --quiet; then
  msg=(-m "chore(evidence): add UI check screenshots" -m "Task $task.")
  trailers="$(wf_trailers)"; [[ -n "$trailers" ]] && msg+=(-m "$trailers")
  git -C "$wt" commit -q "${msg[@]}"
fi
(cd "$wt" && git push -q -u "$remote" "$branch")

sha="$(git -C "$wt" rev-parse HEAD)"
for f in "$wt/$task"/*; do
  name="$(basename "$f")"
  echo "**${name%.*}**"
  echo
  echo "![${name%.*}](https://github.com/$repo/blob/$sha/$task/$name?raw=true)"
  echo
done
