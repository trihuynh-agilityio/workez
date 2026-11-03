#!/usr/bin/env bash
# Stop hook: when a phase finished and was not handed off yet, block the stop once and tell
# Claude to run the next skill. State: one file per feature, .claude/workflow/<feature>/state.json.
# The table:
#   plan       / done / handed_off=false -> design-feature       (Phase 1 -> Phase 2)
#   design     / done / handed_off=false -> write-plan           (Phase 2 -> Phase 3)
#   write-plan / done / handed_off=false -> create-task-issues   (asks the user to approve the plan)
#   tasks      / done / handed_off=false -> build-feature        (runs after the plan approval, no user command)
#   build      / done / handed_off=false -> verify-feature       (build-feature sets this only after every task PR is merged and the final PR is open)
# Anything else (build in progress, waiting_review, blocked, verify, done, and a standalone build-task
# with phase task) never advances.
# With several features ready, the one whose state changed first goes now, the next at the next stop.
# Appends one line per run to .claude/workflow/hook.log, cut back to its last 500 lines once it passes
# 1000. Any problem allows the stop. Every allowed stop runs notify-on-finish.sh (its output to stderr), so
# the "finished" notification comes only when Claude really stops, never on a hand-off.

input="$(cat)"
# Only in projects that use the workflow (a .claude/workflow.json); needs jq.
command -v jq >/dev/null 2>&1 || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0
handed_off=""
trap '[[ -n "$handed_off" ]] || bash "$(dirname "${BASH_SOURCE[0]}")/notify-on-finish.sh" <<<"$input" >&2' EXIT
DIR="$WF_PROJECT/.claude/workflow"
LOG="$DIR/hook.log"
mkdir -p "$DIR" 2>/dev/null

log() {
  printf '%s decision=%s %s\n' "$(date '+%F %T')" "$1" "${2:-}" >>"$LOG" 2>/dev/null
  # Keep the log short: past 1000 lines, keep the last 500 (through a temp file, so a failure leaves it whole).
  if (($(wc -l <"$LOG" 2>/dev/null || echo 0) > 1000)); then
    local tmp
    tmp="$(mktemp "$DIR/hook.log.XXXXXX" 2>/dev/null)" && tail -n 500 "$LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
}

[[ "$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)" == "true" ]] && { log "allow:stop-hook-active"; exit 0; }

# The ready state files, oldest change first.
ready=""
while IFS= read -r f; do
  [[ "$(jq -r 'select(.status == "done" and .handed_off == false) | .phase' "$f" 2>/dev/null)" =~ ^(plan|design|write-plan|tasks|build)$ ]] \
    && { ready="$f"; break; }
done < <(ls -tr "$DIR"/*/state.json 2>/dev/null)
[[ -n "$ready" ]] || { log "allow:not-ready"; exit 0; }

state="$(tr -d '\n' <"$ready")"
feature="$(jq -r '.feature // empty' "$ready")"
case "$(jq -r '.phase' "$ready")" in
  plan) next="design-feature"; from="Phase 1 (Plan)"; to="Phase 2 (Design)" ;;
  design) next="write-plan"; from="Phase 2 (Design)"; to="the plan" ;;
  write-plan) next="create-task-issues"; from="The plan"; to="the task issues" ;;
  tasks) next="build-feature"; from="Creating the task issues"; to="the build" ;;
  build) next="verify-feature"; from="Phase 3 (Build)"; to="Phase 4 (Verify)" ;;
esac
[[ -n "$feature" ]] || { log "allow:no-feature" "state=$state"; exit 0; }

# Mark the hand-off before blocking so a second Stop can never repeat it.
tmp="$(mktemp)"
if jq -c '.handed_off = true' "$ready" >"$tmp" 2>/dev/null; then
  mv "$tmp" "$ready"
else
  rm -f "$tmp"
  log "allow:state-write-failed" "state=$state"
  exit 0
fi

log "block:handoff-to-$next" "state=$state"
handed_off=1
jq -n --arg r "$from is done for \"$feature\". Start $to now: invoke the workez:$next skill with the argument \"$feature\"." \
  '{decision: "block", reason: $r}'
exit 0
