#!/usr/bin/env bash
# merge-task-pr.sh (opt-in auto-merge of a task PR into its integration branch) with the REAL
# check-pr-ready.sh, check-task.sh, check-review.sh and code-head.sh: a throwaway repository per mode
# (GitHub with a fake gh, local tracker with a remote, local tracker without one), plus gh-watch.sh
# --ready in local mode and the doctor.sh auto-merge lines. Never touches the network or real GitHub.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
M="$SRC/scripts/merge-task-pr.sh"
FAKE_MSHA=abcdef0123456789abcdef0123456789abcdef01

# A gh of our own (tests/bin/gh stays as it is): logs every call, answers pr list / pr view from
# $GH_PR_JSON, and the merge API with a fake merge commit. Everything else fails.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
q=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [[ "${args[$i]}" == -q ]] && q="${args[$((i+1))]}"; done
if [[ "$1 $2" == "pr list" ]]; then
  data='[{"number":8}]'
  jq -r "$q" <<<"$data"
elif [[ "$1 $2" == "pr view" ]]; then
  cat "$GH_PR_JSON"
elif [[ "$1 $2 $3" == "api -X PUT" && "$4" == repos/*/pulls/*/merge ]]; then
  printf '{"sha":"%s","merged":true}\n' "$GH_MERGE_SHA"
else
  echo "fake gh: unexpected call: $*" >&2; exit 99
fi
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_PR_JSON="$T/pr.json" GH_MERGE_SHA="$FAKE_MSHA"
: >"$GH_LOG"

# mk_repo <dir> <github|local-remote|local-solo>: a repo whose project is its root, with base dev, the
# integration branch INT, a feature plan with tasks T1 and T2 (Files: notes.txt / shared.txt) and the
# ignore lines the workflow needs. Sets P (the project), BARE (the remote, or empty).
mk_repo() {
  P="$1"; BARE=""
  git init -q -b dev "$P"; mkdir -p "$P/.claude" "$P/docs/demo"
  local tracker=github remote='"origin"'
  [[ "$2" == github ]] || tracker=local
  [[ "$2" == local-solo ]] && remote='""'
  if [[ "$2" == github ]]; then
    INT=feat/7-demo; B1=feat/8-demo-notes; B2=feat/9-demo-other; I1='#8'; I2='#9'
    tpl='feat/{feature_issue}-{feature_slug}'
    jq -n --arg tpl "$tpl" '{tracker: "github", github: {repo: "acme/shop", remote: "origin"}}' >"$P/.claude/base.json"
  else
    INT=feat/demo; B1=feat/demo-notes; B2=feat/demo-other; I1=local; I2=local
    tpl='feat/{feature_slug}'
    jq -n --argjson r "$remote" '{tracker: "local", remote: $r}' >"$P/.claude/base.json"
  fi
  jq --arg tpl "$tpl" '. + {
    branches: {base: "dev", protected: ["dev", "main"], prefix: "feat/"},
    conventions: {commit_types: ["feat", "fix", "docs", "chore"]},
    docs_dir: "docs",
    task_limits: {max_lines: 300, max_files: 10},
    naming: {integration_branch: $tpl, task_branch: "{task_type}/{task_issue}-{task_slug}"},
    auto_merge: {task_prs: true, method: "merge"}}' "$P/.claude/base.json" >"$P/.claude/workflow.json"
  rm "$P/.claude/base.json"
  printf '%s\n' '.claude/workflow/' '.claude/worktrees/' 'docs/*/reviews/' 'docs/*/evidence/' >"$P/.gitignore"
  cat >"$P/docs/demo/plan.md" <<EOF
# Plan: Demo
Status: approved.

## Wave 0

