---
name: design-feature
description: Phase 2 (Design) of the feature workflow. Turns an approved intent into an approved spec and updates the tracking issue. Run with the feature folder name.
model: opus
allowed-tools: Skill Read Glob Grep Write Edit AskUserQuestion Agent
---

# Design a feature (Phase 2)

Phase 2 of the feature workflow: approved intent, then an approved spec, then the issue updated. It chains existing skills and agents and adds no task breakdown and no code. Stop after the hand-off.

Argument: `<feature-name>`, the folder under `<docs_dir>`.

## 1. Check the input

Read `<docs_dir>/<feature-name>/intent.md`. If line 2 does not say `Status: approved.`, stop and tell the user to finish Phase 1 (`/plan-feature`). Never edit the intent.

Call the `workez:github-ops` agent with `find-issue <docs_dir>/<feature-name>/intent.md`. If it reports `not found`, stop and tell the user: the tracking issue is missing, so Phase 1 is not finished. Do not create one here.

If `<docs_dir>/<feature-name>/spec.md` exists, ask with `AskUserQuestion`: revise it or start over. Never overwrite it without that answer.

## 2. Core standards

Invoke `workez:project-context` with the intent path. Keep its list of standards files for steps 3 and 5.

## 3. Gather context

Read the standards files it returned, only the sections it named. Delegate scanning the code the feature touches to the `Explore` agent with `model: "haiku"`, and use only its conclusions.

## 4. Write the spec

Invoke `workez:write-spec` with this override: write to `<docs_dir>/<feature-name>/spec.md`, not to `intent/`. Everything else in that skill applies.

## 5. Self-review

Call the `workez:spec-reviewer` agent with the intent path, the spec path and the standards list. Fix every finding in the spec with `Edit`, blocker, major and minor alike, before the user sees it. When a finding needs a decision only the user or product owner can make, add it to Areas of concern with an owner instead. A finding labelled `Intent:` is not fixed in the spec; keep it for the user. Call the reviewer again after each round of fixes. Stop when it returns no findings, or after 3 rounds.

## 6. Approval

Show the user the spec path, its Open questions, and any findings still open after step 5 (`Intent:` findings, or findings left when the rounds ran out), saying which. Ask with `AskUserQuestion`: approve, or change something. On changes, edit the spec and run the reviewer again. Do not continue without a clear approval. Then set `Status: approved.` in place of the status on line 2 with `Edit`.

Commit the approved spec to the feature's integration branch: `${CLAUDE_PLUGIN_ROOT}/scripts/commit-feature-doc.sh <feature-name> <issue-number from step 1> spec.md`. It never pushes and leaves the current checkout untouched. If it fails, tell the user and carry on.

## 7. Hand off

Call the `workez:github-ops` agent once, with one batch:

```
batch:
1. comment <issue from step 1> "Spec approved: `<docs_dir>/<feature-name>/spec.md`"
2. swap-label <issue from step 1> phase:plan-done phase:design-done
```

## 8. Finish

Write `.claude/workflow/<feature-name>/state.json` (create the folder with `mkdir -p` if needed; use `Write`) with exactly this content, so the `Stop` hook starts `workez:write-plan`:

```json
{"feature": "<feature-name>", "phase": "design", "status": "done", "handed_off": false}
```

Report the spec path and the issue number and URL. Do not commit or push. The plan is started by the `Stop` hook (`next-phase.sh` of the workez plugin), not here.
