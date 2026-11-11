#!/usr/bin/env bash
# Local tracker ("tracker": "local"): local-ops.sh, mark-merged.sh and build-position.sh without gh,
# with a GitLab-like remote (a bare repository) and with no remote at all.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# A gh that always fails: nothing here may call it.
mkdir -p "$T/bin" && printf '#!/bin/sh\necho "gh called: $*" >&2\nexit 99\n' >"$T/bin/gh" && chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# make_app <dir> <remote json value>: a repo whose project is its root, base branch dev.
make_app() {
  git init -q -b dev "$1"
  mkdir -p "$1/.claude" "$1/specs/demo"
  cat >"$1/.claude/workflow.json" <<EOF
{
  "tracker": "local",
  "remote": $2,
  "branches": { "base": "dev", "protected": ["dev", "main"], "prefix": "feat/" },
  "docs_dir": "specs",
  "naming": {
    "feature_issue_title": "Feature: {feature_name}", "integration_branch": "feat/{feature_slug}",
    "task_branch": "{task_type}/{feature_slug}-{task_slug}", "task_pr_title": "{task_type}: {task_title}",
    "final_pr_title": "feat: {feature_name}", "task_commit": "{task_type}: {task_title}"
  }
}
EOF
  printf '# Intent: Demo thing\nStatus: approved.\n' >"$1/specs/demo/intent.md"
  echo base >"$1/README.txt"
  git -C "$1" add -A && git -C "$1" commit -q -m init
}
ops() { "$SRC/scripts/local-ops.sh" "$@"; }

# ---------- with a remote whose URL looks like GitLab ----------
git init -q --bare "$T/remote.git"
make_app "$T/app" '"origin"'
cd "$T/app"
git remote add origin "$T/remote.git"
git push -q origin dev

# 1. config helpers
out="$(bash -c 'source $SRC/scripts/lib/config.sh && echo "$(wf_tracker)|$(wf_remote)|$(wf_ref dev)" && wf_issue_ok local && ! wf_issue_ok "#3" && echo ok')"
[[ "$out" == $'local|origin|origin/dev\nok' ]] && ok "config: tracker, remote, ref, issue check" || ko "config: $out"

# 2. feature issue: create, idempotent, find, labels, comment
out="$(ops create-issue specs/demo/intent.md)"
[[ "$out" == "demo - new labels: feature, phase:plan-done" ]] && ok "create-issue: new" || ko "create-issue: $out"
out="$(ops create-issue specs/demo/intent.md)"
[[ "$out" == *"already existed"* ]] && ok "create-issue: idempotent" || ko "create-issue again: $out"
jq -e '.title == "Feature: Demo thing"' .claude/workflow/demo/tracker.json >/dev/null && ok "create-issue: title from naming" || ko "title"
out="$(ops swap-label demo phase:plan-done phase:design-done)"
[[ "$out" == "demo - labels: feature, phase:design-done" ]] && ok "swap-label: feature" || ko "swap-label: $out"
out="$(ops find-issue specs/demo/intent.md)"
[[ "$out" == "demo - labels: feature, phase:design-done" ]] && ok "find-issue" || ko "find-issue: $out"
[[ "$(ops find-issue specs/other/intent.md)" == "not found" ]] && ok "find-issue: not found" || ko "find-issue missing"
ops comment demo "Spec approved." >/dev/null && grep -q "Spec approved." .claude/workflow/demo/log.md \
  && ok "comment: feature log" || ko "comment"
[[ "$(ops swap-label local status:todo status:in-progress)" == local* ]] && ok "swap-label: task is a no-op" || ko "swap-label task"
[[ "$(ops create-sub-issue demo "Add x" T1)" == "local - new"* ]] && ok "create-sub-issue: local" || ko "create-sub-issue"
ops close-issue demo >/dev/null 2>&1 && ko "close-issue refused the feature" || ok "close-issue: refuses the feature"
printf '# Intent: X\nStatus: draft.\n' >"$T/draft.md"; mkdir -p specs/x && cp "$T/draft.md" specs/x/intent.md
ops create-issue specs/x/intent.md >/dev/null 2>&1 && ko "create-issue: unapproved" || ok "create-issue: refuses an unapproved intent"

