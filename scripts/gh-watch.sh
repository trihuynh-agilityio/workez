#!/usr/bin/env bash
# Read-only watch over task PRs, for the build-feature cron and its position step. Writes nothing,
# never prints comment text, so a run with nothing new needs no agent.
#   gh-watch.sh <branch:issue>... [--handled <id,id,...>] [--settled <pr,pr,...>] [--no-feedback] [--ready]
#               [--until-settled [--interval <sec>] [--timeout <min>|<n>s] [--grace <sec>]]
# Output, one line each:
#   STATE <branch> <OPEN|MERGED|CLOSED|NONE> <pr|-> <issue>     the most recent PR of the branch
#   FEEDBACK <pr> <id> <author>                                  new feedback on an OPEN PR
#   CHECKS <pr> checks-<head sha>                                a failed check on an OPEN PR's head
#   CONFLICT <pr> conflict-<head sha>                            an OPEN PR that conflicts with its base
#   READY <pr> ready-<head sha12> <full head sha>                an OPEN PR that is ready to auto-merge (only with --ready)
# Feedback is filtered as github-ops get-pr-feedback does: only github.feedback_authors from
# .claude/workflow.json; ids in --handled, bodies with <!-- workflow-reply -->, bodies that are only
# github.review_trigger and APPROVED reviews with an empty body are dropped.
# --settled: PR numbers whose MERGED or CLOSED state the workflow already labelled.
# CHECKS and CONFLICT ids name the PR's head commit (12 characters), so --handled drops them until
# a new push; pending checks and an UNKNOWN mergeable state print nothing.
# --no-feedback: states only (the final PR watch), so new comments, checks or conflicts never wake an agent.
# --ready: also print READY for an OPEN PR with no FEEDBACK, CHECKS or CONFLICT line in this run, every check
# completed and green, mergeable, and whose ready-<head sha12> id is not in --handled. It only reports;
# merge-task-pr.sh decides and merges. --no-feedback turns it off too. In local mode (no checks) every OPEN
# branch is READY, with its tip (<remote>/<branch> when it exists, else the local branch) as the head.
# --until-settled: a zero-token wait. Repeats the single pass above (same filters, --handled and --settled)
# every --interval seconds (default 30) and stops at the first pass with something to act on, printing ONLY
# that pass (the STATE line and the action lines). It implies --ready, takes exactly one <branch:issue> and
# excludes --no-feedback. Passes that would exit 0 (pending checks, mergeable UNKNOWN, STATE NONE, handled ids)
# sleep and poll again. A pass that fails is retried; 3 failed passes in a row print the error and exit 2.
# --timeout (default 120, minutes; "<n>s" for seconds) ends the wait: it prints the last STATE line, then
# "TIMEOUT <branch> <timeout as given, 120m or 2s>", and exits 40.
# --grace (default 60 seconds, 0 allowed): on GitHub an OPEN PR with no checks at all (CI may not have registered
# yet right after the PR is opened) is READY only once it has been READY-eligible with zero checks for --grace
# seconds since the first such sighting; if checks appear, the normal rules apply. Local mode has no grace.
# It is meant to run as ONE background Bash command (run_in_background) in build-feature step 4 when
# auto_merge.task_prs is on, replacing the 10-minute cron: it costs no tokens until it exits.
# Exit: 0 nothing new, 10 a MERGED or CLOSED PR not in --settled (wins over 20),
#       20 new feedback, a failed check or a conflict, 30 only READY lines (10 and 20 win),
#       2 usage or gh error, 40 --until-settled timed out (only with --until-settled).

# Local tracker ("tracker": "local"): no gh. Fetches the remote once (when there is one), takes each
# branch's state from local-ops.sh get-pr-state (git ancestry, or mark-merged.sh), and uses the branch
# as the PR id; there is never FEEDBACK, CHECKS or CONFLICT, so the exit is 0 or 10.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
pairs=(); handled=","; settled=","; feedback=1; ready=0
until=0; interval=30; timeout_arg=120; grace=60; opt_set=0
usage="usage: gh-watch.sh <branch:issue>... [--handled <ids>] [--settled <prs>] [--no-feedback] [--ready] [--until-settled [--interval <sec>] [--timeout <min>|<n>s] [--grace <sec>]]"
while (($#)); do
  case "$1" in
    --handled) handled=",${2:-},"; shift 2 ;;
    --settled) settled=",${2:-},"; shift 2 ;;
    --no-feedback) feedback=0; shift ;;
    --ready) ready=1; shift ;;
    --until-settled) until=1; shift ;;
    --interval) interval="${2:-}"; opt_set=1; shift 2 ;;
    --timeout) timeout_arg="${2:-}"; opt_set=1; shift 2 ;;
    --grace) grace="${2:-}"; opt_set=1; shift 2 ;;
    *:*) pairs+=("$1"); shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
