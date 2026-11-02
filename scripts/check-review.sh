#!/usr/bin/env bash
# Review gate for one task. Exits 1 unless the review report exists, its final verdict is PASS,
# and the commit it reviewed is still CODE_HEAD (see code-head.sh). Any code commit after the
# review therefore forces a new review. The report itself stays local and is never committed.
#   check-review.sh <task-id> [plan-path]
# Run from the task's worktree, inside its project folder. The plan path gives the
# feature name; without it the script looks for <docs_dir>/*/reviews/<task-id>.md.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
docs="$(cfg .docs_dir)"

task="${1:-}"
plan="${2:-}"
[[ -n "$task" ]] || { echo "usage: check-review.sh <task-id> [plan-path]" >&2; exit 2; }

if [[ -n "$plan" ]]; then
  report="$docs/$(basename "$(dirname "$plan")")/reviews/$task.md"
else
  report="$(ls "$docs"/*/reviews/"$task".md 2>/dev/null | head -1)"
fi

fail() { echo "check-review $task: FAILED: $1" >&2; exit 1; }

[[ -n "$report" && -f "$report" ]] || fail "no review report (expected $docs/<feature>/reviews/$task.md)"

# The final verdict section is the last "## Final verdict" block.
final="$(awk '/^## Final verdict/ { f = 1; buf = ""; next } f { buf = buf $0 "\n" } END { printf "%s", buf }' "$report")"
[[ -n "$final" ]] || fail "$report has no '## Final verdict' section"

verdict="$(grep -m1 -E '^Verdict:' <<<"$final" | sed -E 's/^Verdict: *//')"
reviewed="$(grep -m1 -E '^Reviewed commit:' <<<"$final" | sed -E 's/^Reviewed commit: *//')"

[[ "$verdict" == "PASS" ]] || fail "final verdict is '${verdict:-missing}', not PASS"
[[ -n "$reviewed" ]] || fail "final verdict names no reviewed commit"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
code_head="$("$here/code-head.sh")" || fail "cannot find CODE_HEAD"

[[ "$code_head" == "$reviewed"* ]] || fail "code changed after the review: reviewed ${reviewed:0:10}, CODE_HEAD is ${code_head:0:10}. Review again."

echo "check-review $task: PASS (verdict PASS on CODE_HEAD ${code_head:0:10})"
