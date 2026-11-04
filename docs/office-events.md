# Office events, schema version 1

`hooks/office-event.sh` records what the workflow does for the office board. These files are its only output. The board, or any other view (a 3D office later), reads them; nothing in them knows about steps or columns.

## Files

`<project>/.claude/workflow/office/events-<session>.jsonl`, one per Claude Code session, git-ignored with the rest of `.claude/workflow/`. The project is the main checkout, also for events fired inside a task worktree. One JSON object per line, appended; a line is always under 4 KB, so the two lanes of a session never mix their lines. Readers skip a line they cannot parse.

## Line

```json
{"v": 1, "ts": 1793782323123, "hook": "PreToolUse", "tool": "Agent", "session": "3f2a…",
 "agent_id": "a91c…", "agent_type": "general-purpose", "skill": null, "feature": "login-page", "task": "T2",
 "tool_use_id": "toolu_…", "cwd": "/repo", "transcript": "/…/3f2a….jsonl",
 "detail": {"subagent_type": "workez:implementer", "description": "Build T2", "model": "sonnet", "result": null}}
```

| Field | Meaning |
|---|---|
| `v` | schema version, `1` |
| `ts` | when the hook ran, milliseconds since the Unix epoch |
| `hook` | the Claude Code hook event: `PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Notification`, `UserPromptSubmit`, `Stop`, `SessionStart`, `SessionEnd` |
| `tool` | for tool events: `Skill`, `Agent` (or `Task`), `AskUserQuestion`, `ExitPlanMode`; else `null` |
| `session` | the session id, cleaned to `[A-Za-z0-9_-]` (also the file name) |
| `agent_id`, `agent_type` | the subagent the event comes from (`SubagentStart` and `SubagentStop`: the subagent itself); `null` on the main thread |
| `skill` | a `workez:*` skill that starts: from a `Skill` call or a typed `/workez:` command |
| `feature` | the feature (or `build-task` slug): the first word of the skill's arguments, or the folder of the `plan.md` / `plan-fix.md` path in an agent's prompt |
| `task` | the first `T<n>` in an agent's prompt |
| `tool_use_id` | the tool call, to pair a `PreToolUse` with its `PostToolUse` |
| `cwd` | the hook's working folder (a task worktree inside a lane) |
| `transcript` | the session's transcript; its modification time shows the session is alive |
| `detail` | per event, below |

## `detail` per event

| Event | `detail` |
|---|---|
| `PreToolUse` `Skill` | `args` (cut to 200 characters). Only `workez:*` skills are recorded. |
| `PreToolUse` / `PostToolUse` `Agent` | `subagent_type`, `description`, `model`; on `PostToolUse` also `result` |
| `SubagentStop` | `result`, `transcript` (the subagent's own transcript) |
| `PreToolUse` / `PostToolUse` `AskUserQuestion` | `question`: the first question |
| `PreToolUse` / `PostToolUse` `ExitPlanMode` | `{}` |
| `Notification` | `type` (`permission_prompt`, `elicitation_dialog`, `idle_prompt`, ...), `message` |
| `UserPromptSubmit` | `{"command": true}` for a `/workez:` command, else `{}`. The prompt text is never recorded. |
| `SessionStart` | `source` (`startup`, `resume`, `clear`, `compact`) |
| `SessionEnd` | `reason` |
| `SubagentStart`, `Stop` | `{}` |

`result` is a lane's or agent's result line: the last line that starts with `PR_READY`, `PR_EXISTS`, `BLOCKED` or `FAILED` (cut to 240 characters), else `null`. Agents may run in the background, so a lane's result can arrive on `SubagentStop` rather than on the `Agent` call's `PostToolUse`.

## Rules

- Lines are facts. Which step or column a fact means is the board's business (its config), so the hook stays the same when the columns change.
- New fields may be added within version 1; readers ignore fields they do not know. A renamed or removed field, or a changed meaning, raises `v`.
- Turning it off: `"office": false` in `.claude/workflow.local.json` (for you) or `.claude/workflow.json` (for everyone), or `WF_OFFICE=off`, which wins over both.
