---
name: plan-feature
description: Use when asked to start a new feature, run Phase 1 (Plan) of the automation workflow, or turn a rough idea into an approved intent and a tracking GitHub Issue.
allowed-tools: Skill Read Glob Bash(git config *) Bash(date *) Bash(ls *) Bash(mkdir *) Write AskUserQuestion Agent
---

# Plan a feature (Phase 1)

Phase 1 of the feature workflow: idea, then intent, then a tracked issue. It chains existing skills and adds no design, spec, plan or code. Stop after the issue.


## Local tracker

With `"tracker": "local"` in `.claude/workflow.json`, follow "Local tracker" in `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`; it wins over the GitHub wording below. The feature issue number that `create-issue` returns is the feature folder name; pass it as the issue number to `commit-feature-doc.sh`. Its URL is `-`.

## 1. Grill the idea

Invoke the `grill-me` skill (the `grilling` skill of the `mattpocock-skills` plugin) on the user's idea. Ask the questions as `AskUserQuestion` pickers, one round at a time, with your recommended answer first. Read `README.md` and `CLAUDE.md` first so no question asks what the repo already answers. Stop when the user confirms a shared understanding.

## 2. Write the intent

Invoke `workez:write-intent` with this override: write to `<docs_dir>/<feature-name>/intent.md` (kebab-case name, 2–5 words, no date prefix), not to `intent/`. Everything else in that skill applies. Team and author follow its rules.

Before writing, check `.claude/workflow/<feature-name>/state.json`. If it exists, that feature is already in the workflow: show its phase and status and ask with `AskUserQuestion` whether to start it over (the state is replaced) or stop. Other features' states are never touched; several features can be planned while another one is in review.

## 3. Get approval

Show the user the path and the open questions. Ask with `AskUserQuestion`: approve, or change something. On changes, edit the intent and ask again. Do not continue without a clear approval, and set `Status: approved.` on line 2 of the intent once it is given.

## 4. Create the tracking issue

The issue tracks the feature as a TODO. `intent.md` is the source of truth, so the issue only points to it.

Hand this step to the `workez:github-ops` agent, which owns the repo, title, body and label. Do not rebuild them here.

- The approval in step 3 covers this step: create the issue without asking again.
- Call the Agent tool with `subagent_type: "github-ops"` and the prompt `create-issue <docs_dir>/<feature-name>/intent.md`.
- The issue leaves Phase 1 labeled `feature` and `phase:plan-done`; Phase 2 starts from that label.
- Take the issue URL from its report. If it reports the intent is not approved or the create failed, tell the user and stop.

## 5. Commit the intent to the feature branch

The approved intent lands on the feature's integration branch (`naming.integration_branch` in `.claude/workflow.json`), the same branch `workez:write-plan` names as every task's `PR target:`. Run `${CLAUDE_PLUGIN_ROOT}/scripts/commit-feature-doc.sh <feature-name> <issue-number> intent.md`. It creates the branch from the freshly fetched base branch (`branches.base`) if missing and commits through a temporary worktree, so the current checkout and its branch stay untouched. Keep its `BRANCH=` and `COMMIT=` lines for the report.

It never pushes: `workez:build-feature` pushes the integration branch once, before the first task PR. If it fails, tell the user and continue to step 6.

## 6. Finish

Write `.claude/workflow/<feature-name>/state.json` (create the folder with `mkdir -p` if needed) with exactly this content, so the `Stop` hook starts Phase 2:

```json
{"feature": "<feature-name>", "phase": "plan", "status": "done", "handed_off": false}
```

Then report the intent path, the issue URL and the commit on the feature branch. Do not push. Phase 2 is started by the `Stop` hook (`next-phase.sh` of the workez plugin), not here.
