#!/usr/bin/env bash
# The one way the workflow makes a worktree for a branch, and the base-branch preflight.
#   worktree.sh base
#       prints BASE=<branch> (branches.base, else the repository's default branch), REF=<remote>/<branch>
#       (the local branch without a remote) and SOURCE=workflow.json|default.
#   worktree.sh create <branch> [--from <start branch>]
#       fetches <start branch> (default: the base) and adds <repo root>/.claude/worktrees/<branch, / as ->
#       on a new branch <branch>, cut from <remote>/<start> (never a stale local copy). A start other
#       than the base (a feature's integration branch) uses the local branch when it already contains
#       the remote one (docs committed but not pushed yet). An existing worktree or branch is resumed.
#       Then runs the preflight against <start>. Prints WORKTREE=, PROJECT=, BRANCH=, FROM=, HEAD=.
#   worktree.sh check <worktree folder | branch> [--target <branch>]
#       the preflight alone: <remote>/<target> (default: the base) must be an ancestor of HEAD.
# Exit: 0 ok, 2 usage or a missing ref, 3 preflight failed. A worktree this run just made and that fails
# the preflight is removed again; an existing one is left as it is: never reset, recreate it.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

usage() {
  echo "usage: worktree.sh base | create <branch> [--from <start branch>] | check <worktree|branch> [--target <branch>]" >&2
  exit 2
}

action="${1:-}"; shift 2>/dev/null
base="$(wf_base)"
remote="$(wf_remote)"

case "$action" in
  base)
    echo "BASE=$base"
    echo "REF=$(wf_ref "$base")"
    [[ -n "$(cfg .branches.base)" ]] && echo "SOURCE=workflow.json" || echo "SOURCE=default"
    exit 0 ;;

  check)
    what="${1:-}"; shift 2>/dev/null; target="$base"
    [[ "${1:-}" == --target && -n "${2:-}" ]] && target="$2"
    [[ -n "$what" ]] || usage
    wf_fetch "$target" 2>/dev/null
    if why="$(wf_base_check "$what" "$target")"; then echo "PREFLIGHT=ok $(wf_ref "$target")"; exit 0; fi
    echo "PREFLIGHT FAILED: $why" >&2
    echo "  Do not reset it. Remove this worktree and its branch, then run worktree.sh create again." >&2
    exit 3 ;;

  create)
    branch="${1:-}"; shift 2>/dev/null; from="$base"
    [[ "${1:-}" == --from && -n "${2:-}" ]] && from="$2"
    [[ -n "$branch" ]] || usage
    why="$(wf_branch_ok "$branch")" || { echo "worktree: $why" >&2; exit 2; }
    [[ "$branch" != "$from" ]] || { echo "worktree: $branch cannot be cut from itself" >&2; exit 2; }
    wt="$(wf_worktree_path "$branch")"

    if [[ -n "$remote" ]] && ! wf_fetch "$from"; then
      [[ "$from" == "$base" ]] && { echo "worktree: git fetch $remote $from failed; the base must come from $remote" >&2; exit 2; }
    fi
    # The start point: always <remote>/<base> for the base. For another branch, the local one when it
    # holds everything the remote one has, else the remote one, else the local one (never pushed yet).
    start="$(wf_ref "$from")"
    if [[ "$from" != "$base" ]] && git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$from"; then
      if ! git -C "$WF_TOP" rev-parse -q --verify "$start^{commit}" >/dev/null ||
        git -C "$WF_TOP" merge-base --is-ancestor "$start" "$from" 2>/dev/null; then start="$from"; fi
    fi
    git -C "$WF_TOP" rev-parse -q --verify "$start^{commit}" >/dev/null ||
      { echo "worktree: $start not found (start branch $from); push or fetch it first" >&2; exit 2; }

    made=0
    if [[ -d "$wt" ]]; then
      [[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$branch" ]] ||
        { echo "worktree: $wt exists but is not on $branch" >&2; exit 2; }
    elif git -C "$WF_TOP" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$WF_TOP" worktree add -q "$wt" "$branch" || exit 2
    else
      git -C "$WF_TOP" worktree add -q --no-track -b "$branch" "$wt" "$start" || exit 2
      made=1
    fi

    # Preflight: the start branch must be in the new worktree's history.
    if ! why="$(wf_base_check "$wt" "$from")"; then
      echo "PREFLIGHT FAILED: $why" >&2
      if ((made)); then
        git -C "$WF_TOP" worktree remove --force "$wt" >/dev/null 2>&1
        git -C "$WF_TOP" branch -D "$branch" >/dev/null 2>&1
        echo "  The new worktree was removed again. Check that $from was fetched and run worktree.sh create again." >&2
      else
        echo "  $wt already existed and was cut from the wrong branch. Do not reset it: remove the worktree" >&2
        echo "  (git worktree remove $wt) and the branch $branch, keeping any commits of its own elsewhere, then run" >&2
        echo "  worktree.sh create $branch --from $from again." >&2
      fi
      exit 3
    fi
    echo "WORKTREE=$wt"
    echo "PROJECT=$(wf_project_in "$wt")"
    echo "BRANCH=$branch"
    echo "FROM=$(wf_ref "$from")"
    echo "HEAD=$(git -C "$wt" rev-parse --short HEAD)"
    ((made)) && echo "CREATED=yes" || echo "CREATED=no"
    exit 0 ;;

  *) usage ;;
esac