# 3. merge request: create, state OPEN, merge commit -> MERGED
git branch feat/demo dev && git push -q origin feat/demo
git switch -q -c feat/demo-notes feat/demo
echo notes >notes.txt && git add notes.txt && git commit -q -m "feat: add notes"
echo "Body text" >"$T/body.md"
ops create-pr feat/demo-notes feat/demo "feat: add notes" "$T/body.md" >/dev/null 2>&1 \
  && ko "create-pr: refused an unpushed branch" || ok "create-pr: needs the branch on the remote"
git push -q origin feat/demo-notes
[[ "$(ops get-pr-state feat/demo-notes)" == "feat/demo-notes NONE" ]] && ok "get-pr-state: NONE before create-pr" || ko "NONE"
# A GitLab URL for the link, rewritten to the bare repository for git itself.
git remote set-url origin "git@gitlab.example.com:grp/app.git"
git config url."$T/remote.git".insteadOf "git@gitlab.example.com:grp/app.git"
out="$(ops create-pr feat/demo-notes feat/demo "feat: add notes" "$T/body.md" 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *" new"* && "$out" == *"OPEN_MR=https://gitlab.example.com/grp/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/demo-notes&merge_request%5Btarget_branch%5D=feat/demo"* ]] \
  && ok "create-pr: record and GitLab link" || ko "create-pr: $out"
md=.claude/workflow/local-mr/feat-demo-notes.md
grep -q "Body text" "$md" && grep -q 'Target branch: `feat/demo`' "$md" && ok "create-pr: merge request file" || ko "mr file"
[[ "$(ops create-pr feat/demo-notes feat/demo "t" "$T/body.md")" == *"already existed" ]] && ok "create-pr: idempotent" || ko "create-pr again"
[[ "$(ops get-pr-state feat/demo-notes)" == $'feat/demo-notes\tOPEN\tfeat/demo-notes' ]] && ok "get-pr-state: OPEN" || ko "OPEN: $(ops get-pr-state feat/demo-notes)"
[[ "$(ops find-pr feat/demo-notes)" == $'feat/demo-notes\tfeat/demo-notes\tOPEN\tfeat/demo\t'* ]] && ok "find-pr" || ko "find-pr: $(ops find-pr feat/demo-notes)"
printf '## Verification\nAll good.\n' >"$T/sec.md"
[[ "$(ops append-pr-section feat/demo-notes "$T/sec.md")" == *added ]] && [[ "$(ops append-pr-section feat/demo-notes "$T/sec.md")" == *replaced ]] \
  && [[ "$(grep -c '^## Verification' "$md")" == 1 ]] && ok "append-pr-section: added then replaced" || ko "append-pr-section"
[[ "$(ops get-pr-feedback feat/demo-notes)" == "no new feedback" && "$(ops get-pr-checks feat/demo-notes)" == "no failed checks" ]] \
  && ok "feedback and checks: none" || ko "feedback/checks"
# The user merges on the host (a merge commit), simulated in a second clone; the source branch is deleted.
git clone -q "$T/remote.git" "$T/host" && git -C "$T/host" switch -q feat/demo \
  && git -C "$T/host" merge -q --no-ff -m "Merge notes" origin/feat/demo-notes && git -C "$T/host" push -q origin feat/demo \
  && git -C "$T/host" push -q origin --delete feat/demo-notes
git fetch -q --prune origin
[[ "$(ops get-pr-state feat/demo-notes)" == *MERGED* ]] && ok "get-pr-state: MERGED by ancestry (source branch deleted)" || ko "MERGED: $(ops get-pr-state feat/demo-notes)"

# 4. squash merge: ancestry misses it, mark-merged settles it
git switch -q -c fix/demo-typo origin/feat/demo
echo typo >typo.txt && git add typo.txt && git commit -q -m "fix: typo" && git push -q origin fix/demo-typo
ops create-pr fix/demo-typo feat/demo "fix: typo" "$T/body.md" >/dev/null
git -C "$T/host" pull -q origin feat/demo && git -C "$T/host" merge -q --squash origin/fix/demo-typo 2>/dev/null \
  && git -C "$T/host" commit -q -m "fix: typo (squashed)" && git -C "$T/host" push -q origin feat/demo
