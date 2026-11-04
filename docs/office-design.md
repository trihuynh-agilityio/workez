# Office board: design

Status: draft, for review. No code yet.

A local, read-only 2D board that shows where the workez workflow stands: each workflow step is a column, each feature and task is a card that moves between columns. At a glance it answers which step each task is in, who is working on it, and where things are stuck or waiting on you. `/workez:office` opens it. A 3D office view may come later, so the event layer knows nothing about the UI.

Constraints:

- Hooks are silent (no stdout, zero extra tokens), fast, and never break the workflow.
- Everything runs locally. The board never calls a model.

## 1. The workflow today

| Step | Skill (orchestrator) | Agents it calls | Waits on you |
|---|---|---|---|
| 1 Intent | `plan-feature` (grilling, `write-intent`) | `github-ops` (Haiku): the feature issue | approve the intent |
| 2 Spec | `design-feature` (`write-spec`, `project-context`) | `spec-reviewer` (Opus), in a loop | approve the spec |
| 2b Plan | `write-plan` | none | none |
| 3a Issues | `create-task-issues` | `github-ops` | approve the plan |
| 3b Build | `build-feature` (or `build-task` for one change) | per wave at most two lane subagents (Sonnet, lanes A and B). Each lane runs `implementer`, `check-task.sh`, `code-reviewer` (Opus, at most 3 rounds), `ui-verifier` on its lane's Playwright, then pushes and writes the PR body. The orchestrator calls `github-ops` once per batch. A cron watch then runs the step 4b fixes (`implementer`, `code-reviewer`, `ui-verifier`). | merge each wave's PRs (`waiting_review`); `blocked` |
| 4 Verify | `verify-feature` | a Haiku checks agent, `e2e-verifier` (lane A), `code-reviewer`, `github-ops` | merge the final PR (`waiting_merge`), or approve `plan-fix.md` (`failed`) |

Phases hand off through `.claude/workflow/<feature>/state.json` and the `next-phase.sh` Stop hook. `scripts/status.sh` already turns a state into "who acts next".

State.json is written only at the **end** of a phase. While `design-feature` runs, the state still says `plan / done / handed_off: true`. The state alone cannot tell the current step, so the board also needs live events.

## 2. Layers

1. **Capture**: hooks append facts to JSONL files. They know nothing about columns.
2. **Model**: a pure reducer turns events, state.json and plan.md into a board snapshot.
3. **View**: a local server sends the snapshot and a live stream. The 2D board reads them now; a 3D view can read the same two endpoints later.

## 3. Capture: hooks

One new script, `hooks/office-event.sh`, registered in `hooks/hooks.json` next to the existing hooks. It does not change them.

| Hook | Matcher | Meaning |
|---|---|---|
| `PreToolUse` | `Skill` | a step starts (`tool_input.skill` such as `workez:design-feature`; its args name the feature) |
| `PreToolUse`, `PostToolUse` | `Agent\|Task` | an agent is launched, or returns. The prompt holds the plan path (the feature) and `T<n>` (the task). A lane returns `PR_READY`, `PR_EXISTS`, `BLOCKED` or `FAILED`. |
| `SubagentStart`, `SubagentStop` | | who is working (`agent_id`, `agent_type`) |
| `PreToolUse`, `PostToolUse` | `AskUserQuestion\|ExitPlanMode` | waiting on you, then answered |
| `Notification` | `permission_prompt\|elicitation_dialog\|idle_prompt` | waiting on you |
| `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd` | | you answered; the session went idle; it started or ended |

There is no `*` matcher on every tool call. Liveness ("is this agent still doing something?") comes from the server checking the agent transcript's modification time, which costs the hooks nothing.

### Detecting the current step

