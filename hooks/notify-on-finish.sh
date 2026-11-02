#!/usr/bin/env bash
# Stop hook: show a macOS notification when Claude finishes responding.
# Never blocks; silently does nothing off macOS.

command -v osascript >/dev/null 2>&1 || exit 0
input="$(cat)"
# Only in projects that use the workflow (a .claude/workflow.json).
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0

# The title is the project folder's name.
title="$(basename "$WF_PROJECT")"
osascript -e "display notification \"Claude finished responding\" with title \"${title//\"/}\" sound name \"Glass\"" >/dev/null 2>&1

exit 0
