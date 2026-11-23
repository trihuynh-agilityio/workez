---
name: run-lane
description: One task's lane of `workez:build-feature` (and `workez:build-task`): implementer, review loop, UI check, PR, and, as a desktop sub session, the watch of its own PR through to the merge. Started only by those skills, never by the user directly. Arguments `<feature-name> <task-id> <lane> <runner>`, plus the plan path and project root.
model: sonnet
disable-model-invocation: true
allowed-tools: Read Write Edit Glob Grep Agent CronCreate CronList CronDelete Bash(git status*) Bash(git log*) Bash(git diff*) Bash(git rev-parse *) Bash(git push *) Bash(git fetch *) Bash(git ls-remote *) Bash(gh pr list *) Bash(gh pr view *) Bash(*/scripts/*)
---

# Run one task's lane

Carries ONE task from its plan to an open PR, and with runner `session` on to its merge. The orchestrator is `workez:build-feature` (or `workez:build-task`); it picks the task, the lane and the runner and owns `state.json`. This skill never writes `state.json`, never starts another session and never touches another task's worktree, branch or PR.

Arguments: `<feature-name> <task-id> <lane> <runner>`, with the plan path, the project root and the plugin root in the brief. `<lane>` is `A`, `B` or `solo`; `<runner>` is `agent` (a subagent that returns after the PR is ready) or `session` (a full desktop sub session that also creates the PR and watches it).

## Paths

- Plugin root: in a sub session, `${CLAUDE_PLUGIN_ROOT}` in this file and in the files it sends you to is the absolute plugin root given in the brief; write it out in full in every command and in the watch prompt.
- Settings: `<project root>/.claude/workflow.json`. Below, `<docs_dir>` is its `docs_dir`, `<remote>` is `github.remote`, `<base>` is the `BASE=` line of `${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh base`, and the commands are its `commands` (each runs in its `dir`). Every worktree comes from `worktree.sh create`, never from a hand-written `git worktree add`. The **project folder** of a worktree is the worktree root plus the project's path inside the repository (`git -C <project root> rev-parse --show-prefix`; empty when the project is the repository root).
- Plan path: the absolute `plan=` path from the brief (`plan.md`, or `plan-fix.md` for a fix task); pass it to every agent and gate. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/` (they find the project from the current folder, a worktree included; run from elsewhere, prefix `WF_PROJECT=<project root>`). Read the task's block in the plan: `Branch:`, `PR target:`, `PR title:`, `Issue:`, `Covers:`, `Verify:`, `UI check:`.
- Lane file: `<project root>/.claude/workflow/<feature-name>/lane-<task-id>.json`, written and read only with `${CLAUDE_PLUGIN_ROOT}/scripts/lane-result.sh` (`set <feature> <task> <field>=<string> | <field>:=<json> ...`, `get <feature> <task> [field]`).
- Notes: written only with `${CLAUDE_PLUGIN_ROOT}/scripts/note.sh <feature-name> "#<issue>" "<what>" ["<outcome>"]` (see "Notable issues" in `${CLAUDE_PLUGIN_ROOT}/skills/build-feature/SKILL.md`). Task labels: `status:in-progress` while the lane runs, `status:in-review` once the PR is open, `status:done` once merged, `status:blocked` when blocked or failed.
- Auto-merge: `jq -r '.auto_merge.task_prs // false' <project root>/.claude/workflow.json`. Below, "auto-merge on" means `true`.

With `"tracker": "local"`, follow "Local tracker" in `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`, as `workez:build-feature` does: no issue labels, a merge request file instead of a PR, and, when the user says a squash merge happened, `${CLAUDE_PLUGIN_ROOT}/scripts/mark-merged.sh <feature-name> <task-id>`.

## Lane and browser

The lane keeps the server, the ports and the evidence folder of its own letter: lane `A` uses `playwright-a` and `lanes.A` of `workflow.json`, lane `B` uses `playwright-b` and `lanes.B`, and `solo` uses lane `A`. A sub session starts its own browser servers, but they all share the project folder, their `--output-dir .claude/workflow/playwright-<x>` and the port blocks, so a lane never uses the other letter's.

## Pipeline

A lane cannot call `workez:review-task` or `workez:create-task-pr`: they are user-only skills that no model can invoke, even in a full session. Read their `SKILL.md` files and follow them step by step, calling the agents directly:

1. `workez:implementer`: worktree (`worktree.sh create <Branch> --from <PR target>`, whose preflight must pass; on `PREFLIGHT FAILED` stop as BLOCKED with its message and never `git reset` the worktree), Verify, then `check-task.sh`. Anything unclear or wrong in the spec or plan, and any deviation from it, is reported back and noted (`spec deviation: <what>` → `<what was done>`). A task that already has a worktree resumes from it (the same command resumes it and runs the preflight again): skip to the first step not yet done (commits exist: review; review PASS: UI check; and so on).
2. The `workez:review-task` loop with the `workez:code-reviewer` and the implementer's fix mode, at most 3 rounds, ending with a local, uncommitted PASS report that `check-review.sh` accepts; it writes its notes as `review-task` says.
3. `workez:ui-verifier`, only for a task with `UI check:`, with the task's lane. A FAIL goes back to the implementer, then to review again, at most 2 re-runs; note it (`UI check FAIL: <what>` → `fixed in <sha>` or `still failing, blocked`).
4. The `workez:create-task-pr` steps up to its step 5: `check-pr-ready.sh`, the existing-PR check (`gh pr list --repo <github.repo> --head <Branch> --state all`, read-only, before the push), push the task branch, the `pr-description` body plus the Workflow details section written to `pr-<task-id>.md`. Its step 6 is the PR creation below.

Each lane keeps its own worktree, its own ports (`lanes` in `workflow.json`), its own Playwright browser and its own evidence folder, so the two lanes run their UI checks at the same time.

A stop in the pipeline is `BLOCKED <reason>` (an unmet precondition, a failed preflight, a review or UI check still open after its budget) or `FAILED <reason>` (a gate or command that fails). An existing PR for the branch is `PR_EXISTS <url>`.

## Runner agent

A subagent has no `Agent` tool for `workez:github-ops`, and does not write the lane file (the orchestrator does). Run the Pipeline and return exactly one line and nothing else: `PR_READY <body file>`, `PR_EXISTS <url>`, `BLOCKED <reason>` or `FAILED <reason>`. The orchestrator creates the PR and sets the labels.

## Runner session

A full sub session: it has the `Agent` tool and `CronCreate`. Every step of the Pipeline that says "call the agent" is a direct call. In order:

1. **Start.** If the lane file already says `status` `merged`, report `LANE <task-id> MERGED PR #<n> <sha>` and end. Otherwise `lane-result.sh set <feature-name> <task-id> status=running runner=session lane=<lane> issue:=<n>` (keep the other fields of an existing file: a resume never clears `handled_feedback`, `fix_rounds`, `settled` or `session`). A task whose PR is already open (the existing-PR check, or `pr` in the lane file) saves it with `pr:=<n>` and skips to step 4; one already merged goes to step 6.
2. **Pipeline.** Run it. On BLOCKED or FAILED: call `workez:github-ops` once with `swap-label <issue> status:in-progress status:blocked`, write the note (`blocked: <reason>` → `blocked`), `lane-result.sh set <feature-name> <task-id> status=blocked reason=<reason>` (`status=failed` for FAILED), and end with one line: `LANE <task-id> BLOCKED <reason>` (or `FAILED`).
3. **PR.** Call `workez:github-ops` itself with the batch of `workez:create-task-pr` step 6: `create-pr <Branch> <PR target> "<PR title>" <project root>/.claude/workflow/<feature-name>/pr-<task-id>.md`, then `swap-label <issue> status:in-progress status:in-review if $1.new`. On `PR_EXISTS` reuse that PR and add no label line. Then `lane-result.sh set <feature-name> <task-id> status=pr_open pr:=<n>`.
4. **Watch.** Watch only this task's PR. Call `CronCreate` for every 10 minutes with this plain-text prompt (never a skill call, because a scheduled run cannot invoke a user-only skill): "Run ${CLAUDE_PLUGIN_ROOT}/scripts/gh-watch.sh <Branch>:<Issue> --handled <ids> --settled <prs>, where <ids> and <prs> are read now, on every run, with `${CLAUDE_PLUGIN_ROOT}/scripts/lane-result.sh get <feature-name> <task-id> handled_feedback` and `... settled` (JSON arrays, joined with commas; empty when missing). Exit 0: do nothing more, call no agent and reply with nothing. Otherwise read the STATE, FEEDBACK, CHECKS, CONFLICT and READY lines. MERGED: read ${CLAUDE_PLUGIN_ROOT}/skills/run-lane/SKILL.md and carry out its step 6 for <feature-name> <task-id>. CLOSED: call CronDelete <id>, call github-ops swap-label <issue> status:in-review status:blocked, write the note `PR #<n> closed without merge` → `blocked`, run lane-result.sh set <feature-name> <task-id> status=blocked reason='PR closed without merge' cron_id:=null, and end. FEEDBACK, CHECKS or CONFLICT on the OPEN PR: read ${CLAUDE_PLUGIN_ROOT}/skills/build-feature/SKILL.md and carry out its step 4b for task <task-id>, with feature name <feature-name> and plan path <plan path>, reading and writing handled_feedback and fix_rounds in the lane file with lane-result.sh instead of state.json (step 5 of ${CLAUDE_PLUGIN_ROOT}/skills/run-lane/SKILL.md)." With auto-merge on, add `--ready` to the `gh-watch.sh` command and append: "Last, for a READY <pr> <id> <sha> line: run ${CLAUDE_PLUGIN_ROOT}/scripts/merge-task-pr.sh <feature-name> <task-id> --sha <sha> --pr <pr> (local tracker: no --pr). MERGED: carry out step 6 of ${CLAUDE_PLUGIN_ROOT}/skills/run-lane/SKILL.md. WAIT: nothing. REFUSED: tell the user the reason in one line and add <id> to handled_feedback with lane-result.sh." Save the cron id with `lane-result.sh set <feature-name> <task-id> cron_id=<id>`. Say in one line that the PR is open and watched, and end the turn: the app wakes the main session, which waits.
5. **Step 4b in a lane.** Step 4b of `build-feature` reads and writes `state.tasks.<id>`; here the lane file takes its place. Read `handled_feedback` and `fix_rounds` with `lane-result.sh get`; write every handled id and the new round count with `lane-result.sh set <feature-name> <task-id> handled_feedback:=[...] fix_rounds:=<n>`. A lane never writes `state.json`, and uses its own lane's worktree, browser and evidence.
6. **Merged.** Reached from the watch, from `merge-task-pr.sh` printing `MERGED`, or from a resume that finds the PR merged. In order:
   - `CronDelete` the lane file's `cron_id`.
   - The merge sha: the `MERGED` line of `merge-task-pr.sh`, else `gh pr view <pr> --repo <github.repo> --json mergeCommit -q .mergeCommit.oid` (local tracker: the integration branch tip).
   - One `workez:github-ops` batch: `swap-label <issue> status:in-review status:done`, `close-issue <issue>` (`already closed` is fine).
   - `${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-feature.sh <feature-name> --task <task-id>`; report any `KEPT` line.
   - `lane-result.sh set <feature-name> <task-id> status=merged merge_sha=<sha> settled:=[<pr>] cron_id:=null notes:=<JSON array of the note lines this lane wrote for its issue, read from notes.md>`.
   - End with one line: `LANE <task-id> MERGED PR #<n> <sha>`. The app then wakes the main session, which starts the next wave.

## Rules

- Never write `state.json`, never start other sessions, never touch another task's worktree, branch or PR.
- Never merge, except through `merge-task-pr.sh` with auto-merge on; never push `<base>` or any `branches.protected` branch; never force push; never use `gh pr merge`, `git merge` or `gh pr review` yourself.
- The 3-round review budget and the 2 fix rounds per PR stay; an item left over goes to the user, not to another round.
- Write the lane file only with `lane-result.sh`, and notes only with `note.sh`.
