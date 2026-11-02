---
name: create-task-issues
description: Phase 3 (Build) step, started by the Stop hook right after write-plan (or run by hand when the plan exists). Turns each task of an approved plan into a GitHub sub-issue of the feature issue and writes the numbers back into the plan. Run with the feature folder name.
model: sonnet
allowed-tools: Read Edit Write Glob Agent AskUserQuestion
---

# Create the task issues

One sub-issue per task of `<docs_dir>/<feature-name>/plan.md`, linked to the feature issue, then the numbers written back into the plan. It builds nothing: no push and no implementation; its only commit is the approved plan on the integration branch (step 4).

Argument: `<feature-name>`, the folder under `<docs_dir>`.

## 1. Check the plan

Read `<docs_dir>/<feature-name>/plan.md`.

- If line 2 is `Status: approved.`, carry on.
- If it is `Status: draft.`, ask with `AskUserQuestion`: approve the plan, or change something. On changes, stop and let the user edit. On approval, set line 2 to `Status: approved.` with `Edit`.
- Never edit `intent.md` or `spec.md`.

## 2. Find the feature issue

Call the `workez:github-ops` agent with `find-issue <docs_dir>/<feature-name>/intent.md`. Keep its number and its current labels. If it reports `not found`, stop and tell the user: the feature issue is missing, so Phase 1 is not finished. Do not create one.

## 3. Create the sub-issues and update the feature issue

Call `workez:github-ops` once, with one batch. First one `create-sub-issue` line per task `## T<n>: <title>`, in plan order:

- parent: the feature issue number,
- title: `naming.task_issue_title` from `.claude/workflow.json`, with `{task_title}` = the heading text after `T<n>: `, without the `[ ]` (never the task id),
- task id: `T<n>`, which `workez:github-ops` uses only as the plan reference and the duplicate key, never in the title,
- task fields: its Goal, Covers, wave, Lane, Depends on (as `#$<k>.number` of those tasks' earlier batch lines; `none` if empty), and the plan path `<docs_dir>/<feature-name>/plan.md` (`workez:github-ops` builds the body from them in the shared issue body format),
- labels: `task`.

Then two more lines:

- `comment` on the feature issue with the task list, one line per task: `#$<k>.number`, title, wave and lane, where `<k>` is that task's batch line. Write it to `<project root>/.claude/workflow/<feature-name>/task-list.md` first and pass `--body-file`.
- `swap-label` on the feature issue: its current phase label from step 2 (`phase:design-done`, or `phase:plan-done` if that is the one present) to `phase:tasks-ready`.

Do not ask questions here. A task whose sub-issue already exists is returned as `already existed`; keep its number. If the batch stops at an ERROR, keep the numbers of the OK lines, report the error, and run the same batch again once the cause is fixed: lines that already ran come back as `already existed`.

## 4. Write the numbers into the plan

For each task that now has a number, `Edit` plan.md:

- `Issue: pending` becomes `Issue: #<n>`.
- `Branch:` has `<sub-issue>` replaced by `<n>` (the plan wrote it from `naming.task_branch`). Keep the backticks and any trailing note such as `(only if fixes are needed)`.
- `PR title:` has `<sub-issue>` replaced by `<n>`.

This is the only edit allowed on an approved plan. Change nothing else in it.

Then commit the approved plan, numbers included, to the feature's integration branch: `${CLAUDE_PLUGIN_ROOT}/scripts/commit-feature-doc.sh <feature-name> <feature issue number> plan.md`. It never pushes and leaves the current checkout untouched. If it fails, tell the user and carry on.

## 5. Hand off

Write `.claude/workflow/<feature-name>/state.json` (create the folder with `mkdir -p` if needed; use `Write`) with exactly this content, so the `Stop` hook starts `workez:build-feature` (the plan was approved in step 1, so no further command is needed):

```json
{"feature": "<feature-name>", "phase": "tasks", "status": "done", "handed_off": false}
```

Report a table: task, issue number, branch name, and any failures. Do not push or start implementation yourself: the `Stop` hook starts `workez:build-feature`.
