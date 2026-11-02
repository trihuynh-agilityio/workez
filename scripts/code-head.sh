#!/usr/bin/env bash
# Prints CODE_HEAD: the latest commit that changes any file outside the review reports
# (<docs_dir>/*/reviews/**) and the UI-check evidence (<docs_dir>/*/evidence/**).
# Older task branches committed these records, so HEAD could move without the code changing;
# every gate compares against CODE_HEAD instead of HEAD.
#   code-head.sh [base]    run inside a task worktree; with a base, only commits in base..HEAD count

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 1
docs="$(cfg .docs_dir)"

base="${1:-}"
range="HEAD"
[[ -n "$base" ]] && range="$base..HEAD"

head="$(git log -1 --format=%H "$range" -- ':(top)' \
  ":(top,exclude,glob)**/$docs/*/reviews/**" \
  ":(top,exclude,glob)**/$docs/*/evidence/**")"

[[ -n "$head" ]] || { echo "code-head: no code commit found in $range" >&2; exit 1; }
echo "$head"
