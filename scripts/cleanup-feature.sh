#!/usr/bin/env bash
# Removes the local data a feature no longer needs. Never touches a remote branch.
#   cleanup-feature.sh <feature> --task <task-id> [--dry-run]
#       after that task's PR is merged: its worktree and its local branch.
#   cleanup-feature.sh <feature> [--dry-run]
#       when the final PR is merged: every task as above, the verify, evidence and integration-branch
#       worktrees, the local integration branch, .claude/workflow/<feature>/, <docs_dir>/<feature>/evidence/
#       and reviews/, and the Playwright output when no other feature is running.
# A standalone task (workez:build-task) has its plan in .claude/workflow/<feature>/plan.md and its
# PR target is the base branch: the base branch and its worktree are never removed, and its
# evidence branch is <task branch>-evidence.
# A worktree is removed only if it has no uncommitted or untracked changes, a local task branch only
# if the integration branch or the base contains it, and the local integration branch only if the
# base contains it (merged with a merge commit or fast-forward; a squash merge leaves it KEPT).
# Remote branches are left to the repository's own settings.
# Anything else is kept and printed as KEPT with the reason. Prints REMOVED, KEPT or WOULD REMOVE lines.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

feature="${1:-}"; shift 2>/dev/null
only_task=""; dry=0
while (($#)); do
  case "$1" in
    --task) only_task="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: cleanup-feature.sh <feature> [--task <task-id>] [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ "$feature" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "usage: cleanup-feature.sh <feature> [--task <task-id>] [--dry-run]" >&2; exit 2; }

remote="$(wf_remote)"
base="$(cfg .branches.base)"
docs="$WF_PROJECT/$(cfg .docs_dir)/$feature"
runtime="$WF_PROJECT/.claude/workflow"
plans=()
for f in "$docs/plan.md" "$docs/plan-fix.md" "$runtime/$feature/plan.md"; do [[ -f "$f" ]] && plans+=("$f"); done
((${#plans[@]})) || { echo "cleanup-feature: no plan in $docs or $runtime/$feature" >&2; exit 2; }

# Tasks: "<id> <branch>", and the integration branch from the first PR target.
tasks="$(awk '
  /^## T[0-9]+: / { id = $2; sub(":", "", id); next }
  /^## / { id = "" }
  id && /^- \*\*Branch\*\*:/ { b = $0; if (b ~ /`/) { sub(/^[^`]*`/, "", b); sub(/`.*/, "", b); print id, b } }
' "${plans[@]}")"
integration="$(grep -h -m1 '^- \*\*PR target\*\*:' "${plans[@]}" | head -1 | sed -E 's/^[^`]*`([^`]*)`.*/\1/')"
[[ -n "$integration" ]] || { echo "cleanup-feature: no PR target in the plan" >&2; exit 2; }
wf_fetch "$integration" 2>/dev/null
int_ref="$(wf_ref "$integration")"
git -C "$WF_TOP" rev-parse -q --verify "$int_ref" >/dev/null || int_ref="$integration"
wf_fetch "$base" 2>/dev/null
base_ref="$(wf_ref "$base")"

# marked <branch>: the local tracker's merge request for it was marked merged (mark-merged.sh: a
# squash merge, which leaves no ancestry).
mr_file() { printf '%s/local-mr/%s' "$runtime" "${1//\//-}"; }
marked() { wf_local && [[ "$(jq -r '.state // empty' "$(mr_file "$1").json" 2>/dev/null)" == merged ]]; }

# merged <branch>: the integration branch or the base contains it.
merged() {
  git -C "$WF_TOP" merge-base --is-ancestor "$1" "$int_ref" 2>/dev/null ||
    git -C "$WF_TOP" merge-base --is-ancestor "$1" "$base_ref" 2>/dev/null || marked "$1"
}

# drop_mr <branch>: the local tracker's merge request record, once it is MERGED or CLOSED.
drop_mr() {
  wf_local && [[ -f "$(mr_file "$1").json" ]] || return 0
  case "$("$WF_HOME/scripts/local-ops.sh" get-pr-state "$1" | cut -f2)" in
    MERGED | CLOSED) act "merge request record $1" rm -f "$(mr_file "$1").json" "$(mr_file "$1").md" ;;
  esac
}

say() { echo "$1 $2${3:+ ($3)}"; }
act() {  # act <what> <command...>: run it, or only say it in a dry run
  local what="$1"; shift
  if ((dry)); then say "WOULD REMOVE" "$what"; return 0; fi
  if "$@" >/dev/null 2>&1; then say REMOVED "$what"; else say KEPT "$what" "removal failed"; fi
}
# Clean = no changes except the workflow's own records: review reports and UI evidence, which show
# as untracked on task branches cut before .gitignore listed them (check-pr-ready.sh allows the same).
docs_rel="$(cfg .docs_dir)"
clean_tree() {
  [[ -z "$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null |
    grep -vE "^\?\? (.*/)?$docs_rel/[^/]+/(evidence|reviews)/" || true)" ]]
}

# drop_worktree <path>: removes a worktree that is clean (--force only clears those records).
drop_worktree() {
  local wt="$1"
  [[ -d "$wt" ]] || return 0
  if clean_tree "$wt"; then act "worktree $wt" git -C "$WF_TOP" worktree remove --force "$wt"
  else say KEPT "worktree $wt" "uncommitted or untracked changes"; return 1; fi
}

# drop_task <branch>: its worktree (under the repository root, or under the project when that is a
# subfolder), then the local branch if the integration branch or the base contains it.
drop_task() {
  local branch="$1" wt kept=0
  local first; first="$(wf_worktree_path "$branch")"
  for wt in "$first" "$WF_PROJECT/.claude/worktrees/${branch//\//-}"; do
    drop_worktree "$wt" || kept=1
    [[ "$WF_PROJECT" == "$WF_TOP" ]] && break   # both paths are the same folder
  done
  git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$branch" || return 0
  if ((kept)); then say KEPT "branch $branch" "its worktree was kept"
  elif merged "$branch"; then
    act "branch $branch" git -C "$WF_TOP" branch -D "$branch"
  else say KEPT "branch $branch" "not contained in $int_ref or $base_ref"; fi
}

found=0
while read -r id branch; do
  [[ -n "$id" ]] || continue
  [[ -z "$only_task" || "$id" == "$only_task" ]] || continue
  found=1
  drop_task "$branch"
  drop_mr "$branch"
done <<<"$tasks"
[[ -z "$only_task" || $found == 1 ]] || { echo "cleanup-feature: task $only_task not in the plan" >&2; exit 2; }
[[ -n "$only_task" ]] && exit 0

# The whole feature.
if [[ -d "$WF_TOP/.claude/worktrees/verify-$feature" ]]; then
  act "verify worktree" "$WF_HOME/scripts/verify-worktree.sh" remove "$feature"
fi
# A standalone task targets the base branch (or another protected one): never remove it.
standalone=0
[[ "$integration" == "$base" ]] && standalone=1
jq -e --arg b "$integration" '.branches.protected // [] | index($b)' "$WF_CONFIG" >/dev/null 2>&1 && standalone=1
# The local integration branch, once the final PR is merged into the base.
if ((standalone)); then :
elif drop_worktree "$(wf_worktree_path "$integration")" &&
  git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$integration"; then
  if git -C "$WF_TOP" merge-base --is-ancestor "$integration" "$base_ref" 2>/dev/null || marked "$integration"; then
    act "branch $integration" git -C "$WF_TOP" branch -D "$integration"
  else say KEPT "branch $integration" "not contained in $base_ref: final PR not merged, or squash-merged"; fi
fi
((standalone)) || drop_mr "$integration"
evidence_branch="$integration-evidence"
((standalone)) && evidence_branch="$(head -1 <<<"$tasks" | cut -d' ' -f2)-evidence"
if drop_worktree "$(wf_worktree_path "$evidence_branch")" &&
  git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$evidence_branch"; then
  # The evidence branch is only a local copy of what was pushed; keep it if it has unpushed commits.
  if [[ -n "$remote" ]] && git -C "$WF_TOP" merge-base --is-ancestor "$evidence_branch" "$remote/$evidence_branch" 2>/dev/null; then
    act "branch $evidence_branch" git -C "$WF_TOP" branch -D "$evidence_branch"
  else say KEPT "branch $evidence_branch" "not pushed to $remote"; fi
fi

for d in "$runtime/$feature" "$docs/evidence" "$docs/reviews"; do
  [[ -d "$d" && "$d" == "$WF_PROJECT"/* ]] && act "$d" rm -rf "$d"
done
# The feature's port slot (dev-servers.sh), free for the next feature.
for s in "$runtime"/lane-slots/*; do
  [[ -f "$s" && "$(cat "$s" 2>/dev/null)" == "$feature" ]] && act "$s" rm -f "$s"
done

# Shared Playwright output, only when no other feature has a state.
others=0
for s in "$runtime"/*/state.json; do
  [[ -f "$s" && "$s" != "$runtime/$feature/state.json" ]] && others=1
done
if ((others)); then say KEPT "Playwright output" "another feature is running"
else
  for d in "$runtime"/playwright-*; do
    [[ -d "$d" ]] && [[ -n "$(ls -A "$d")" ]] && act "$d/*" find "$d" -mindepth 1 -delete
  done
fi
exit 0