((${#pairs[@]})) || { echo "$usage" >&2; exit 2; }
if ((until)); then
  ((${#pairs[@]} == 1 && feedback)) || { echo "$usage (--until-settled takes one pair and not --no-feedback)" >&2; exit 2; }
  [[ "$interval" =~ ^[0-9]+$ && "$grace" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
  if [[ "$timeout_arg" =~ ^[0-9]+$ ]]; then timeout_s=$((timeout_arg * 60)); timeout_label="${timeout_arg}m"
  elif [[ "$timeout_arg" =~ ^[0-9]+s$ ]]; then timeout_s="${timeout_arg%s}"; timeout_label="$timeout_arg"
  else echo "$usage" >&2; exit 2; fi
  ready=1
elif ((opt_set)); then
  echo "$usage (--interval, --timeout and --grace need --until-settled)" >&2; exit 2
fi

if ! wf_local; then
  repo="$(cfg .github.repo)"
  [[ -n "$repo" ]] || { echo "gh-watch: github.repo is missing in $WF_CONFIG" >&2; exit 2; }
  authors="$(jq -c '.github.feedback_authors // []' "$WF_CONFIG")"
  trigger="$(jq -c '.github.review_trigger // ""' "$WF_CONFIG")"
fi

# jq filter shared by the three feedback endpoints; prints "<id> <author>". gh -q takes no jq
# arguments, so the config values go in as JSON literals.
keep='.[]
  | select(.user.login as $u | '"$authors"' | index($u))
  | (.body // "") as $b
  | select(($b | contains("<!-- workflow-reply -->")) | not)
  | select('"$trigger"' == "" or ($b | gsub("^\\s+|\\s+$"; "")) != '"$trigger"')
  | select(((.state // "") == "APPROVED" and ($b | test("^\\s*$"))) | not)
  | "\(.id) \(.user.login)"'

# Prints "<head sha12> <mergeable> <failed check count> <full head sha> <pending check count> <total check count>". A check failed when a check run concluded
# FAILURE, TIMED_OUT, STARTUP_FAILURE or ACTION_REQUIRED, or a status context is FAILURE or ERROR;
# CANCELLED is left out, since a newer push cancels the older runs. Pending: a check run that is not
# COMPLETED, or a status context that is PENDING or EXPECTED.
head_q='"\(.headRefOid[0:12]) \(.mergeable) \([.statusCheckRollup[]?
  | select(((.conclusion // .state // "") as $c
    | ["FAILURE","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","ERROR"] | index($c)))] | length) \(.headRefOid) \([.statusCheckRollup[]?
  | select((.status // "COMPLETED") != "COMPLETED" or (((.status // "") == "") and ((.state // "") as $s | ["PENDING","EXPECTED"] | index($s))))] | length) \([.statusCheckRollup[]?] | length)"'

# One pass over every pair. Lines go to pass_out, an error message to pass_err; returns the exit code
# (0, 10, 20, 30, or 2 on error). zero_since (epoch seconds) is kept across passes for the grace.
pass_out=""; pass_err=""; zero_since=""
emit() { pass_out+="$*"$'\n'; }
watch_pass() {
  pass_out=""; pass_err=""
  local settled_new=0 feedback_new=0 ready_new=0 pair branch issue row state pr head sha mergeable failed full pending total
  local pr_fb path items id author rem tip now
  if wf_local; then
    git -C "$WF_TOP" fetch -q --prune "$(wf_remote)" 2>/dev/null || [[ -z "$(wf_remote)" ]] \
      || { pass_err="gh-watch: git fetch $(wf_remote) failed"; return 2; }
    for pair in "${pairs[@]}"; do
      branch="${pair%:*}"; issue="${pair##*:}"
      row="$("$(dirname "${BASH_SOURCE[0]}")/local-ops.sh" get-pr-state "$branch")" \
        || { pass_err="gh-watch: local-ops get-pr-state failed for $branch"; return 2; }
      read -r _ state _ <<<"$row"
      if [[ "$state" == NONE ]]; then emit "STATE $branch NONE - $issue"; continue; fi
      emit "STATE $branch $state $branch $issue"
      [[ "$state" == MERGED || "$state" == CLOSED ]] && [[ "$settled" != *",$branch,"* ]] && settled_new=1
      if ((ready)) && [[ "$state" == OPEN ]]; then
        rem="$(wf_remote)"; tip=""
        [[ -n "$rem" ]] && tip="$(git -C "$WF_TOP" rev-parse -q --verify "refs/remotes/$rem/$branch" 2>/dev/null)"
        [[ -n "$tip" ]] || tip="$(git -C "$WF_TOP" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)"
        if [[ -n "$tip" && "$handled" != *",ready-${tip:0:12},"* ]]; then
          emit "READY $branch ready-${tip:0:12} $tip"; ready_new=1
        fi
      fi
    done
    ((settled_new)) && return 10
    ((ready_new)) && return 30
    return 0
  fi

  for pair in "${pairs[@]}"; do
    branch="${pair%:*}"; issue="${pair##*:}"
    row="$(gh pr list --repo "$repo" --head "$branch" --state all --json number,state,createdAt \
      -q 'sort_by(.createdAt) | last | select(.) | "\(.number) \(.state)"')" \
      || { pass_err="gh-watch: gh pr list failed for $branch"; return 2; }
    if [[ -z "$row" ]]; then
      emit "STATE $branch NONE - $issue"
      continue
    fi
    pr="${row% *}"; state="${row#* }"
    emit "STATE $branch $state $pr $issue"

    case "$state" in
      MERGED | CLOSED) [[ "$settled" == *",$pr,"* ]] || settled_new=1; continue ;;
    esac
    ((feedback)) || continue

    head="$(gh pr view "$pr" --repo "$repo" --json headRefOid,mergeable,statusCheckRollup -q "$head_q")" \
      || { pass_err="gh-watch: gh pr view failed for $pr"; return 2; }
    read -r sha mergeable failed full pending total <<<"$head"
    pr_fb=0
    if ((${failed:-0} > 0)) && [[ "$handled" != *",checks-$sha,"* ]]; then
      emit "CHECKS $pr checks-$sha"; feedback_new=1; pr_fb=1
    fi
    if [[ "$mergeable" == CONFLICTING && "$handled" != *",conflict-$sha,"* ]]; then
      emit "CONFLICT $pr conflict-$sha"; feedback_new=1; pr_fb=1
    fi

    for path in "pulls/$pr/reviews" "pulls/$pr/comments" "issues/$pr/comments"; do
      items="$(gh api "repos/$repo/$path" --paginate -q "$keep")" \
        || { pass_err="gh-watch: gh api $path failed"; return 2; }
      while read -r id author; do
        [[ -n "$id" && "$handled" != *",$id,"* ]] || continue
        emit "FEEDBACK $pr $id $author"
        feedback_new=1; pr_fb=1
      done <<<"$items"
    done

    if ((ready && !pr_fb && ${failed:-0} == 0 && ${pending:-0} == 0)) && [[ "$mergeable" == MERGEABLE && "$handled" != *",ready-$sha,"* ]]; then
      # Until-settled grace: a PR with no checks at all may just not have its CI registered yet.
      if ((until && ${total:-0} == 0 && grace > 0)); then
        now="$(date +%s)"
        [[ -n "$zero_since" ]] || zero_since="$now"
        ((now - zero_since < grace)) && continue
      fi
      emit "READY $pr ready-$sha $full"; ready_new=1
    fi
  done

  ((settled_new)) && return 10
  ((feedback_new)) && return 20
  ((ready_new)) && return 30
  return 0
}

if ((!until)); then
  watch_pass; rc=$?
  printf '%s' "$pass_out"
  [[ -z "$pass_err" ]] || echo "$pass_err" >&2
  exit "$rc"
fi

# --until-settled: poll until a pass has something to act on, the timeout passes or 3 passes in a row fail.
start="$(date +%s)"; fails=0; branch="${pairs[0]%:*}"
while :; do
  watch_pass; rc=$?
  if ((rc == 2)); then
    fails=$((fails + 1))
    if ((fails >= 3)); then echo "$pass_err" >&2; exit 2; fi
  else
    fails=0
    if ((rc != 0)); then printf '%s' "$pass_out"; exit "$rc"; fi
  fi
  left=$((timeout_s - ($(date +%s) - start)))
  if ((left <= 0)); then
    printf '%s' "$pass_out" | grep '^STATE '
    echo "TIMEOUT $branch $timeout_label"
    exit 40
  fi
  sleep "$((interval < left ? interval : left))"
done
