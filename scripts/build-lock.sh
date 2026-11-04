#!/usr/bin/env bash
# Whether a feature (or a standalone build-task slug) may start building now.
#   build-lock.sh <feature>
# Features owned by different Claude sessions build at the same time: each session has its own
# Playwright servers, and dev-servers.sh gives each feature its own ports. One session still runs lanes
# for one feature at a time, because both would drive that session's two Playwright browsers.
# So the build may start unless another feature with phase build or task and status in_progress has the
# same owner (.claude/workflow/<feature>/owner, written by the claim-feature.sh hook). A feature with no
# owner file is counted as this session's, the safe guess.
# Exit 0 and prints FREE; exit 1 and prints BUSY <other feature> for each one in the way. Read-only.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
feature="${1:-}"
[[ -n "$feature" ]] || { echo "usage: build-lock.sh <feature>" >&2; exit 2; }
DIR="$WF_PROJECT/.claude/workflow"
mine="$(cat "$DIR/$feature/owner" 2>/dev/null)"

busy=0
for s in "$DIR"/*/state.json; do
  [[ -f "$s" ]] || continue
  other="$(basename "$(dirname "$s")")"
  [[ "$other" == "$feature" ]] && continue
  jq -e '(.phase == "build" or .phase == "task") and .status == "in_progress"' "$s" >/dev/null 2>&1 || continue
  theirs="$(cat "$DIR/$other/owner" 2>/dev/null)"
  if [[ -z "$mine" || -z "$theirs" || "$mine" == "$theirs" ]]; then
    echo "BUSY $other"
    busy=1
  fi
done
((busy)) && exit 1
echo FREE
