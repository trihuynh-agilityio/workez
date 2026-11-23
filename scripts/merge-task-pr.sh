#!/usr/bin/env bash
# Opt-in auto-merge of ONE feature task PR into the feature's integration branch. Never the final PR
# into the base branch, never a standalone build-task PR.
#   merge-task-pr.sh <feature> <task-id> --sha <expected head sha> [--pr <n>] [--dry-run]
# Needs "auto_merge": { "task_prs": true, "method": "merge" } in .claude/workflow.json (off by default).
# Every guard runs in every mode: the task's plan must be a feature plan whose tasks share one PR
# target, that target must be an integration branch (not the base, not protected, matching
# naming.integration_branch); the task worktree must sit at --sha and pass check-pr-ready.sh (review
# and UI gates); the PR (GitHub) or local merge request (local tracker) must be open, not a draft, aimed
# at the integration branch, still at --sha, mergeable, with every check green.
# GitHub: merges through the merge API, pinned to --sha so a push in between is refused by GitHub too.
# Local tracker: merges with --no-ff in a throwaway worktree, moves the integration branch with a
# compare-and-swap and pushes it without force (when the project has a remote), then marks the MR merged.
# After a real merge it appends "- <subject>: auto-merged ..." to .claude/workflow/<feature>/notes.md.
# Output, one line:
#   stdout  MERGED <branch> <pr|branch> <merge sha>                      exit 0
#   stdout  WOULD MERGE <branch> <pr|branch> into <integration>          exit 0 (--dry-run; nothing changed)
#   stderr  REFUSED <reason>                                             exit 3: a guard failed; do not retry blindly
#   stderr  WAIT <reason>                                                exit 4: checks running or mergeability not
#                                                                        computed yet; try again later
# Exit: 0 merged (or would), 2 usage, 3 refused (also any unexpected git or gh error), 4 wait.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: merge-task-pr.sh <feature> <task-id> --sha <expected head sha> [--pr <n>] [--dry-run]"
refuse() { echo "REFUSED $*" >&2; exit 3; }
wait_() { echo "WAIT $*" >&2; exit 4; }

