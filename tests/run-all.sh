#!/usr/bin/env bash
# Runs every workflow test and exits non-zero if any fails.
#   bash tests/run-all.sh [-v]     (-v prints every PASS line too)
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
for t in "$dir"/test-*.sh; do
  name="$(basename "$t" .sh)"
  out="$(bash "$t" 2>&1)"; rc=$?
  if [[ "${1:-}" == -v ]]; then printf '== %s\n%s\n' "$name" "$out"
  else grep -E '^FAIL' <<<"$out"; fi
  printf '%-28s %s\n' "$name" "$( ((rc == 0)) && echo ok || echo FAILED)"
  ((rc == 0)) || failed+=("$name")
done
((${#failed[@]} == 0)) || { echo "failed: ${failed[*]}"; exit 1; }
