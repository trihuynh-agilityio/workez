#!/usr/bin/env bash
# Local tracker only: marks a task's merge request as merged (or closed without merge) by hand, for a
# merge git cannot see: a squash or rebase merge leaves the task's commits out of the base branch.
#   mark-merged.sh <branch> [--closed]
#   mark-merged.sh <feature> <task-id> [--closed]     (the Branch of that task in the feature's plan)
# The next watch run or build-feature position step reads it through local-ops.sh get-pr-state.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
wf_local || { echo "mark-merged: only for the local tracker (\"tracker\": \"local\" in workflow.json)" >&2; exit 2; }
state=merged; args=()
for a in "$@"; do [[ "$a" == --closed ]] && state=closed || args+=("$a"); done
usage="usage: mark-merged.sh <branch> | <feature> <task-id> [--closed]"
case "${#args[@]}" in
  1) branch="${args[0]}" ;;
  2)
    docs="$WF_PROJECT/$(cfg .docs_dir)/${args[0]}"
    branch=""
    for p in "$docs/plan.md" "$docs/plan-fix.md"; do
      [[ -f "$p" ]] || continue
      branch="$(awk -v t="${args[1]}" 'index($0, "## " t ": ") == 1 { f = 1; next } f && /^## / { exit }
        f && /^- \*\*Branch\*\*:/ { sub(/^[^`]*`/, ""); sub(/`.*/, ""); print; exit }' "$p")"
      [[ -n "$branch" ]] && break
    done
    [[ -n "$branch" ]] || { echo "mark-merged: no task ${args[1]} with a Branch in $docs/plan.md" >&2; exit 2; } ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
f="$WF_PROJECT/.claude/workflow/local-mr/${branch//\//-}.json"
[[ -f "$f" ]] || { echo "mark-merged: no local merge request for $branch (create-pr has not run for it)" >&2; exit 1; }
tmp="$(mktemp "$f.XXXXXX")" && jq --arg s "$state" '.state = $s' "$f" >"$tmp" && mv "$tmp" "$f"
echo "$branch $(tr a-z A-Z <<<"$state")"
