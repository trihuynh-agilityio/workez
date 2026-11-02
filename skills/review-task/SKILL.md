---
name: review-task
description: Phase 3 (Build) local review loop for ONE task, after the implementer and before the UI check or PR. Reviews the task's commits, has the implementer fix blocker and major findings, and writes the review report. Run with the feature folder name and the task id.
model: opus
disable-model-invocation: true
allowed-tools: Read Write Edit Glob Grep Agent Bash(git diff*) Bash(git log*) Bash(git rev-parse *) Bash(git status*) Bash(git add *) Bash(git commit *) Bash(*/scripts/check-task.sh *) Bash(*/scripts/code-head.sh*) Bash(*/scripts/check-review.sh *)
---

# Review one task

The local review loop between the implementer and the UI check. It never creates a PR and never pushes.

Arguments: `<feature-name> <task-id>`, for example `saved-searches T4`.

## Paths

- Settings: `<project root>/.claude/workflow.json` (`docs_dir`, `github.remote` as `<remote>`, `branches.base` as `<base>`). The **project folder** of a worktree is the worktree root plus the project's path inside the repository (`git -C <project root> rev-parse --show-prefix`; empty at the root).
- Project root: the folder that holds `.claude/workflow.json` and `<docs_dir>`. Plan: `<project root>/<docs_dir>/<feature-name>/plan.md`, or `plan-fix.md` next to it when the task id is defined there (a fix task added by `workez:verify-feature`); that file is the plan path below. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/` (they find the project from the current folder, a worktree included; run from elsewhere, prefix `WF_PROJECT=<project root>`).
- Read the task's block in the plan. Its `Branch:` gives the worktree: `<repo root>/.claude/worktrees/<branch with / replaced by ->`. Its `PR target:` is the integration branch.
- In the worktree, work from its project folder. The report is `<docs_dir>/<feature-name>/reviews/<task-id>.md` there.

## 1. Preconditions

Stop and report if any fails:

- the worktree exists and is on the task's branch,
- `check-task.sh <task-id> <plan path>` passes,
- the task's `Verify:` command passes.

## 2. Round budget

Count the `## Round` sections already in the report (none if it does not exist). **At most 3 rounds in total**, counted across every run of this skill for the task, including re-runs after a UI check failure. If 3 are used and the last verdict is not PASS, or the code changed since a PASS, go to step 5.

## 3. Review

Call the `workez:code-reviewer` agent with the plan path, the task id, the worktree path, and, for a later round, the last reviewed commit as the base and the earlier findings with their statuses. Get `CODE_HEAD` from `code-head.sh` in the worktree. Append to the report:

```markdown
## Round <n>
- Reviewed commit: <full CODE_HEAD hash>
- Verdict: PASS | CHANGES_REQUIRED

| # | Severity | Location | Problem | Status |
|---|---|---|---|---|
```

Statuses: `open`, `fixed`, `wontfix: <reason>`, `minor`. The report starts with `# Review: <task id> <task title>` and a line with the branch. Keep it small: one line per finding.

## 4. Fix loop

- **CHANGES_REQUIRED**: send **only** the blocker and major findings to the `workez:implementer` agent in fix mode (same worktree, plan path, task id, the findings). It fixes them in a **new** commit, never an amend, re-runs `Verify:` and `check-task.sh` on the whole task diff, so the 300-line and 10-file limits are cumulative, and may answer a finding with `wontfix` and a written reason. Record each outcome in the report, then go back to step 2 for the next round.
- **PASS**: continue with step 6.

## 5. Blocked

If blocker or major findings are still open after round 3, write the final section with `Verdict: BLOCKED` (the same layout as step 6, without a PASS), show the user the open findings, and stop. No PR, no UI check.

## 6. PASS

Replace any earlier final section so the report ends with exactly one:

```markdown
## Final verdict
Verdict: PASS
Reviewed commit: <full CODE_HEAD hash>
Minor findings kept for the PR description: <list, or none>
```

Never commit the report: it stays local in the worktree (`reviews/` is git-ignored, and the gates accept it untracked). Run `check-review.sh <task-id> <plan path>` and make sure it passes. Then:

- if the task has a `UI check:`, call the `workez:ui-verifier` agent with the plan path, the task id, the worktree path and the task's lane (`solo` uses lane A),
- otherwise report "ready for PR".

Never create the PR here.

## Rules

- The reviewer and this skill never edit source code; only the implementer does, in fix mode.
- Never edit `intent.md`, `spec.md` `plan.md` or `plan-fix.md`. A finding about them goes to the user.
- Never push, merge or post to GitHub.