git fetch -q origin
[[ "$(ops get-pr-state fix/demo-typo)" == *OPEN* ]] && ok "squash: still OPEN by ancestry" || ko "squash state"
cat >specs/demo/plan.md <<'EOF'
# Plan: Demo
Status: approved.

## Wave 0

## T1: Add notes  [ ]
- **Lane**: A
- **Issue**: local
- **Branch**: `feat/demo-notes`
- **PR target**: `feat/demo`

## T2: Fix typo  [ ]
- **Lane**: B
- **Issue**: local
- **Branch**: `fix/demo-typo`
- **PR target**: `feat/demo`

## Wave 1

## T3: Integration  [ ]
- **Lane**: solo
- **Issue**: local
- **Branch**: `chore/demo-integration` (only if fixes are needed)
- **PR target**: `feat/demo`
EOF
out="$("$SRC/scripts/mark-merged.sh" demo T2)"
[[ "$out" == "fix/demo-typo MERGED" && "$(ops get-pr-state fix/demo-typo)" == *MERGED* ]] && ok "mark-merged: by feature and task id" || ko "mark-merged: $out"

# 5. build-position accepts Issue: local
ops get-pr-state feat/demo-notes fix/demo-typo >"$T/states.tsv"
out="$("$SRC/scripts/build-position.sh" specs/demo/plan.md "$T/states.tsv")"
grep -q "^T1 .*status=done" <<<"$out" && grep -q "^T2 .*status=done" <<<"$out" && grep -q "^ACTION=integrate" <<<"$out" \
  && ok "build-position: Issue local, wave 0 done" || ko "build-position: $out"
sed -i.bak 's/^- \*\*Issue\*\*: local$/- **Issue**: pending/' specs/demo/plan.md
"$SRC/scripts/build-position.sh" specs/demo/plan.md "$T/states.tsv" | grep -q "no sub-issue number" \
  && ok "build-position: pending still blocks" || ko "build-position pending"

# ---------- no remote at all ----------
make_app "$T/solo" '""'
cd "$T/solo"
[[ "$(bash -c 'source $SRC/scripts/lib/config.sh && echo "[$(wf_remote)]$(wf_ref dev)" && wf_fetch dev && echo fetched')" == $'[]dev\nfetched' ]] \
  && ok "no remote: wf_ref is the local branch, wf_fetch does nothing" || ko "no remote helpers"
git branch feat/demo dev
git switch -q -c feat/demo-notes feat/demo
echo n >n.txt && git add n.txt && git commit -q -m "feat: n"
out="$(ops create-pr feat/demo-notes feat/demo "feat: n" "$T/body.md")"
grep -q 'git switch feat/demo && git merge --no-ff feat/demo-notes' .claude/workflow/local-mr/feat-demo-notes.md \
  && [[ "$out" != *OPEN_MR* ]] && ok "no remote: create-pr prints the merge command, no link" || ko "no remote create-pr: $out"
[[ "$(ops get-pr-state feat/demo-notes)" == *OPEN* ]] && ok "no remote: OPEN" || ko "no remote OPEN"
git switch -q feat/demo && git merge -q --ff-only feat/demo-notes
[[ "$(ops get-pr-state feat/demo-notes)" == *MERGED* ]] && ok "no remote: fast-forward merge is MERGED" || ko "no remote FF: $(ops get-pr-state feat/demo-notes)"
"$SRC/scripts/mark-merged.sh" feat/demo-notes --closed >/dev/null && [[ "$(ops get-pr-state feat/demo-notes)" == *CLOSED* ]] \
  && ok "mark-merged --closed" || ko "closed"
ops create-pr feat/demo feat/demo "x" "$T/body.md" >/dev/null 2>&1 && ko "create-pr: nothing to merge" || ok "create-pr: refuses a branch with nothing to merge"

done_tests