feature=""; task=""; sha=""; pr=""; dry=0; pos=()
while (($#)); do
  case "$1" in
    --sha) sha="${2:-}"; shift $(($# > 1 ? 2 : 1)) ;;
    --pr) pr="${2:-}"; shift $(($# > 1 ? 2 : 1)) ;;
    --dry-run) dry=1; shift ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
((${#pos[@]} == 2)) || { echo "$usage" >&2; exit 2; }
feature="${pos[0]}"; task="${pos[1]}"
[[ -n "$sha" ]] || { echo "$usage" >&2; exit 2; }
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }

# 1. Argument shapes.
[[ "$feature" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "feature '$feature' is not a feature folder name"
[[ "$task" =~ ^T[0-9]+$ ]] || refuse "task '$task' is not a task id (T<n>)"
[[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || refuse "--sha '$sha' is not a commit sha"

# 2. The opt-in.
[[ "$(jq -r '.auto_merge.task_prs // false' "$WF_CONFIG")" == true ]] || refuse "auto_merge.task_prs is off in workflow.json"
method="$(jq -r '.auto_merge.method // "merge"' "$WF_CONFIG")"
[[ "$method" == merge ]] || refuse "auto_merge.method '$method' is not supported; only merge"

# 3. The plan and the task block. Only the feature's plans; a standalone task is never merged here.
docs="$WF_PROJECT/$(cfg .docs_dir)/$feature"
plans=()
for p in "$docs/plan.md" "$docs/plan-fix.md"; do [[ -f "$p" ]] && plans+=("$p"); done
if ((${#plans[@]} == 0)); then
  [[ -f "$WF_PROJECT/.claude/workflow/$feature/plan.md" ]] \
    && refuse "$feature is a standalone task; its PR targets the base and is never auto-merged"
  refuse "no plan for $feature in $docs"
fi
plan=""; block=""
for p in "${plans[@]}"; do
  block="$(awk -v t="$task" 'index($0, "## " t ": ") == 1 { f = 1; print; next } f && /^## / { exit } f' "$p")"
  [[ -n "$block" ]] && { plan="$p"; break; }
done
[[ -n "$plan" ]] || refuse "task $task is not in the plans of $feature"
field() { grep -m1 "^- \*\*$1\*\*:" <<<"$block" | sed -E 's/^- \*\*[^*]+\*\*: *//'; }
ticks() { grep -o '`[^`]*`' | tr -d '`'; }
title="$(head -1 <<<"$block" | sed -E 's/^## T[0-9]+: *//; s/[[:space:]]*\[[ xX]\][[:space:]]*$//')"
branch="$(field Branch | ticks | head -1)"
integration="$(field 'PR target' | ticks | head -1)"
issue="$(field Issue)"
[[ -n "$branch" ]] || refuse "task $task has no Branch in ${plan#"$WF_PROJECT"/}"
[[ -n "$integration" ]] || refuse "task $task has no PR target in ${plan#"$WF_PROJECT"/}"

# 4. The integration branch.
targets="$(for p in "${plans[@]}"; do
  awk '/^## T[0-9]+: / { f = 1; next } /^## / { f = 0 }
    f && /^- \*\*PR target\*\*:/ { t = $0; sub(/^[^`]*`/, "", t); sub(/`.*/, "", t); print t }' "$p"
done | sort -u)"
[[ "$(grep -c . <<<"$targets")" == 1 ]] || refuse "the feature's tasks do not share one PR target"
base="$(wf_base)"
[[ "$integration" != "$base" ]] || refuse "target $integration is the base branch"
jq -e --arg b "$integration" '.branches.protected // [] | index($b)' "$WF_CONFIG" >/dev/null 2>&1 \
  && refuse "target $integration is protected (branches.protected)"
[[ "$branch" != "$integration" ]] || refuse "branch $branch is its own PR target"
tpl="$(cfg .naming.integration_branch)"
if [[ -n "$tpl" ]]; then
  re="${tpl//\{feature_slug\}/@@S@@}"; re="${re//\{feature_issue\}/@@I@@}"
  re="$(printf '%s' "$re" | sed -E 's/[]|.+?(){}^$*\\[]/\\&/g')"
  re="${re//@@S@@/$feature}"; re="${re//@@I@@/([0-9]+|$feature)}"
  printf '%s' "$integration" | grep -Eq "^${re}\$" || refuse "target $integration does not match naming.integration_branch"
fi

# The head sha, as a full sha.
wf_fetch "$branch" >/dev/null 2>&1 || true
full="$(git -C "$WF_TOP" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)" || refuse "commit $sha is not known locally"

# 5. Review and UI gate, run in the task's worktree.
wt="$(wf_worktree_path "$branch")"
[[ -d "$wt" ]] || refuse "no worktree for $branch; the review gate cannot be checked"
wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || refuse "cannot read HEAD of $wt"
[[ "$wt_head" == "$full" ]] || refuse "head changed: expected ${full:0:12}, the worktree is at ${wt_head:0:12}"
if ! out="$( (cd "$(wf_project_in "$wt")" && "$here/check-pr-ready.sh" "$task" "$plan") 2>&1 )"; then
  out="$(tr '\n' '|' <<<"$out" | sed 's/|$//; s/|/; /g')"
  refuse "check-pr-ready failed: ${out:0:400}"
fi

# Notes line after a real merge, through note.sh (it skips an identical line).
write_note() { # <subject> <what> <merge sha>
  "$here/note.sh" "$feature" "$1" "auto-merged $2 (${3:0:7})" >/dev/null 2>&1 || true
}

if ! wf_local; then
  # ---- GitHub ----
  repo="$(cfg .github.repo)"
  [[ -n "$repo" ]] || refuse "github.repo is missing in $WF_CONFIG"
  if [[ -z "$pr" ]]; then
    pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number -q '.[0].number // empty' 2>&1)" \
      || refuse "gh pr list failed: $(head -1 <<<"$pr")"
    [[ -n "$pr" ]] || refuse "no open PR for $branch"
  fi
  json="$(gh pr view "$pr" --repo "$repo" --json state,isDraft,baseRefName,headRefName,headRefOid,mergeable,statusCheckRollup 2>&1)" \
    || refuse "gh pr view $pr failed: $(head -1 <<<"$json")"
  j() { jq -r "$1" <<<"$json"; }
  st="$(j '.state // ""')"
  [[ "$st" == OPEN ]] || refuse "PR #$pr is ${st:-in an unknown state}"
  [[ "$(j '.isDraft // false')" == false ]] || refuse "PR #$pr is a draft"
  pbase="$(j '.baseRefName // ""')"
  [[ "$pbase" == "$integration" ]] || refuse "PR #$pr targets $pbase, not $integration"
  [[ "$(j '.headRefName // ""')" == "$branch" ]] || refuse "PR #$pr is not the PR of $branch"
  poid="$(j '.headRefOid // ""')"
  [[ "$poid" == "$full" ]] || refuse "head changed: PR #$pr is at ${poid:0:12}, expected ${full:0:12}"
  case "$(j '.mergeable // ""')" in
    MERGEABLE) ;;
    CONFLICTING) refuse "PR #$pr conflicts with $integration" ;;
    *) wait_ "GitHub has not computed mergeability of PR #$pr yet" ;;
  esac
  pending="$(j '[.statusCheckRollup[]? | select(
      (has("status") and .status != "COMPLETED") or
      ((has("status") | not) and ((.state // "") as $s | ["PENDING","EXPECTED"] | index($s))))] | length')"
  ((${pending:-0} == 0)) || wait_ "checks still running on PR #$pr"
  failed="$(j '[.statusCheckRollup[]? | select(
      if has("status") then ((.conclusion // "") as $c | ["SUCCESS","NEUTRAL","SKIPPED"] | index($c) | not)
      else ((.state // "") != "SUCCESS") end) | (.name // .context // "check")] | join(", ")')"
  [[ -z "$failed" ]] || refuse "a check failed on PR #$pr: $failed"
  if ((dry)); then echo "WOULD MERGE $branch $pr into $integration"; exit 0; fi
  out="$(gh api -X PUT "repos/$repo/pulls/$pr/merge" -f merge_method=merge -f sha="$full" 2>&1)" \
    || refuse "GitHub refused the merge of PR #$pr: $(head -1 <<<"$out")"
  msha="$(jq -r '.sha // empty' <<<"$out" 2>/dev/null)"
  [[ -n "$msha" ]] || refuse "GitHub gave no merge commit for PR #$pr: $(head -1 <<<"$out")"
  subject="$title"; [[ "$issue" =~ ^#[0-9]+$ ]] && subject="$issue"
  write_note "$subject" "PR #$pr" "$msha"
  echo "MERGED $branch $pr $msha"
  exit 0
fi

# ---- Local tracker ----
rec="$WF_PROJECT/.claude/workflow/local-mr/${branch//\//-}.json"
[[ -f "$rec" ]] || refuse "no local merge request for $branch"
[[ "$(jq -r '.state // "open"' "$rec")" == open ]] || refuse "the merge request of $branch is not open"
[[ "$(jq -r '.base // ""' "$rec")" == "$integration" ]] || refuse "the merge request of $branch does not target $integration"
[[ "$(jq -r '.head // ""' "$rec")" == "$branch" ]] || refuse "the merge request record of $branch names another head"
remote="$(wf_remote)"
g() { git -C "$WF_TOP" "$@"; }
if [[ -n "$remote" ]]; then
  g fetch -q "$remote" "$branch" "$integration" 2>/dev/null || refuse "git fetch $remote $branch $integration failed"
  tip="$(g rev-parse -q --verify "refs/remotes/$remote/$branch" 2>/dev/null)" || refuse "$remote/$branch does not exist"
  [[ "$tip" == "$full" ]] || refuse "head changed: $remote/$branch is at ${tip:0:12}, expected ${full:0:12}"
  old="$(g rev-parse -q --verify "refs/remotes/$remote/$integration" 2>/dev/null)" || refuse "$remote/$integration does not exist"
  local_old="$(g rev-parse -q --verify "refs/heads/$integration" 2>/dev/null || true)"
  if [[ -n "$local_old" ]] && ! g merge-base --is-ancestor "$local_old" "$old" 2>/dev/null; then
    refuse "local $integration has commits not on $remote; push or reconcile them first"
  fi
else
  tip="$(g rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)" || refuse "branch $branch does not exist"
  [[ "$tip" == "$full" ]] || refuse "head changed: $branch is at ${tip:0:12}, expected ${full:0:12}"
  old="$(g rev-parse -q --verify "refs/heads/$integration" 2>/dev/null)" || refuse "branch $integration does not exist"
  local_old="$old"
fi
g merge-base --is-ancestor "$full" "$old" 2>/dev/null && refuse "$branch is already in $integration"
g merge-tree --write-tree "$old" "$full" >/dev/null 2>&1; rc=$?
((rc == 0)) || { ((rc == 1)) && refuse "$branch conflicts with $integration"; refuse "git merge-tree failed"; }
where="$(g worktree list --porcelain 2>/dev/null | awk -v b="branch refs/heads/$integration" \
  '$1 == "worktree" { sub(/^worktree /, ""); w = $0 } $0 == b { print w; exit }')"
[[ -z "$where" ]] || refuse "$integration is checked out in $where; remove that worktree or merge by hand"
if ((dry)); then echo "WOULD MERGE $branch $branch into $integration"; exit 0; fi

tmp="$WF_TOP/.claude/worktrees/${integration//\//-}-automerge"
[[ ! -e "$tmp" ]] || refuse "$tmp exists (a stale throwaway worktree); remove it and run again"
g worktree add -q --detach "$tmp" "$old" >/dev/null 2>&1 || refuse "could not create the throwaway worktree $tmp"
trap 'git -C "$WF_TOP" worktree remove --force "$tmp" >/dev/null 2>&1' EXIT
if ! mout="$(git -C "$tmp" merge --no-ff --no-edit -m "Merge branch '$branch' into $integration" "$full" 2>&1)"; then
  git -C "$tmp" merge --abort >/dev/null 2>&1
  refuse "merge of $branch into $integration failed: $(head -1 <<<"$mout")"
fi
new="$(git -C "$tmp" rev-parse HEAD)"
g update-ref -m "merge-task-pr: $branch" "refs/heads/$integration" "$new" "$local_old" 2>/dev/null \
  || refuse "$integration moved during the merge; nothing pushed"
if [[ -n "$remote" ]]; then
  if ! pout="$(g push -q "$remote" "refs/heads/$integration:refs/heads/$integration" 2>&1)"; then
    if [[ -n "$local_old" ]]; then g update-ref "refs/heads/$integration" "$local_old" "$new"
    else g update-ref -d "refs/heads/$integration" "$new"; fi
    refuse "push of $integration to $remote was rejected; local ref restored: $(head -1 <<<"$pout")"
  fi
  g fetch -q "$remote" "$integration" >/dev/null 2>&1 || true
fi
"$here/mark-merged.sh" "$branch" >/dev/null || refuse "merged $branch into $integration (${new:0:12}) but could not mark its merge request merged"
tmpf="$(mktemp "$rec.XXXXXX")" && jq --arg s "$new" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.merge_sha = $s | .merged_at = $t' "$rec" >"$tmpf" && mv "$tmpf" "$rec"
write_note "$title" "MR $branch" "$new"
echo "MERGED $branch $branch $new"
