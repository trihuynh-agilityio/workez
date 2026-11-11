#!/usr/bin/env bash
# Read-only watch over task PRs, for the build-feature cron and its position step. Writes nothing,
# never prints comment text, so a run with nothing new needs no agent.
#   gh-watch.sh <branch:issue>... [--handled <id,id,...>] [--settled <pr,pr,...>] [--no-feedback]
# Output, one line each:
#   STATE <branch> <OPEN|MERGED|CLOSED|NONE> <pr|-> <issue>     the most recent PR of the branch
#   FEEDBACK <pr> <id> <author>                                  new feedback on an OPEN PR
#   CHECKS <pr> checks-<head sha>                                a failed check on an OPEN PR's head
#   CONFLICT <pr> conflict-<head sha>                            an OPEN PR that conflicts with its base
# Feedback is filtered as github-ops get-pr-feedback does: only github.feedback_authors from
# .claude/workflow.json; ids in --handled, bodies with <!-- workflow-reply -->, bodies that are only
# github.review_trigger and APPROVED reviews with an empty body are dropped.
# --settled: PR numbers whose MERGED or CLOSED state the workflow already labelled.
# CHECKS and CONFLICT ids name the PR's head commit (12 characters), so --handled drops them until
# a new push; pending checks and an UNKNOWN mergeable state print nothing.
# --no-feedback: states only (the final PR watch), so new comments, checks or conflicts never wake an agent.
# Exit: 0 nothing new, 10 a MERGED or CLOSED PR not in --settled (wins over 20),
#       20 new feedback, a failed check or a conflict, 2 usage or gh error.

# Local tracker ("tracker": "local"): no gh. Fetches the remote once (when there is one), takes each
# branch's state from local-ops.sh get-pr-state (git ancestry, or mark-merged.sh), and uses the branch
# as the PR id; there is never FEEDBACK, CHECKS or CONFLICT, so the exit is 0 or 10.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
pairs=(); handled=","; settled=","; feedback=1
usage="usage: gh-watch.sh <branch:issue>... [--handled <ids>] [--settled <prs>] [--no-feedback]"
while (($#)); do
  case "$1" in
    --handled) handled=",${2:-},"; shift 2 ;;
    --settled) settled=",${2:-},"; shift 2 ;;
    --no-feedback) feedback=0; shift ;;
    *:*) pairs+=("$1"); shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
((${#pairs[@]})) || { echo "$usage" >&2; exit 2; }

if wf_local; then
  git -C "$WF_TOP" fetch -q --prune "$(wf_remote)" 2>/dev/null || [[ -z "$(wf_remote)" ]] \
    || { echo "gh-watch: git fetch $(wf_remote) failed" >&2; exit 2; }
  settled_new=0
  for pair in "${pairs[@]}"; do
    branch="${pair%:*}"; issue="${pair##*:}"
    row="$("$(dirname "${BASH_SOURCE[0]}")/local-ops.sh" get-pr-state "$branch")" \
      || { echo "gh-watch: local-ops get-pr-state failed for $branch" >&2; exit 2; }
    read -r _ state _ <<<"$row"
    if [[ "$state" == NONE ]]; then echo "STATE $branch NONE - $issue"; continue; fi
    echo "STATE $branch $state $branch $issue"
    [[ "$state" == MERGED || "$state" == CLOSED ]] && [[ "$settled" != *",$branch,"* ]] && settled_new=1
  done
  ((settled_new)) && exit 10
  exit 0
fi

repo="$(cfg .github.repo)"
[[ -n "$repo" ]] || { echo "gh-watch: github.repo is missing in $WF_CONFIG" >&2; exit 2; }
authors="$(jq -c '.github.feedback_authors // []' "$WF_CONFIG")"
trigger="$(jq -c '.github.review_trigger // ""' "$WF_CONFIG")"

# jq filter shared by the three feedback endpoints; prints "<id> <author>". gh -q takes no jq
# arguments, so the config values go in as JSON literals.
keep='.[]
  | select(.user.login as $u | '"$authors"' | index($u))
  | (.body // "") as $b
  | select(($b | contains("<!-- workflow-reply -->")) | not)
  | select('"$trigger"' == "" or ($b | gsub("^\\s+|\\s+$"; "")) != '"$trigger"')
  | select(((.state // "") == "APPROVED" and ($b | test("^\\s*$"))) | not)
  | "\(.id) \(.user.login)"'

# Prints "<head sha> <mergeable> <failed check count>". A check failed when a check run concluded
# FAILURE, TIMED_OUT, STARTUP_FAILURE or ACTION_REQUIRED, or a status context is FAILURE or ERROR;
# CANCELLED is left out, since a newer push cancels the older runs.
head_q='"\(.headRefOid[0:12]) \(.mergeable) \([.statusCheckRollup[]?
  | select(((.conclusion // .state // "") as $c
    | ["FAILURE","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","ERROR"] | index($c)))] | length)"'

settled_new=0; feedback_new=0
for pair in "${pairs[@]}"; do
  branch="${pair%:*}"; issue="${pair##*:}"
  row="$(gh pr list --repo "$repo" --head "$branch" --state all --json number,state,createdAt \
    -q 'sort_by(.createdAt) | last | select(.) | "\(.number) \(.state)"')" \
    || { echo "gh-watch: gh pr list failed for $branch" >&2; exit 2; }
  if [[ -z "$row" ]]; then
    echo "STATE $branch NONE - $issue"
    continue
  fi
  pr="${row% *}"; state="${row#* }"
  echo "STATE $branch $state $pr $issue"

  case "$state" in
    MERGED | CLOSED) [[ "$settled" == *",$pr,"* ]] || settled_new=1; continue ;;
  esac
  ((feedback)) || continue

  head="$(gh pr view "$pr" --repo "$repo" --json headRefOid,mergeable,statusCheckRollup -q "$head_q")" \
    || { echo "gh-watch: gh pr view failed for $pr" >&2; exit 2; }
  read -r sha mergeable failed <<<"$head"
  if ((${failed:-0} > 0)) && [[ "$handled" != *",checks-$sha,"* ]]; then
    echo "CHECKS $pr checks-$sha"; feedback_new=1
  fi
  if [[ "$mergeable" == CONFLICTING && "$handled" != *",conflict-$sha,"* ]]; then
    echo "CONFLICT $pr conflict-$sha"; feedback_new=1
  fi

  for path in "pulls/$pr/reviews" "pulls/$pr/comments" "issues/$pr/comments"; do
    items="$(gh api "repos/$repo/$path" --paginate -q "$keep")" \
      || { echo "gh-watch: gh api $path failed" >&2; exit 2; }
    while read -r id author; do
      [[ -n "$id" && "$handled" != *",$id,"* ]] || continue
      echo "FEEDBACK $pr $id $author"
      feedback_new=1
    done <<<"$items"
  done
done

((settled_new)) && exit 10
((feedback_new)) && exit 20
exit 0
