#!/usr/bin/env bash
# PostToolUse hook: format the file Claude just wrote or edited, with the "format" rules of
# .claude/workflow.json. Never blocks the edit.
# Works in this checkout and in task worktrees (<repo root>/.claude/worktrees/<name>/<project path>/,
# or the same under this project's .claude/worktrees/), where the implementer edits. Each rule's
# write command runs in that folder of THIS checkout, with the file's absolute path appended, so a
# worktree without installed tools is still formatted (the tools read the config nearest the file).

input="$(cat)"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0

file="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
[[ -n "$file" && -f "$file" ]] || exit 0

# The project folder the file belongs to.
case "$file" in
  "$WF_PROJECT"/.claude/worktrees/* | "$WF_TOP"/.claude/worktrees/*)
    base="${file%%/.claude/worktrees/*}"
    rest="${file#"$base"/.claude/worktrees/}"
    proj="$(wf_project_in "$base/.claude/worktrees/${rest%%/*}")"
    ;;
  "$WF_PROJECT"/.claude/*) exit 0 ;;
  "$WF_PROJECT"/*) proj="$WF_PROJECT" ;;
  *) exit 0 ;;
esac
[[ "$file" == "$proj"/* ]] || exit 0

i="$(wf_format_rule "${file#"$proj"/}")" || exit 0
dir="$(cfg ".format[$i].dir")"; write="$(cfg ".format[$i].write")"
[[ -n "$write" ]] || exit 0
(cd "$WF_PROJECT/${dir:-.}" && bash -c "$write \"\$1\"" write "$file" >&2) \
  || echo "format-on-edit: '$write' failed on $file" >&2

exit 0
