#!/usr/bin/env bash
# Computes where the build of a feature stands, from the plan and the pull request states. No writes.
#   build-position.sh <plan-path> <states-file>
# Also reads plan-fix.md next to the plan when it exists (the fix waves verify-feature adds after a FAIL);
# each task line ends with plan=<file> so callers pass the right plan path for that task.
# states-file, one line each, tab or space separated (from github-ops get-pr-state):
#   <branch> <OPEN|MERGED|CLOSED|NONE> [pr-number]
#   CHECK <task-id> PASS     the integration check of a task that has no PR of its own
# The integration task is the one whose Branch says "(only if fixes are needed)"; its line has integration=yes.
# Output: one line per task, then CURRENT_WAVE, ACTION (start|integrate|wait|blocked|finish) and the tasks it concerns.
# ACTION=integrate: only integration tasks are left to start; run their check in the caller, not as a lane.
# Task status: done (MERGED, or CHECK PASS), waiting (OPEN), closed (CLOSED unmerged), todo, resume (todo with a local branch).

plan="${1:-}"; states="${2:-}"
[[ -f "$plan" && -f "$states" ]] || { echo "usage: build-position.sh <plan-path> <states-file>" >&2; exit 2; }
plan_files=("$plan")
fix="$(dirname "$plan")/plan-fix.md"
[[ -f "$fix" ]] && plan_files+=("$fix")

tasks="$(awk '
  /^## Wave [0-9]+/ { if (id) emit(); wave = $3; next }
  /^## T[0-9]+: /   { if (id) emit(); id = $2; sub(":", "", id); lane = ""; issue = ""; branch = ""; optional = 0; next }
  id && /^- \*\*Lane\*\*:/   { lane = $0; sub(/^- \*\*Lane\*\*: */, "", lane) }
  id && /^- \*\*Issue\*\*:/  { issue = $0; sub(/^- \*\*Issue\*\*: */, "", issue) }
  id && /^- \*\*Branch\*\*:/ { branch = $0; if (branch ~ /only if/) optional = 1; sub(/^[^`]*`/, "", branch); sub(/`.*/, "", branch) }
  /^## /            { if (id) emit(); id = "" }   # any other heading ends a task
  function emit() { printf "%s\t%s\t%s\t%s\t%s\t%d\t%s\n", id, wave, lane, issue, branch, optional, FILENAME; id = "" }
  FNR == 1 && NR > 1 { if (id) emit(); id = "" }
  END { if (id) emit() }
' "${plan_files[@]}")"
[[ -n "$tasks" ]] || { echo "build-position: no tasks found in $plan" >&2; exit 2; }

state_of() { awk -v b="$1" '$1 == b { print $2; exit }' "$states"; }
pr_of()    { awk -v b="$1" '$1 == b { print $3; exit }' "$states"; }
checked()  { awk -v t="$1" '$1 == "CHECK" && $2 == t && $3 == "PASS" { f = 1 } END { exit !f }' "$states"; }

order=(); st_list=(); wv_list=(); int_list=()
while IFS=$'\t' read -r id wave lane issue branch optional src; do
  st="$(state_of "$branch")"; pr="$(pr_of "$branch")"
  s=todo
  case "$st" in
    MERGED) s=done ;;
    OPEN) s=waiting ;;
    CLOSED) s=closed ;;
    *)
      if ((optional)) && checked "$id"; then s=done
      elif [[ -n "$branch" ]] && git rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1; then s=resume
      fi ;;
  esac
  [[ "$issue" =~ ^#[0-9]+$ ]] || s=blocked_no_issue
  order+=("$id"); st_list+=("$s"); wv_list+=("$wave"); int_list+=("$optional")
  printf '%s wave=%s lane=%s issue=%s branch=%s pr=%s status=%s integration=%s plan=%s\n' "$id" "$wave" "$lane" "$issue" \
    "${branch:-none}" "${pr:--}" "$s" "$( ((optional)) && echo yes || echo no)" "$src"
done <<<"$tasks"

current=""
for i in "${!order[@]}"; do
  [[ "${st_list[$i]}" == done ]] && continue
  w="${wv_list[$i]}"
  [[ -z "$current" || "$w" -lt "$current" ]] && current="$w"
done

if [[ -z "$current" ]]; then
  echo "CURRENT_WAVE=none"; echo "ACTION=finish"; exit 0
fi
echo "CURRENT_WAVE=$current"

todo=(); integ=(); closed=(); bad=(); wait=()
for i in "${!order[@]}"; do
  id="${order[$i]}"
  case "${st_list[$i]}" in
    closed) closed+=("$id") ;;
    blocked_no_issue) bad+=("$id") ;;
  esac
  [[ "${wv_list[$i]}" == "$current" ]] || continue
  case "${st_list[$i]}" in
    todo | resume)
      # An integration task with a local branch needed fixes: it runs as a normal lane.
      if ((int_list[i])) && [[ "${st_list[$i]}" == todo ]]; then integ+=("$id"); else todo+=("$id"); fi ;;
    waiting) wait+=("$id") ;;
  esac
done

if ((${#closed[@]})); then echo "ACTION=blocked"; echo "TASKS=${closed[*]} (PR closed without merge)"
elif ((${#bad[@]})); then echo "ACTION=blocked"; echo "TASKS=${bad[*]} (no sub-issue number; run create-task-issues)"
elif ((${#todo[@]})); then echo "ACTION=start"; echo "TASKS=${todo[*]}"
elif ((${#integ[@]})) && ((${#wait[@]} == 0)); then echo "ACTION=integrate"; echo "TASKS=${integ[*]}"
else echo "ACTION=wait"; echo "TASKS=${wait[*]}"; fi
