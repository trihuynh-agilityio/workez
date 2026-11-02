#!/usr/bin/env bash
# PreToolUse hook (Bash): Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/) for
# commits and branches made through the Bash tool, when .claude/workflow.json sets
# conventions.commit_types. Checks the subject of `git commit -m "<subject>"` and the name given to
# `git checkout -b`, `git switch -c`, `git branch <name>` and `git worktree add -b`. A command it
# cannot read (a message from a file or an editor, a name in a variable) is left to check-task.sh.
# Exit 2 blocks the call and sends the reason back to Claude.

input="$(cat)"
command="$(jq -r '.tool_input.command // empty' <<<"$input")"
[[ -n "$command" ]] || exit 0
grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|checkout|switch|branch|worktree)([[:space:]]|$)' <<<"$command" || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0
wf_conventions || exit 0

block() {
  echo "Blocked: $1 (Conventional Commits, see conventions in .claude/workflow.json)" >&2
  exit 2
}

# The first -m/--message value of a git commit, in double or single quotes.
if grep -Eq 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)' <<<"$command"; then
  msg="$(perl -ne 'if (/git(?:\s+-C\s+\S+)?\s+commit\b.*?(?:-m|--message)(?:=|\s+)(?:"((?:[^"\\]|\\.)*)"|'"'"'([^'"'"']*)'"'"')/s) { print defined $1 ? $1 : $2; exit }' <<<"$command")"
  if [[ -n "$msg" && "$msg" != *'$('* && "$msg" != *'`'* ]]; then
    subject="$(head -1 <<<"$msg")"
    why="$(wf_commit_ok "$subject")" || block "$why"
  fi
fi

# The name of a new branch.
name="$(perl -ne '
  if (/git(?:\s+-C\s+\S+)?\s+(?:checkout\s+(?:-[a-zA-Z]+\s+)*-[bB]|switch\s+(?:-[a-zA-Z]+\s+)*-[cC]|worktree\s+add\s+(?:-[a-zA-Z-]+\s+)*-[bB])\s+([^\s;&|]+)/) { print $1; exit }
  if (/git(?:\s+-C\s+\S+)?\s+branch\s+(?!-)([^\s;&|]+)/) { print $1; exit }' <<<"$command")"
name="${name//\"/}"; name="${name//\'/}"
if [[ -n "$name" && "$name" != *'$'* ]]; then
  why="$(wf_branch_ok "$name")" || block "$why"
fi
exit 0
