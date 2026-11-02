---
name: write-plan
description: Use when asked to write, draft or start an implementation plan for a change that already has an intent and a spec, before any code exists.
model: opus
allowed-tools: Bash(ls *) Read Write Glob Grep Agent
---

# Write a plan

A plan turns an approved spec into small tasks grouped in waves that the build phase can run in parallel, with the proof for each requirement and the rules the build phase must follow. It only writes the plan; it builds nothing. It is short and concrete. Every requirement in the spec is traceable to a task and a test.

## 1. Collect the inputs

- **Intent and spec**: the `intent.md` and `spec.md` the plan answers. Take them from the request (a feature folder name such as `saved-searches` means `<docs_dir>/<feature-name>/`). If the request names none, run `ls <docs_dir>/` and ask which folder. If the folder has no `spec.md`, stop and offer to run `workez:write-spec` first.
- **Project guidance**: read `CLAUDE.md` and any design spec it points to, for the stack, rules and commands. Read `.claude/workflow.json` for the workflow settings: `commands` (test, lint, build), `task_limits`, `naming`, `lanes` and `app_url` (the UI check URL of each lane). The tasks also need how to run one test file or test, from `CLAUDE.md` or the test command; if that is missing, stop and ask the user. Do not guess. The plan never copies the workflow rules, the settings or the repo name: those live in `workflow.json`, the skills and `workez:github-ops`.
- **Feature issue number**: call the `workez:github-ops` agent with `find-issue <docs_dir>/<feature-name>/intent.md` and take the number from its report. The number names the integration branch only; it is never written into the intent or the spec. If it reports `not found`, stop and tell the user to finish Phase 1 (`/plan-feature`).
- **The code**: use Glob and Grep to find the real files, routes, components and helpers the spec touches. Name only files you found, or new files marked as new. Never guess a path.

Read both documents whole before writing. If the spec's status is still `draft`, tell the user and carry on only if they say so. Requirements are the spec's `R1.`, `R2.` ids; they stand in for acceptance criteria everywhere below.

## 2. Name and place the file

```
<docs_dir>/<feature-name>/plan.md
```

- It sits in the same folder as the intent and spec.
- If `plan.md` already exists, read it and offer to update it. Never overwrite it.

## 3. File content

The layout is fixed. Lines 1 to 3 are exactly these, then the headings below in this order. Do not rename, reorder, add or drop a heading.

```markdown
# Plan: <feature name>
Status: draft.
From: [intent.md](intent.md) and [spec.md](spec.md).

## Issues with the spec

## Wave 0
(tasks)

## Wave 1
(tasks, then more waves as needed)

## Wave <last>
(the integration task)

## Risks

## Checks
```

- Line 1 is `# Plan: ` plus the feature name in sentence case, as in the intent.
- Line 2 is always `Status: draft.` when the file is first written.
- Each task is a heading `## T<n>: <title>  [ ]` placed under its wave heading, with the fields in section 4. The title becomes the description of the task's commit and PR title, so when `workflow.json` has `conventions` write it as Conventional Commits wants a description: imperative, starting lowercase, no trailing period, short enough that `<type>(<scope>): <title>` stays within `conventions.subject_max_length` (for example `add the save search button`).
- `## Checks` has four parts, in this order: `### AC coverage`, `### Parallel safety`, `### Size`, `### Test plan`.

## 4. Waves and tasks

### Waves

- Tasks are grouped in `## Wave <n>` sections. Tasks in one wave run in parallel. A wave starts only after the previous wave's PRs are merged.
- At most 2 tasks per wave, one per lane (`A` or `B`). A single-task wave is fine (lane `solo`).
- **Wave 0** is the foundation and runs alone: shared types, interfaces, schemas, config, shared utilities, shared test fixtures, mocks and helpers, and the acceptance tests.
- The **final wave** is integration and runs alone: wire the parts together and run the full test suite. If the suite passes with nothing to change, the integration task makes no commit and no task PR: it is done with the suite result noted in the final PR description. Its Branch, PR target and PR title apply only when fixes are needed, and the task says so.
- **File ownership (hard rule)**: two tasks in the same wave never create or modify the same file. If they must, put them in different waves or merge them.
- Prefer balanced lanes, but correctness beats parallelism.

### Task size (hard rule)

- One task is one PR with fewer than `task_limits.max_lines` changed lines (added and removed, tests included) and fewer than `task_limits.max_files` files. Split a task before writing the plan if it would exceed either limit.
- If the plan needs more than about 10 tasks, stop and tell the user the feature may be too big and should be split. Do not write a huge plan.

### Task fields

Every task has, in this order:

- **Lane**: `A`, `B` or `solo`.
- **Goal**: one or two lines.
- **Files**: the precise and complete list of files created (`(new)`) or modified, tests included.
- **Size**: estimated lines and file count, for example `~180 lines, 4 files`.
- **Covers**: the requirement ids (`R1`, `R2`).
- **Depends on**: task ids from earlier waves only, or `none`.
- **Tests**: test files and key cases, including the spec's boundary values.
- **Verify**: the exact command that runs only this task's tests, built from `commands.test` in `.claude/workflow.json` (and how to run one file, from `CLAUDE.md`).
- **Done when**: concrete, checkable criteria.
- **Type** (only when `workflow.json` has `conventions`): the Conventional Commits type of the change, one of `conventions.commit_types`: `feat` for new behaviour, `fix` for a bug fix, `test` for tests only (the acceptance tests of wave 0), `refactor`, `docs`, `build`, `ci`, `chore`, ... It names the task's branch and its commits.
- **Scope** (optional, same condition): a lowercase noun for the part of the code, such as `api` or `search-form`, or `none`.
- **Slug**: `<task-slug>`: lowercase kebab-case, ASCII, 2 to 5 words, unique within the feature (different from every other task slug and from the feature slug).
- **Issue**: `pending`. Sub-issues are created after the plan is approved, so the number does not exist yet. Never guess or reserve one.
- **Branch**: `naming.task_branch` from `.claude/workflow.json`, in backticks, with the task slug for `{task_slug}`, the Type for `{task_type}`, and `<sub-issue>` for `{task_issue}` until the sub-issue exists.
- **PR target**: `naming.integration_branch`, with the real feature issue number and the feature slug.
- **PR title**: `naming.task_pr_title`, with the task title, the Type for `{task_type}`, `(<scope>)` for `{task_scope}` (nothing when the scope is `none`) and the same `<sub-issue>` placeholder. The `T<n>` id never goes into it.
- **UI check**: only for tasks that change user-facing UI (see below).

### Testing

- Every task writes its own unit tests.
- Wave 0 writes the acceptance tests: one or more per requirement, derived from the spec's requirements and the boundary values they name. They are expected to fail until the feature is built. Implementer tasks never edit acceptance tests.
- Mark any test that cannot run in parallel (shared port, database or temp file). It runs only in the integration wave, which runs the full suite, acceptance tests included.
- For critical UI flows, add a Playwright test to that task's Tests, but only if the project already has Playwright. If it does not, do not add it to the plan; record it under Risks as a decision for the user.

### UI check (UI tasks only)

- **Route/URL**: the lane's `app_url` from `.claude/workflow.json` (filled with that lane's ports) plus the path.
- **Scenarios**: each is the user's actions and the expected visible result.
- Every scenario must be reproducible as written: name the exact setup and data. For a failure, slow or offline state, say how to cause it in the browser (for example a console override of `fetch` that never answers for one URL), never a step like "stop the server and bring it back".
- **Evidence**: a screenshot per scenario, a trace or video for multi-step flows, and the browser console log with failed requests.
- UI checks run with Playwright MCP inside the task's own lane, right after the implementer and before the task's PR is created. Each lane has its own browser and its own dev-server ports, set in `lanes` of `workflow.json`.
- Evidence goes in `<docs_dir>/<feature-name>/evidence/<task-id>/` with a `result.md` (each scenario pass or fail, observed against expected, errors, branch and commit). Nothing in the evidence folder is committed. The content of `result.md` and the screenshots (published by `publish-evidence.sh`) go into the PR description.

If the task has no UI change, leave the UI check out.

## 5. Fill the other sections

- **Issues with the spec**: every place the spec is wrong, missing or contradicts the code or `CLAUDE.md`, each with what the plan does about it and `Owner: <who decides>.`. Never edit the spec, and never guess around a problem. If there are none, write `None.`.
- **Risks**: bullets, each saying what could go wrong and what the plan does about it. Draw from the spec's areas of concern, naming each by number. Mark any task that must wait for an owner's answer.
- **Checks**: fill the four parts:
  - `### AC coverage`: every requirement id, with the task ids that cover it. No requirement is left uncovered.
  - `### Parallel safety`: for each wave, the files touched by each lane, confirming no overlap.
  - `### Size`: every task with its estimated lines and files, confirming each is under the `task_limits`.
  - `### Test plan`: a table `Requirement | Acceptance test file | Task that writes it | Tasks that make it pass`.

## 6. Rules

- Follow the spec. Do not add scope, and keep anything it puts out of scope out.
- Never invent a file, command, requirement id or fact. A named risk beats a confident guess.
- If the spec and the code or `CLAUDE.md` conflict, do not pick one silently. State both under Issues with the spec.
- Ask the user only when something essential is missing or ambiguous and cannot be read from the inputs or the code. Otherwise choose the obvious option and record it.
- No code in the plan. Never edit `intent.md` or `spec.md`.

## 7. Finish

Tell the user the path of the file, the number of tasks and waves, and which issues or risks need a decision first, with the owner of each. Do not commit; leave that to the user's branch workflow.

Then write `.claude/workflow/<feature-name>/state.json` (create the folder with `mkdir -p` if needed; use `Write`) with exactly this content, so the `Stop` hook starts `workez:create-task-issues`, which asks the user to approve the plan before it creates anything:

```json
{"feature": "<feature-name>", "phase": "write-plan", "status": "done", "handed_off": false}
```