- **Feature phase**: the latest `workez:*` Skill event for that feature. Without one (after a restart, or a missed event), the state.json phase and status, mapped with the same table as `next_step` in `status.sh`.
- **Task step inside a lane**: the agent type (`implementer` is Implement, `code-reviewer` is Review, `ui-verifier` is UI check). PR open is "the lane returned `PR_READY` or `PR_EXISTS`". Merged and closed come from `tasks.T<n>.status` in state.json.
- **Which task an agent belongs to**, in order:
  1. `T<n>` and the plan path in the Agent prompt. Every workez agent gets both.
  2. Matching a `SubagentStart` to the pending launch of the same `agent_type`, first in, first out.
  3. The `cwd` worktree, mapped to the plan task whose branch it is.

### Silent, fast, safe

- The whole body runs in `{ ...; } >/dev/null 2>&1` and the script always exits 0. Exit 2 on `PreToolUse` would block the tool, and stdout on `UserPromptSubmit` or `SessionStart` is added to the model's context.
- No `set -e`. A 3 second timeout, and `async: true` where Claude Code supports it.
- One `jq -c` call builds the line; one append writes it.
- The project is found from `$CLAUDE_PROJECT_DIR/.claude/workflow.json` first, which skips the git calls of `config.sh`. `hook-env.sh` is the fallback.
- On by default, like `notify`. The personal key `office: false` in `workflow.local.json`, or `WF_OFFICE=off`, turns it off.

## 4. Transport: JSONL, then SSE

Hooks only append to a file. The server tails it and pushes to the browser with Server-Sent Events.

- Writing a file works when the server is down and adds no network wait to a hook. Replaying the files rebuilds the board after a restart, and recorded files serve as test fixtures.
- A local WebSocket would make each hook a network client: slower, and events are lost when nothing listens. The browser only receives, so SSE (`EventSource`, which reconnects by itself) is enough.
- Files: `.claude/workflow/office/events-<session>.jsonl` (the folder is already git-ignored). Lanes of one session append to the same file; lines under 4 KB written with `O_APPEND` do not interleave. The server deletes files older than 7 days; `cleanup-feature.sh` may drop a feature's events.

Event schema, version 1. Facts only:

```json
{"v": 1, "ts": "2026-11-04T09:12:03.123Z", "hook": "SubagentStart", "session": "…", "agent_id": "…", "agent_type": "workez:implementer", "skill": null, "feature": "login", "task": "T2", "detail": {}}
```

## 5. Model, server and UI

- `office/model.js`: a pure reducer from events, state.json and plan.md to a snapshot: `{columns, features: [{name, kind, phase, step, column, status, reason, gate, since, agent, quiet, tasks: [...]}], waiting}`; `gate` is true when the card waits at a workflow gate from state.json (approve the plan, merge a PR, approve plan-fix.md), not at a question or a permission prompt. `office/load.js` reads the files for it; `node office/snapshot.js` prints the board as text (`--json` for the snapshot). Tested in Node (`office/test/`) and end to end with the real hook (`tests/test-office-model.sh`).
- `office/server.js`: Node `http` and `fs` only, no npm dependencies (Node 18 is already required for Playwright). `GET /api/health`, `GET /api/snapshot`, `GET /api/stream` (SSE) and the static UI. Binds to 127.0.0.1, checks the `Host` header, read-only.
- `office/ui/`: `index.html`, `app.js`, `style.css`. Vanilla JS, no build step, no CDN.

### Step to column config

Two levels, so columns can be regrouped without touching detection. The default is `office/board.json` in the plugin; a project may override it in `.claude/office.json` (steps merge by id; `columns`, when given, replace the list). Not under `office` in `workflow.json`: that key is the personal on/off switch.

