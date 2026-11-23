#!/usr/bin/env bash
# Append one line to a feature's log of notable events.
#   note.sh <feature> <subject> <what> [<outcome>]
# The file is .claude/workflow/<feature>/notes.md: the per-feature log of notable events (review
# blocker/major findings, wontfix, flaky checks, conflicts, UI check failures, blocked tasks, spec
# deviations, verify failures, auto-merges). build-feature, verify-feature and build-task condense it
# into the "## Notable issues" section of the final PR. It is append-only and git-ignored, because it
# lives under .claude/workflow/. Each call adds one line:
#   - <subject>: <what> → <outcome>      (or "- <subject>: <what>" without an outcome)
# An identical line already in the file is not added again. Prints "NOTED <path>" or "EXISTS <path>".
# Exit 2 on bad usage.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

usage() { echo "usage: note.sh <feature> <subject> <what> [<outcome>]" >&2; exit 2; }
(($# >= 3)) || usage

feature="$1"
[[ -n "$feature" && "$feature" != */* && "$feature" != .* ]] || { echo "note.sh: bad feature name '$feature'" >&2; exit 2; }

# clean <text>: one line, tabs and line breaks as spaces, spaces squeezed and trimmed.
clean() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}
subject="$(clean "$2")"; what="$(clean "$3")"; outcome="$(clean "${4:-}")"
[[ -n "$subject" && -n "$what" ]] || { echo "note.sh: subject and what must not be empty" >&2; exit 2; }

line="- $subject: $what"
[[ -n "$outcome" ]] && line="$line → $outcome"

file="$WF_PROJECT/.claude/workflow/$feature/notes.md"
mkdir -p "$(dirname "$file")"
if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
  echo "EXISTS $file"
  exit 0
fi
printf '%s\n' "$line" >>"$file"
echo "NOTED $file"
