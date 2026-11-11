---
name: create-task-pr
description: Phase 3 (Build) last step for ONE task: after the review loop (and the UI check, if the task has one), pushes the task branch and opens its pull request against the integration branch. Run with the feature folder name and the task id. It never merges or approves.
model: sonnet
disable-model-invocation: true
allowed-tools: Read Write Glob Grep Agent Skill Bash(git status*) Bash(git log*) Bash(git diff*) Bash(git rev-parse *) Bash(git add *) Bash(git commit *) Bash(git ls-remote *) Bash(*/scripts/check-pr-ready.sh *) Bash(*/scripts/code-head.sh*)
---

# Create the PR for one task

The last step of the per-task pipeline: implementer, Verify and guard, `workez:review-task`, `workez:ui-verifier` (UI tasks only), then this. It pushes the task branch and opens one pull request. It never merges, approves, or pushes anything else.

Arguments: `<feature-name> <task-id>`, for example `saved-searches T4`.

## Paths

- Settings: `<project root>/.claude/workflow.json` (`docs_dir`, `github.remote` as `<remote>`, `branches.base` as `<base>`). The **project folder** of a worktree is the worktree root plus the project's path inside the repository (`git -C <project root> rev-parse --show-prefix`; empty at the root).
- Project root: the folder that holds `.claude/workflow.json` and `<docs_dir>`. Plan: `<project root>/<docs_dir>/<feature-name>/plan.md`, or `plan-fix.md` next to it when the task id is defined there (a fix task added by `workez:verify-feature`); that file is the plan path below. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/` (they find the project from the current folder, a worktree included; run from elsewhere, prefix `WF_PROJECT=<project root>`).
- Read the task's block in the plan: `Branch:` (the head), `PR target:` (the base, the integration branch), `PR title:`, `Issue:`, `Covers:`, and whether it has a `UI check:`.
- The worktree is `<repo root>/.claude/worktrees/<branch with / replaced by ->`. Work from its project folder.


## Local tracker

With `"tracker": "local"` in `.claude/workflow.json`, follow "Local tracker" in `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`; it wins over the GitHub wording below. Step 4: push only when `<remote>` is set. Step 5: no `Refs #` line, and do not run `publish-evidence.sh`: after the `result.md` content, list the screenshots by their local paths under `### Screenshots` for the user to attach. Step 6: line 2 of the batch changes nothing and may be left out. Step 7: report the merge request file (the URL), its `OPEN_MR=` link when one was printed, the title and the target branch, and tell the user to open the merge request on their host and merge it (or, without a remote, to run the `git merge` command in the file).

## 1. Keep the UI evidence local

Never commit anything from `<docs_dir>/<feature-name>/evidence/`, not even `result.md`. The gate reads `result.md` from the worktree, and step 5 puts its content and the screenshots in the PR description.

## 2. Gate

Run `check-pr-ready.sh <task-id> <plan path>` from the worktree. If it fails, show its messages and stop. Never edit the gates, bypass them or fix the cause here.

## 3. Idempotency

Call the `workez:github-ops` agent with `find-pr <head branch>`. If a pull request already exists for the branch, in any state, report its number, URL and state, and stop. Do not push again, do not create a second one and do not rewrite its body.

## 4. Push the task branch

Push only the task branch: `git push -u <remote> <Branch>`, run from the worktree. Never force, and never push the integration branch, `<base>` or any `branches.protected` branch. If the remote branch has history this branch does not contain, stop and report it.

## 5. Body

1. Invoke the `pr-description` skill on the task diff `<PR target>...HEAD`, run from the worktree. Override: the base is the task's `PR target`, not `<base>`; skip its step 4 (no merge request, no push); use none of its title. Use its body as the main body, including its closing line. If the project has no `pr-description` skill, write a short Summary and Changes section from the diff instead.
2. Append a `## Workflow details` section with only what `pr-description` does not already say. Skip any part it covers; never repeat it.
   - `Refs #<sub-issue number>` (from `Issue:`). No closing keyword such as Closes or Fixes.
   - The requirements the task covers, from `Covers:`.
   - The review summary from `<docs_dir>/<feature-name>/reviews/<task-id>.md`: the number of rounds, the final verdict, and the minor findings still open.
   - Only if the task has a `UI check:`: the content of its local `result.md` (its path and file list lines left out), then a `### Screenshots` section so the reviewer sees the UI without running it. Get it from `${CLAUDE_PLUGIN_ROOT}/scripts/publish-evidence.sh <task-id> <docs_dir>/<feature-name>/evidence/<task-id> <PR target>`, run from the worktree: it pushes the screenshots to the never-merged branch `<PR target>-evidence` and prints one Markdown image per screenshot, linked by commit so the images never change. Paste its output as is. List the other local evidence files (logs, traces) by name only.
   - As the very last line: `Created by workflow; review and merge by a human.`
3. Write the whole body to `<project root>/.claude/workflow/<feature-name>/pr-<task-id>.md`.

## 6. Create the PR

Call the `workez:github-ops` agent once, with one batch (step 3 found no PR, so the PR is new). Never create it by any other route.

```
batch:
1. create-pr <Branch> <PR target> "<PR title>" <project root>/.claude/workflow/<feature-name>/pr-<task-id>.md
2. swap-label <Issue number> status:in-progress status:in-review if $1.new
```

The title is the `PR title:` field exactly (built by `workez:write-plan` from `naming.task_pr_title` in `.claude/workflow.json`). Post no comment to start a review: the repository's CI reviews a new task PR by itself when it is opened (see `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`), and `github.review_trigger` is only for the user to ask for another review by hand. The review's findings come back through `get-pr-feedback` (authors in `github.feedback_authors`) like any review. An existing PR gets no line 2.

## 7. Report

The PR number and URL, and whether it was new. Do not merge, approve, review or close anything.