```json
{
  "steps": {
    "intent":    {"skills": ["workez:plan-feature", "workez:write-intent"]},
    "spec":      {"skills": ["workez:design-feature", "workez:write-spec"], "agents": ["workez:spec-reviewer"]},
    "implement": {"agents": ["workez:implementer"]},
    "review":    {"agents": ["workez:code-reviewer"]},
    "ui_check":  {"agents": ["workez:ui-verifier"]}
  },
  "columns": [
    {"title": "Intent", "steps": ["intent"]},
    {"title": "Spec", "steps": ["spec"]},
    {"title": "Build", "steps": ["implement", "review", "ui_check"]},
    {"title": "In review", "steps": ["pr_open"]}
  ],
  "quiet_after_min": 10
}
```

Default columns: Intent, Spec, Plan, Issues, Implement, Review, UI check, PR open, Verify, Done. Each feature is a row (swimlane).

## 6. Card status and time in step

| Status | Set by | Cleared by |
|---|---|---|
| working: the agent as a badge, such as "implementer · sonnet" | `SubagentStart`, `PreToolUse` of a Skill | `SubagentStop`, `Stop` |
| waiting on you: pinned to the top of its row, with the reason ("approve spec", "merge PR #31", "permission: Bash") | `AskUserQuestion`, `ExitPlanMode`, `Notification`; state `waiting_review`, `waiting_merge`, `failed`; `write-plan / done / handed_off: true` | the question's `PostToolUse`, `UserPromptSubmit`, a state change |
| done | task `done` or merged in state.json; phase `done` | |
| error, with the reason | a lane returns `BLOCKED` or `FAILED`; state `blocked` or `failed` | the next start event |
| quiet: a mark on a working card | no event and no transcript write for `quiet_after_min` | any activity |

Time in step is now minus `since`, the time of the event that moved the card into its column. Replaying the files keeps it across restarts. A card also shows the review round, the fix rounds and the PR number from state.json. `github-ops` calls flash on the card instead of getting cards of their own.

## 7. `/workez:office`

`scripts/office.sh [--no-open | stop]`:

1. Finds the project and reads `.claude/workflow/office/server.json` (`pid`, `port`).
2. If `GET /api/health` answers, reuses that server. Otherwise starts `node office/server.js` detached, on 127.0.0.1 and a free port, and waits up to 3 seconds for it to be healthy.
3. Opens the URL (`open`, or `xdg-open` on Linux) and prints it.

The server exits by itself after 30 minutes with no browser connected and no new event. `skills/office/SKILL.md` allows only `Bash(*/scripts/office.sh*)`: a slash command always costs one small model turn, so running `office.sh` from a terminal is the zero-token way. The board itself never calls a model.

## 8. MVP, as pull requests into `feat/office-board`

0. **Spike (not merged).** A raw-payload dump hook in `settings.local.json` for one `build-task` run. It checks the assumptions about Claude Code hook inputs (`agent_id` and `agent_type` on `SubagentStart`, nested subagents' events, `async` support, subagent transcript paths) and records the fixtures for PR 2.
1. **Event capture.** `hooks/office-event.sh`, the `hooks.json` entries, the schema doc and `tests/test-office-hook.sh`: empty stdout for every event; exit 0 on bad input, missing jq, no project or an unwritable folder; a timing budget; `next-phase.sh` unchanged.
2. **Model.** `office/model.js`, the default `board.json`, the state.json fallback mapping, the text snapshot and Node tests on the fixtures. A Node step in CI.
3. **Server and 2D UI.** `server.js` (snapshot, SSE, tailing, pruning, idle exit) and the board.
4. **`/workez:office`.** `office.sh`, the skill, a Node check in `doctor`, README and WORKFLOW docs.

## Open questions

Each has a recommended answer, used unless decided otherwise.

1. **Card granularity.** One card per task (and one per feature for steps 1 to 3a) with the current agent as a badge, or one card per agent run (a reviewer card three times per task)? Recommended: per task.
2. **Board scope.** One board per project with each feature as a row, or one board across projects? Recommended: per project for the MVP; the event files are per project, so a global board can come later.
3. **Recording default.** Record events from day one in every workez project, or only after the first `/workez:office`? Recommended: from day one, with the `office: false` opt-out.
