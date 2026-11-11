#!/usr/bin/env bash
# Creates or removes the throwaway worktree that verify-feature tests in. Nothing here is ever pushed.
#   verify-worktree.sh create <feature-name> <integration-branch>
#   verify-worktree.sh remove <feature-name>
# create: fetches the base branch and the integration branch from the remote in workflow.json
#   (fast-forward only), puts a local branch verify/<feature-name> at the integration tip in
#   <repo root>/.claude/worktrees/verify-<feature-name>, and, if the base is not already contained in
#   it, merges <remote>/<base> into THAT branch only, so the tree is what would land in the base.
#   A conflict aborts the merge and exits 3 (the worktree is removed).
#   Prints KEY=value lines: WORKTREE, PROJECT (the project folder inside it), INTEGRATION_HEAD,
#   BASE_HEAD (the base branch head), MERGED (yes|no).
# remove: removes the worktree and the local verify/<feature-name> branch.
# This is the only place a merge is allowed; it refuses any path outside .claude/worktrees/verify-*.

set -euo pipefail
source "$(dirname "$0")/lib/config.sh"

action="${1:-}"; feature="${2:-}"; branch="${3:-}"
[[ "$action" == create || "$action" == remove ]] && [[ "$feature" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "usage: verify-worktree.sh create <feature-name> <integration-branch> | remove <feature-name>" >&2; exit 2; }

top="$WF_TOP"
remote="$(wf_remote)"; base="$(cfg .branches.base)"
wt="$top/.claude/worktrees/verify-$feature"
tmp_branch="verify/$feature"
[[ "$wt" == "$top/.claude/worktrees/verify-"* ]] || { echo "verify-worktree: bad path $wt" >&2; exit 2; }

remove() {
  [[ -d "$wt" ]] && git -C "$top" worktree remove --force "$wt"
  git -C "$top" worktree prune
  git -C "$top" show-ref --verify --quiet "refs/heads/$tmp_branch" && git -C "$top" branch -D "$tmp_branch" >/dev/null
  return 0
}

if [[ "$action" == remove ]]; then
  remove
  echo "removed verify worktrees for $feature"
  exit 0
fi

why="$(wf_branch_ok "$branch")" || { echo "verify-worktree: integration $why" >&2; exit 2; }
remove   # idempotent: start from nothing

# Without a remote (local tracker) the local base and integration branches are the truth.
wf_fetch "$base"
[[ -z "$remote" ]] || git -C "$top" fetch -q "$remote" "$branch:$branch" 2>/dev/null || {
  # Refused when the local branch is ahead or diverged; only fine if it is not behind the remote.
  git -C "$top" merge-base --is-ancestor "$remote/$branch" "$branch" 2>/dev/null ||
    { echo "verify-worktree: local $branch cannot be fast-forwarded to $remote/$branch" >&2; exit 1; }
}

git -C "$top" worktree add -q -b "$tmp_branch" "$wt" "$branch"
integration_head="$(git -C "$wt" rev-parse HEAD)"
base_head="$(git -C "$top" rev-parse "$(wf_ref "$base")")"
merged=no
if ! git -C "$wt" merge-base --is-ancestor "$base_head" HEAD; then
  if git -C "$wt" merge --no-edit -q "$base_head" >/dev/null 2>&1; then
    merged=yes
  else
    git -C "$wt" merge --abort 2>/dev/null || true
    echo "CONFLICT merging $(wf_ref "$base") ($base_head) into $branch; not resolved here" >&2
    remove
    exit 3
  fi
fi

echo "WORKTREE=$wt"
echo "PROJECT=$(wf_project_in "$wt")"
echo "INTEGRATION_HEAD=$integration_head"
echo "BASE_HEAD=$base_head"
echo "MERGED=$merged"
