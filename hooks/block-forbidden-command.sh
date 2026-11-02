#!/usr/bin/env bash
# PreToolUse hook (Bash): block commands that are destructive or break project rules.
# Exit 2 blocks the call and sends the message on stderr back to Claude.
# Does nothing in a project without .claude/workflow.json. The generic rules live here; the project's own rules are "blocked_commands" in .claude/workflow.json
# (each an extended regex "pattern" and a "message"), and the protected branches come from
# "branches.protected".

input="$(cat)"
command="$(jq -r '.tool_input.command // empty' <<<"$input")"
[[ -n "$command" ]] || exit 0
# Only in projects that use the workflow (a .claude/workflow.json).
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0

block() {
  echo "Blocked: $1" >&2
  exit 2
}

matches() { grep -Eq -- "$1" <<<"$command"; }

# Project rules from workflow.json.
while IFS=$'\t' read -r pattern message; do
  [[ -n "$pattern" ]] && matches "$pattern" && block "$message"
done < <(jq -r '.blocked_commands // [] | .[] | "\(.pattern)\t\(.message)"' "$WF_CONFIG")
protected="$(cfg '.branches.protected | join("|")')"
protected="${protected:-$(cfg .branches.base)}"

# Git: never force-push, never push to or merge on a protected branch
matches 'git[[:space:]]+push([[:space:]]+[^;&|]*)?[[:space:]](--force|--force-with-lease|-f)([[:space:]]|$)' \
  && block "force push is not allowed."
matches "git[[:space:]]+push([[:space:]]+[^;&|]*)?[[:space:]:](HEAD:)?(refs/heads/)?($protected)([[:space:]]|\$)" \
  && block "never push to a protected branch ($protected)."
if matches 'git[[:space:]]+(push|merge)([[:space:]]|$)'; then
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -n "$current" ]] && grep -Eqx -- "$protected" <<<"$current" \
    && block "currently on $current; never merge or push on a protected branch."
fi

# Destructive operations
matches 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*("?(/|~|\.|\.\.|\$HOME|\$\{HOME\})/?"?)([[:space:]]|$)' \
  && block "rm -rf on /, ~, \$HOME, . or .. is not allowed."
matches 'git[[:space:]]+reset[[:space:]]+[^;&|]*--hard' \
  && block "git reset --hard discards work; ask the user first."
matches 'git[[:space:]]+clean[[:space:]]+[^;&|]*-[a-zA-Z]*f' \
  && block "git clean -f deletes untracked files; ask the user first."

exit 0
