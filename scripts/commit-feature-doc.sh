#!/usr/bin/env bash
# Commits approved feature docs (intent.md, spec.md, plan.md) to the feature's integration branch,
# without touching the current checkout. Nothing here is ever pushed: build-feature pushes the branch.
#   commit-feature-doc.sh <feature-name> <feature-issue-number> <doc>...
# <doc> is a file name inside <docs_dir>/<feature-name>/ (intent.md, spec.md, plan.md).
# The branch name comes from naming.integration_branch in workflow.json. If it is missing, it is
# created from the freshly fetched <remote>/<base branch> (never a stale local copy, never another branch).
# The docs are copied from this checkout into a temporary worktree, committed there, and the
# worktree is removed. Prints BRANCH=, COMMIT= (or COMMIT=none when the branch already had identical files).

set -euo pipefail
source "$(dirname "$0")/lib/config.sh"

feature="${1:-}"; issue="${2:-}"; shift 2 2>/dev/null || true
[[ "$feature" =~ ^[a-z0-9][a-z0-9-]*$ && "$issue" =~ ^[0-9]+$ && $# -gt 0 ]] || {
  echo "usage: commit-feature-doc.sh <feature-name> <feature-issue-number> <doc>..." >&2; exit 2; }

remote="$(cfg .github.remote)"; base="$(cfg .branches.base)"
branch="$(wf_fill "$(cfg .naming.integration_branch)" feature_issue="$issue" feature_slug="$feature")"
wt="$(wf_worktree_path "$branch")"
docs="$(cfg .docs_dir)/$feature"

for doc in "$@"; do
  [[ "$doc" =~ ^[a-z-]+\.md$ && -f "$WF_PROJECT/$docs/$doc" ]] || { echo "commit-feature-doc: no $docs/$doc" >&2; exit 2; }
done
[[ -e "$wt" ]] && { echo "commit-feature-doc: $wt already exists" >&2; exit 2; }

if ! git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$WF_TOP" fetch -q "$remote" "$base"
  git -C "$WF_TOP" branch --no-track "$branch" "$remote/$base"
fi
git -C "$WF_TOP" worktree add --quiet "$wt" "$branch"
trap 'git -C "$WF_TOP" worktree remove --force "$wt"' EXIT

dest="$(wf_project_in "$wt")/$docs"
mkdir -p "$dest"
paths=()
for doc in "$@"; do
  cp "$WF_PROJECT/$docs/$doc" "$dest/$doc"
  paths+=("$dest/$doc")
done
git -C "$wt" add -- "${paths[@]}"

echo "BRANCH=$branch"
if git -C "$wt" diff --cached --quiet; then
  echo "COMMIT=none"
  exit 0
fi
names="$(printf '%s, ' "${@%.md}")"
# Conventional Commits subject: docs(<feature>): add approved intent, spec
msg=(-m "docs($feature): add approved ${names%, }" -m "Approved in the feature workflow.")
trailers="$(wf_trailers)"; [[ -n "$trailers" ]] && msg+=(-m "$trailers")
git -C "$wt" commit --quiet "${msg[@]}"
echo "COMMIT=$(git -C "$wt" rev-parse --short HEAD)"
