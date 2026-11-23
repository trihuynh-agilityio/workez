---
name: run-lane
description: One task's lane of `workez:build-feature` and `workez:build-task`: implementer, review loop, UI check and the PR body, run by a lane subagent. Started only by those skills, never by the user directly. Arguments `<feature-name> <task-id> <lane>`, plus the plan path and project root.
model: sonnet
disable-model-invocation: true
allowed-tools: Read Write Edit Glob Grep Agent Bash(git status*) Bash(git log*) Bash(git diff*) Bash(git rev-parse *) Bash(git push *) Bash(git fetch *) Bash(git ls-remote *) Bash(gh pr list *) Bash(*/scripts/*)
---

# Run one task's lane

Carries ONE task from its plan to a pull request body ready to be created. The orchestrator is `workez:build-feature` (or `workez:build-task`); it picks the task and the lane, creates the PR, sets the labels and owns `state.json`. This skill never writes `state.json` and never touches another task's worktree, branch or PR.

Arguments: `<feature-name> <task-id> <lane>`, with the plan path and the project root in the brief. `<lane>` is `A`, `B` or `solo`.

## Paths

- Settings: `<project root>/.claude/workflow.json`. Below, `<docs_dir>` is its `docs_dir`, `<remote>` is `github.remote`, `<base>` is the `BASE=` line of `${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh base`, and the commands are its `commands` (each runs in its `dir`). Every worktree comes from `worktree.sh create`, never from a hand-written `git worktree add`. The **project folder** of a worktree is the worktree root plus the project's path inside the repository (`git -C <project root> rev-parse --show-prefix`; empty when the project is the repository root).
- Plan path: the absolute `plan=` path from the brief (`plan.md`, or `plan-fix.md` for a fix task); pass it to every agent and gate. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/` (they find the project from the current folder, a worktree included; run from elsewhere, prefix `WF_PROJECT=<project root>`). Read the task's block in the plan: `Branch:`, `PR target:`, `PR title:`, `Issue:`, `Covers:`, `Verify:`, `UI check:`.
- Notes: written only with `${CLAUDE_PLUGIN_ROOT}/scripts/note.sh <feature-name> "#<issue>" "<what>" ["<outcome>"]` (see "Notable issues" in `${CLAUDE_PLUGIN_ROOT}/skills/build-feature/SKILL.md`). The task labels are set by the orchestrator, never by the lane.

With `"tracker": "local"`, follow "Local tracker" in `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`, as `workez:build-feature` does: no issue labels and a merge request file instead of a PR.

## Lane and browser

The lane keeps the server, the ports and the evidence folder of its own letter: lane `A` uses `playwright-a` and `lanes.A` of `workflow.json`, lane `B` uses `playwright-b` and `lanes.B`, and `solo` uses lane `A`, so a lane never uses the other letter's.

## Pipeline

A lane cannot call `workez:review-task` or `workez:create-task-pr`: they are user-only skills that no model can invoke. Read their `SKILL.md` files and follow them step by step, calling the agents directly:

1. `workez:implementer`: worktree (`worktree.sh create <Branch> --from <PR target>`, whose preflight must pass; on `PREFLIGHT FAILED` return `BLOCKED <its message>` and never `git reset` the worktree), Verify, then `check-task.sh`. Anything unclear or wrong in the spec or plan, and any deviation from it, is reported back and noted (`spec deviation: <what>` → `<what was done>`). A task that already has a worktree resumes from it (the same command resumes it and runs the preflight again): skip to the first step not yet done (commits exist: review; review PASS: UI check; and so on).
2. The `workez:review-task` loop with the `workez:code-reviewer` and the implementer's fix mode, at most 3 rounds, ending with a local, uncommitted PASS report that `check-review.sh` accepts; it writes its notes as `review-task` says.
3. `workez:ui-verifier`, only for a task with `UI check:`, with the task's lane. A FAIL goes back to the implementer, then to review again, at most 2 re-runs; note it (`UI check FAIL: <what>` → `fixed in <sha>` or `still failing, blocked`).
4. The `workez:create-task-pr` steps up to its step 5: `check-pr-ready.sh`, the existing-PR check (`gh pr list --repo <github.repo> --head <Branch> --state all`, read-only, before the push), push the task branch, the `pr-description` body plus the Workflow details section written to `pr-<task-id>.md`. Its step 6 is the orchestrator's.

Each lane keeps its own worktree, its own ports (`lanes` in `workflow.json`), its own Playwright browser and its own evidence folder, so the two lanes run their UI checks at the same time.

## Return

A subagent has no `Agent` tool for `workez:github-ops`. Return exactly one line and nothing else: `PR_READY <body file>`, `PR_EXISTS <url>`, `BLOCKED <reason>` or `FAILED <reason>`. `BLOCKED` is an unmet precondition, a failed preflight, or a review or UI check still open after its budget; `FAILED` is a gate or command that fails; an existing PR for the branch is `PR_EXISTS`.

## Rules

- Never write `state.json`, never touch another task's worktree, branch or PR.
- Never merge; never push `<base>` or any `branches.protected` branch; never force push.
- The 3-round review budget and the 2 UI re-runs stay; an item left over goes to the user, not to another round.
