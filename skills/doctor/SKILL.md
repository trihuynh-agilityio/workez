---
name: doctor
description: Use when asked to check, diagnose or verify that a project and this machine are ready for the workez feature workflow, after setup, after changing .claude/workflow.json, or when a workflow step fails for an unclear reason.
allowed-tools: Read Bash(*/scripts/doctor.sh*)
---

# Check the workflow setup

Run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` from the project folder (add `--offline` only if the user asks to skip GitHub). It changes nothing.

Report the result to the user:

- Each `FAIL` line first, with what to do about it, in the order the script printed them. A missing or wrong `workflow.json`, permissions or `.gitignore` is fixed by the `workez:setup` skill; a missing tool by installing it; GitHub access by `gh auth login` or the repository settings.
- Then each `WARN` line and what it costs (for example no Chrome: the UI checks cannot run).
- Then one line: ready, or not ready until the failures are fixed.

Do not fix anything yourself unless the user asks.