## T1: Add notes  [ ]
- **Type**: feat
- **Lane**: A
- **Issue**: $I1
- **Branch**: \`$B1\`
- **PR target**: \`$INT\`
- **Files**: \`notes.txt\` (new)

## T2: Change shared  [ ]
- **Type**: feat
- **Lane**: B
- **Issue**: $I2
- **Branch**: \`$B2\`
- **PR target**: \`$INT\`
- **Files**: \`shared.txt\`

## Risks
EOF
  echo base >"$P/shared.txt"
  git -C "$P" add -A && git -C "$P" commit -q -m "chore: init"
  git -C "$P" branch "$INT" dev
  if [[ "$2" != local-solo ]]; then
    BARE="$P-origin.git"; git init -q --bare "$BARE"
    git -C "$P" remote add origin "$BARE"
    git -C "$P" push -q origin dev "$INT"
  fi
}

# mk_task <task> <branch> <file> <content>: the task's worktree where the workflow keeps it, one
# commit of the file, the branch pushed (with a remote) and a passing review report.
mk_task() {
  local wt; wt="$(cd "$P" && bash -c 'source "$SRC/scripts/lib/config.sh" && wf_worktree_path "$1"' _ "$2")"
  git -C "$P" worktree add -q -b "$2" "$wt" "$INT" || return 1
  printf '%s\n' "$4" >"$wt/$3"
  git -C "$wt" add "$3" && git -C "$wt" commit -q -m "feat: work of $1"
  [[ -n "$BARE" ]] && git -C "$wt" push -q origin "$2"
  review "$wt" "$1" PASS
  echo "$wt"
}
# review <worktree> <task> <verdict>: the review report, uncommitted, on the worktree's CODE_HEAD.
review() {
  local ch; ch="$(cd "$1" && "$SRC/scripts/code-head.sh")"
  mkdir -p "$1/docs/demo/reviews"
  printf '# Review of %s\n\n## Final verdict\nVerdict: %s\nReviewed commit: %s\n' "$2" "$3" "$ch" >"$1/docs/demo/reviews/$2.md"
}

# run <args...>: merge-task-pr.sh from the project; sets out, err, rc.
run() { out="$(cd "$P" && "$M" "$@" 2>"$T/err")"; rc=$?; err="$(cat "$T/err")"; }
puts() { grep -c 'api -X PUT' "$GH_LOG" || true; }
# refused <name> <substring of the reason> <args...>: exit 3, "REFUSED ..." on stderr, nothing merged.
refused() {
  local name="$1" want="$2"; shift 2
  : >"$GH_LOG"; run "$@"
  [[ $rc == 3 && "$err" == REFUSED* && "$err" == *"$want"* && -z "$out" && "$(puts)" == 0 ]] \
    && ok "$name" || ko "$name: rc $rc out [$out] err [$err] puts $(puts)"
}
waits() { # <name> <substring> <args...>
  local name="$1" want="$2"; shift 2
  : >"$GH_LOG"; run "$@"
  [[ $rc == 4 && "$err" == WAIT* && "$err" == *"$want"* && "$(puts)" == 0 ]] && ok "$name" || ko "$name: rc $rc err [$err]"
}
cfg_set() { jq "$1" "$P/.claude/workflow.json" >"$T/wf.json" && cp "$T/wf.json" "$P/.claude/workflow.json"; }
# With the plan as a throwaway edit: plan_sed <sed expr> then restore_plan.
plan_sed() { cp "$P/docs/demo/plan.md" "$T/plan.bak"; sed -E -i.sedbak "$1" "$P/docs/demo/plan.md"; rm -f "$P/docs/demo/plan.md.sedbak"; }
restore_plan() { cp "$T/plan.bak" "$P/docs/demo/plan.md"; }
# pr_json <state...>: the PR as GitHub reports it, by jq edit of the default.
pr_default() {
  jq -n --arg sha "$HEAD1" --arg base "$INT" --arg head "$B1" \
    '{state: "OPEN", isDraft: false, baseRefName: $base, headRefName: $head, headRefOid: $sha, mergeable: "MERGEABLE",
      statusCheckRollup: [{__typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "SUCCESS"},
                          {__typename: "StatusContext", context: "ci/x", state: "SUCCESS"}]}' >"$GH_PR_JSON"
}
pr_edit() { jq "$1" "$GH_PR_JSON" >"$T/pr.tmp" && mv "$T/pr.tmp" "$GH_PR_JSON"; }

# =====================================================================================================
# GitHub
# =====================================================================================================
mk_repo "$T/gh" github
WT1="$(mk_task T1 "$B1" notes.txt notes)"
HEAD1="$(git -C "$WT1" rev-parse HEAD)"
INT_TIP="$(git -C "$P" rev-parse "$INT")"
pr_default
S=(demo T1 --sha "$HEAD1")
NOTES="$P/.claude/workflow/demo/notes.md"

# the usage
: >"$GH_LOG"; run demo T1; [[ $rc == 2 && "$err" == usage* ]] && ok "usage: --sha is required (exit 2)" || ko "usage: $rc $err"
run demo T1 --sha "$HEAD1" --bogus; [[ $rc == 2 ]] && ok "usage: an unknown flag exits 2" || ko "usage flag: $rc"

# the opt-in
cfg_set '.auto_merge.task_prs = false'
refused "auto_merge.task_prs false -> REFUSED, mentions off" "is off" "${S[@]}"
cfg_set 'del(.auto_merge)'
refused "no auto_merge key -> REFUSED (off by default)" "is off" "${S[@]}"
cfg_set '.auto_merge = {task_prs: true, method: "squash"}'
refused "method squash -> REFUSED" "squash" "${S[@]}"
cfg_set '.auto_merge = {task_prs: true, method: "merge"}'

# the integration branch rules (all tasks' PR targets change together)
plan_sed 's/^(- \*\*PR target\*\*: `)[^`]*`/\1dev`/'
refused "PR target = base -> REFUSED base branch" "base branch" "${S[@]}"
restore_plan
cfg_set '.branches.protected = ["dev", "main", "release"]'
plan_sed 's/^(- \*\*PR target\*\*: `)[^`]*`/\1release`/'
refused "PR target protected (not base) -> REFUSED protected" "protected" "${S[@]}"
restore_plan
cfg_set '.branches.protected = ["dev", "main"]'
plan_sed 's/^(- \*\*PR target\*\*: `)[^`]*`/\1feat\/zzz`/'
refused "PR target not matching naming.integration_branch -> REFUSED" "naming.integration_branch" "${S[@]}"
restore_plan
plan_sed '/^## T2:/,$ s/^(- \*\*PR target\*\*: `)[^`]*`/\1feat\/9-other`/'
refused "tasks with different PR targets -> REFUSED share" "share" "${S[@]}"
restore_plan

# a standalone task
mv "$P/docs/demo/plan.md" "$T/plan.hidden"; mkdir -p "$P/.claude/workflow/demo"; cp "$T/plan.hidden" "$P/.claude/workflow/demo/plan.md"
refused "standalone task (plan only under .claude/workflow) -> REFUSED standalone" "standalone" "${S[@]}"
rm -rf "$P/.claude/workflow/demo"; mv "$T/plan.hidden" "$P/docs/demo/plan.md"
refused "unknown task -> REFUSED" "not in the plans" demo T9 --sha "$HEAD1"
refused "bad feature name -> REFUSED" "feature folder" 'De mo' T1 --sha "$HEAD1"

# the sha
refused "--sha of another commit -> REFUSED head changed" "head changed" demo T1 --sha "$INT_TIP"
refused "--sha unknown commit -> REFUSED" "not known" demo T1 --sha 1234567
pr_edit '.headRefOid = "'"$INT_TIP"'"'
refused "PR headRefOid differs from --sha -> REFUSED head changed" "head changed" "${S[@]}"
pr_default

# the review gate
review "$WT1" T1 FAIL
refused "review verdict FAIL -> REFUSED check-pr-ready" "check-pr-ready" "${S[@]}"
rm "$WT1/docs/demo/reviews/T1.md"
refused "no review report -> REFUSED check-pr-ready" "check-pr-ready" "${S[@]}"
review "$WT1" T1 PASS

# the PR
pr_edit '.baseRefName = "dev"';           refused "PR base differs -> REFUSED" "targets dev" "${S[@]}"; pr_default
pr_edit '.isDraft = true';                refused "draft PR -> REFUSED" "draft" "${S[@]}"; pr_default
pr_edit '.state = "MERGED"';              refused "PR not open -> REFUSED" "MERGED" "${S[@]}"; pr_default
pr_edit '.mergeable = "CONFLICTING"';     refused "mergeable CONFLICTING -> REFUSED" "conflicts" "${S[@]}"; pr_default
pr_edit '.mergeable = "UNKNOWN"';         waits "mergeable UNKNOWN -> exit 4 WAIT" "mergeability" "${S[@]}"; pr_default
pr_edit '.statusCheckRollup += [{__typename: "CheckRun", name: "build", status: "IN_PROGRESS", conclusion: ""}]'
waits "a check IN_PROGRESS -> exit 4 WAIT" "checks still running" "${S[@]}"; pr_default
pr_edit '.statusCheckRollup += [{__typename: "StatusContext", context: "ci/slow", state: "PENDING"}]'
waits "a status context PENDING -> exit 4 WAIT" "checks still running" "${S[@]}"; pr_default
pr_edit '.statusCheckRollup += [{__typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE"}]'
refused "a check FAILURE -> REFUSED naming the check" "lint" "${S[@]}"; pr_default
pr_edit '.statusCheckRollup += [{__typename: "StatusContext", context: "ci/legacy", state: "FAILURE"}]'
refused "a status context FAILURE -> REFUSED naming it" "ci/legacy" "${S[@]}"; pr_default
pr_edit '.statusCheckRollup += [{__typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED"}]'
: >"$GH_LOG"; run "${S[@]}" --dry-run
[[ $rc == 0 ]] && ok "a SKIPPED check counts as green" || ko "skipped check: $rc $err"; pr_default

# --dry-run
: >"$GH_LOG"; run "${S[@]}" --dry-run
[[ $rc == 0 && "$out" == "WOULD MERGE $B1 8 into $INT" && "$(puts)" == 0 && ! -e "$NOTES" ]] \
  && ok "--dry-run: WOULD MERGE, no PUT, no notes.md" || ko "dry-run: rc $rc [$out] [$err] puts $(puts)"
: >"$GH_LOG"; run "${S[@]}" --dry-run --pr 8
[[ $rc == 0 && "$out" == WOULD* ]] && ! grep -q 'pr list' "$GH_LOG" && ok "--pr skips pr list" || ko "--pr: $rc [$out] $(cat "$GH_LOG")"

# the happy path
: >"$GH_LOG"; run "${S[@]}"
[[ $rc == 0 && "$out" == "MERGED $B1 8 $FAKE_MSHA" ]] && ok "happy path: exit 0, MERGED <branch> <pr> <merge sha>" || ko "happy: rc $rc [$out] [$err]"
grep -qxF -- "api -X PUT repos/acme/shop/pulls/8/merge -f merge_method=merge -f sha=$HEAD1" "$GH_LOG" && [[ "$(puts)" == 1 ]] \
  && ok "happy path: one merge API call, method merge, pinned to the full head sha" || ko "PUT: $(cat "$GH_LOG")"
! grep -q 'pr merge' "$GH_LOG" && ok "happy path: never gh pr merge" || ko "gh pr merge was called"
[[ "$(cat "$NOTES" 2>/dev/null)" == "- #8: auto-merged PR #8 (abcdef0)" ]] && ok "happy path: notes.md line" || ko "notes: $(cat "$NOTES" 2>&1)"
run "${S[@]}"
[[ $rc == 0 && "$(grep -c . "$NOTES")" == 1 ]] && ok "merging again does not duplicate the notes line" || ko "notes twice: $(cat "$NOTES")"

# doctor: the auto-merge lines
doc() { (cd "$P" && bash "$SRC/scripts/doctor.sh" --offline 2>&1); }
out="$(doc)"; grep -Eq '^OK    auto-merge +on' <<<"$out" && ok "doctor: auto-merge on" || ko "doctor on: $(grep auto <<<"$out")"
cfg_set '.auto_merge.method = "squash"'; out="$(doc)"
grep -q '^FAIL  auto_merge.method' <<<"$out" && ok "doctor: FAIL auto_merge.method for squash" || ko "doctor squash: $(grep auto <<<"$out")"
cfg_set 'del(.auto_merge)'; out="$(doc)"
grep -Eq '^OK    auto-merge +off' <<<"$out" && ok "doctor: auto-merge off without the key" || ko "doctor off: $(grep auto <<<"$out")"
cfg_set '.auto_merge = {task_prs: false, method: "merge"}'; out="$(doc)"
grep -Eq '^OK    auto-merge +off' <<<"$out" && ok "doctor: auto-merge off when task_prs is false" || ko "doctor false: $(grep auto <<<"$out")"
cfg_set '.auto_merge = {task_prs: "yes", method: "merge"}'; out="$(doc)"
grep -q '^FAIL  auto_merge.task_prs' <<<"$out" && ok "doctor: FAIL auto_merge.task_prs for a non-boolean" || ko "doctor non-bool: $(grep auto <<<"$out")"

# =====================================================================================================
# Local tracker with a remote
# =====================================================================================================
mk_repo "$T/lr" local-remote
WT1="$(mk_task T1 "$B1" notes.txt notes)"
WT2="$(mk_task T2 "$B2" shared.txt other)"
HEAD1="$(git -C "$WT1" rev-parse HEAD)"; HEAD2="$(git -C "$WT2" rev-parse HEAD)"
echo "Body" >"$T/body.md"
# (create-pr exits 1 when it has no link to print, so look for the record instead of the exit code)
for b in "$B1" "$B2"; do
  (cd "$P" && "$SRC/scripts/local-ops.sh" create-pr "$b" "$INT" "feat: $b" "$T/body.md" >/dev/null 2>&1)
  [[ -f "$P/.claude/workflow/local-mr/${b//\//-}.json" ]] || ko "create-pr $b made no record"
done
S=(demo T1 --sha "$HEAD1")
NOTES="$P/.claude/workflow/demo/notes.md"
REC="$P/.claude/workflow/local-mr/${B1//\//-}.json"
INT_OLD="$(git -C "$P" rev-parse "$INT")"; DEV_OLD="$(git -C "$BARE" rev-parse dev)"
: >"$GH_LOG"

# gh-watch --ready in local mode (the branch is OPEN)
tip="$(git -C "$P" rev-parse "origin/$B1" 2>/dev/null || git -C "$BARE" rev-parse "$B1")"
out="$(cd "$P" && "$SRC/scripts/gh-watch.sh" "$B1:local" --ready)"; rc=$?
[[ $rc == 30 && "$out" == *"READY $B1 ready-${tip:0:12} $tip"* ]] && ok "gh-watch --ready local: OPEN branch is READY, exit 30" || ko "ready local: rc $rc $out"
out="$(cd "$P" && "$SRC/scripts/gh-watch.sh" "$B1:local" --ready --handled "ready-${tip:0:12}")"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "gh-watch --ready local: handled id -> exit 0, no READY" || ko "ready handled: rc $rc $out"
out="$(cd "$P" && "$SRC/scripts/gh-watch.sh" "$B1:local")"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "gh-watch local without --ready: no READY, exit 0" || ko "no ready flag: rc $rc $out"

# the sha
refused "local+remote: --sha of another commit -> REFUSED, integration unchanged" "head changed" demo T1 --sha "$INT_OLD"
[[ "$(git -C "$P" rev-parse "$INT")" == "$INT_OLD" && "$(git -C "$BARE" rev-parse "$INT")" == "$INT_OLD" ]] \
  && ok "local+remote: no merge happened on a refused sha" || ko "integration moved"
# the integration branch checked out elsewhere
git -C "$P" worktree add -q "$T/lr-int" "$INT"
refused "local+remote: integration checked out in a worktree -> REFUSED checked out" "checked out" "${S[@]}"
git -C "$P" worktree remove --force "$T/lr-int"
# dry run
run "${S[@]}" --dry-run
[[ $rc == 0 && "$out" == "WOULD MERGE $B1 $B1 into $INT" && "$(git -C "$BARE" rev-parse "$INT")" == "$INT_OLD" && ! -e "$NOTES" ]] \
  && ok "local+remote: --dry-run changes nothing" || ko "local dry-run: rc $rc [$out] [$err]"
# push rejected: a pre-receive hook in the remote
printf '#!/bin/sh\necho "no pushes today" >&2\nexit 1\n' >"$BARE/hooks/pre-receive"; chmod +x "$BARE/hooks/pre-receive"
refused "local+remote: push rejected -> REFUSED rejected" "rejected" "${S[@]}"
[[ "$(git -C "$P" rev-parse "$INT")" == "$INT_OLD" && "$(git -C "$BARE" rev-parse "$INT")" == "$INT_OLD" \
  && "$(jq -r .state "$REC")" == open && ! -e "$P/.claude/worktrees/${INT//\//-}-automerge" ]] \
  && ok "local+remote: rejected push restores the local ref, record stays open, no throwaway worktree" \
  || ko "after rejection: local $(git -C "$P" rev-parse "$INT") record $(jq -r .state "$REC")"
rm "$BARE/hooks/pre-receive"

# the happy path
run "${S[@]}"
NEW="$(git -C "$BARE" rev-parse "$INT")"
[[ $rc == 0 && "$out" == "MERGED $B1 $B1 $NEW" ]] && ok "local+remote: MERGED line with the merge commit" || ko "local happy: rc $rc [$out] [$err]"
[[ "$(git -C "$BARE" rev-parse "$INT^2")" == "$HEAD1" && "$(git -C "$BARE" rev-parse "$INT^1")" == "$INT_OLD" \
  && "$(git -C "$BARE" rev-list --parents -n1 "$INT" | wc -w | tr -d ' ')" == 3 ]] \
  && ok "local+remote: remote integration branch has a merge commit, second parent is the task sha" || ko "merge commit shape"
[[ "$(git -C "$P" rev-parse "$INT")" == "$NEW" ]] && ok "local+remote: local integration ref follows" || ko "local ref"
[[ "$(git -C "$BARE" rev-parse dev)" == "$DEV_OLD" ]] && ok "local+remote: remote dev unchanged" || ko "dev moved"
[[ "$(jq -r .state "$REC")" == merged && "$(jq -r .merge_sha "$REC")" == "$NEW" ]] \
  && ok "local+remote: record is merged with merge_sha" || ko "record: $(cat "$REC")"
(cd "$P" && "$SRC/scripts/local-ops.sh" get-pr-state "$B1") | grep -q 'MERGED' && ok "local+remote: get-pr-state MERGED" || ko "get-pr-state"
out="$(cd "$P" && "$SRC/scripts/gh-watch.sh" "$B1:local")"; rc=$?
[[ $rc == 10 && "$out" == *"STATE $B1 MERGED"* ]] && ok "local+remote: gh-watch exit 10, STATE MERGED" || ko "gh-watch after merge: rc $rc $out"
[[ "$(cat "$NOTES" 2>/dev/null)" == "- Add notes: auto-merged MR $B1 (${NEW:0:7})" ]] \
  && ok "local+remote: notes.md line" || ko "notes: $(cat "$NOTES" 2>&1)"
! git -C "$P" worktree list | grep -q automerge && [[ ! -e "$P/.claude/worktrees/${INT//\//-}-automerge" ]] \
  && ok "local+remote: the -automerge throwaway worktree is gone" || ko "automerge worktree left: $(git -C "$P" worktree list)"
refused "local+remote: merging again -> REFUSED (not open)" "not open" "${S[@]}"
[[ ! -s "$GH_LOG" ]] && ok "local tracker never calls gh" || ko "gh called: $(cat "$GH_LOG")"

# a conflict: the integration branch moved on the remote in the file the second task changed
git clone -q -b "$INT" "$BARE" "$T/lr-clone"
echo theirs >"$T/lr-clone/shared.txt" && git -C "$T/lr-clone" commit -q -am "fix: change shared" && git -C "$T/lr-clone" push -q origin "$INT"
OLD2="$(git -C "$BARE" rev-parse "$INT")"
refused "local+remote: conflict with the integration branch -> REFUSED conflicts" "conflicts" demo T2 --sha "$HEAD2"
[[ "$(git -C "$BARE" rev-parse "$INT")" == "$OLD2" ]] && ok "local+remote: a conflict changes nothing" || ko "conflict moved the remote"

# =====================================================================================================
# Local tracker without a remote
# =====================================================================================================
mk_repo "$T/ln" local-solo
WT1="$(mk_task T1 "$B1" notes.txt notes)"
HEAD1="$(git -C "$WT1" rev-parse HEAD)"
(cd "$P" && "$SRC/scripts/local-ops.sh" create-pr "$B1" "$INT" "feat: add notes" "$T/body.md" >/dev/null 2>&1)
[[ -f "$P/.claude/workflow/local-mr/${B1//\//-}.json" ]] || ko "create-pr made no record"
S=(demo T1 --sha "$HEAD1")
NOTES="$P/.claude/workflow/demo/notes.md"; REC="$P/.claude/workflow/local-mr/${B1//\//-}.json"
INT_OLD="$(git -C "$P" rev-parse "$INT")"
out="$(cd "$P" && "$SRC/scripts/gh-watch.sh" "$B1:local" --ready)"; rc=$?
[[ $rc == 30 && "$out" == *"READY $B1 ready-${HEAD1:0:12} $HEAD1"* ]] && ok "gh-watch --ready local, no remote: tip is the local branch" || ko "ready solo: rc $rc $out"
refused "local solo: --sha of another commit -> REFUSED" "head changed" demo T1 --sha "$INT_OLD"
run "${S[@]}"
NEW="$(git -C "$P" rev-parse "$INT")"
[[ $rc == 0 && "$out" == "MERGED $B1 $B1 $NEW" && "$NEW" != "$INT_OLD" ]] && ok "local solo: MERGED line" || ko "solo happy: rc $rc [$out] [$err]"
[[ "$(git -C "$P" rev-parse "$INT^2")" == "$HEAD1" && "$(git -C "$P" rev-parse "$INT^1")" == "$INT_OLD" \
  && "$(git -C "$P" rev-list --parents -n1 "$INT" | wc -w | tr -d ' ')" == 3 ]] \
  && ok "local solo: --no-ff merge commit, second parent is the task sha" || ko "solo merge shape"
[[ "$(jq -r .state "$REC")" == merged && "$(jq -r .merge_sha "$REC")" == "$NEW" ]] && ok "local solo: record merged" || ko "solo record: $(cat "$REC")"
[[ "$(cat "$NOTES" 2>/dev/null)" == "- Add notes: auto-merged MR $B1 (${NEW:0:7})" ]] && ok "local solo: notes.md line" || ko "solo notes: $(cat "$NOTES" 2>&1)"
! git -C "$P" worktree list | grep -q automerge && ok "local solo: no throwaway worktree left" || ko "solo worktree"

done_tests
