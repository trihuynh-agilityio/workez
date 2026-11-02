#!/usr/bin/env bash
# Mechanical checks of verify-feature, run in order and one at a time (shared DB and ports are never
# used in parallel). Every step runs even if an earlier one failed.
#   verify-checks.sh <project-dir-in-worktree> <log-dir> <acceptance-test-file>...
# The steps are the commands of workflow.json, in this order: install, build, lint, format_check, test,
# then acceptance (with {output} = <log-dir>/acceptance.json and {files} = the acceptance files, paths
# relative to the acceptance command's dir). Each command is one step named <key>-<dir>.
# Full logs go to <log-dir>; <log-dir>/checks.tsv has one row per step: <step> <exit-code> <seconds> <log-file>.
# Exit 0 if every step passed, else 1.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

proj="${1:-}"; logs="${2:-}"; shift 2 2>/dev/null
[[ -d "$proj" && -n "$logs" && $# -ge 1 ]] || {
  echo "usage: verify-checks.sh <project-dir-in-worktree> <log-dir> <acceptance-test-file>..." >&2; exit 2; }
mkdir -p "$logs"
logs="$(cd "$logs" && pwd)"   # absolute: the steps run in other folders (the acceptance {output} included)
tsv="$logs/checks.tsv"; : >"$tsv"
failed=0

run() {  # run <step> <dir> <command>
  local step="$1" dir="$2" cmd="$3"
  local log="$logs/$step.log" start=$SECONDS code
  (cd "$proj/$dir" && bash -c "$cmd") >"$log" 2>&1; code=$?
  printf '%s\t%s\t%s\t%s\n' "$step" "$code" "$((SECONDS - start))" "$log" >>"$tsv"
  ((code == 0)) || failed=1
  echo "$step exit=$code"
}

for key in install build lint format_check test; do
  while IFS=$'\t' read -r dir cmd; do
    [[ -n "$cmd" ]] || continue
    step="${key//_/-}"; [[ "$dir" == "." ]] || step="$step-${dir//\//-}"
    run "$step" "$dir" "$cmd"
  done < <(wf_commands "$key")
done

files="$(printf '%q ' "$@")"
while IFS=$'\t' read -r dir cmd; do
  [[ -n "$cmd" ]] && run acceptance "$dir" "$(wf_fill "$cmd" output="$logs/acceptance.json" files="$files")"
done < <(wf_commands acceptance)

exit "$failed"
