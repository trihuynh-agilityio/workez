#!/usr/bin/env bash
# Prints where every feature (and build-task) of the project stands and who acts next. Read-only:
# reads .claude/workflow/*/state.json and the pr-states.tsv / verify-pr-states.tsv next to them, never
# GitHub. Run it from anywhere inside the project (or prefix WF_PROJECT=<project>).
#   status.sh [--short] [feature]
# Per feature: phase / status, how long ago the state changed, who acts next ("you" or "Claude") and
# what to do, then the task statuses, the PR states as last recorded and the session watch, if any.
# --short: one line per feature (feature, phase / status, who, next). Features waiting on you come first.
# PR states are only as fresh as the last build or verify run; GitHub may be ahead of them.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
DIR="$WF_PROJECT/.claude/workflow"
short=0; [[ "${1:-}" == --short ]] && { short=1; shift; }
only="${1:-}"

# ago <file>: how long since the file changed, roughly.
ago() {
  local s
  s=$(($(date +%s) - $(date -r "$1" +%s 2>/dev/null || date +%s)))
  if ((s < 3600)); then echo "$((s / 60))m ago"
  elif ((s < 86400)); then echo "$((s / 3600))h ago"
  else echo "$((s / 86400))d ago"; fi
}

# next_step <phase> <status> <handed_off> <feature>: "<who>\t<what to do>".
next_step() {
  local f="$4"
  case "$1/$2/$3" in
    plan/done/false) printf 'Claude\tthe Stop hook starts design-feature at the next stop' ;;
    plan/done/true) printf 'Claude\tdesign-feature writes the spec, then you approve it (stalled: /workez:design-feature %s)' "$f" ;;
    design/done/false) printf 'Claude\tthe Stop hook starts write-plan at the next stop' ;;
    design/done/true) printf 'Claude\twrite-plan writes the plan (stalled: /workez:write-plan %s)' "$f" ;;
    write-plan/done/false) printf 'Claude\tthe Stop hook starts create-task-issues, which asks you to approve the plan' ;;
    write-plan/done/true) printf 'you\tapprove the plan in create-task-issues (no session asking: /workez:create-task-issues %s)' "$f" ;;
    tasks/done/false) printf 'Claude\tthe Stop hook starts build-feature at the next stop' ;;
    tasks/done/true) printf 'Claude\tbuild-feature starts the build (stalled: /workez:build-feature %s)' "$f" ;;
    build/in_progress/*) printf 'Claude\tthe lanes are building the wave (stalled: /workez:build-feature %s)' "$f" ;;
    build/waiting_review/*) printf 'you\treview and merge the open task PRs; the watch starts the next wave (no watch: /workez:build-feature %s)' "$f" ;;
    build/blocked/*) printf 'you\ta PR was closed without merge, or a task has no issue or failed; fix it, then /workez:build-feature %s' "$f" ;;
    build/done/false) printf 'Claude\tthe Stop hook starts verify-feature at the next stop' ;;
    build/done/true) printf 'Claude\tverify-feature checks the feature (stalled: /workez:verify-feature %s)' "$f" ;;
    verify/in_progress/*) printf 'Claude\tverify-feature is checking the feature (stalled: /workez:verify-feature %s)' "$f" ;;
    verify/waiting_merge/*) printf 'you\tverify PASSED: merge the final PR; the watch then cleans up (no watch: /workez:verify-feature %s)' "$f" ;;
    verify/failed/*) printf 'you\tverify FAILED: approve plan-fix.md, or say you handle it yourself (/workez:verify-feature %s)' "$f" ;;
    verify/blocked/*) printf 'you\tverify could not run; read its report, fix the cause, then /workez:verify-feature %s' "$f" ;;
    task/in_progress/*) printf 'Claude\tthe lane is building the task (stalled: /workez:build-task %s)' "$f" ;;
    task/waiting_review/*) printf 'you\treview and merge the task PR; the watch finishes the task (no watch: /workez:build-task %s)' "$f" ;;
    task/blocked/*) printf 'you\tthe task is blocked; fix the cause, then /workez:build-task %s' "$f" ;;
    task/done/*) printf 'Claude\tthe task PR is merged; the watch cleans up (no watch: /workez:build-task %s)' "$f" ;;
    *) printf '?\tunknown state; check state.json' ;;
  esac
}

# pr_line <tsv>: "branch STATE #pr · ..." on one line.
pr_line() {
  awk '$1 == "CHECK" { out = out sep $2 " check " $3; sep = " · "; next }
       NF >= 2 { out = out sep $1 " " $2 ($3 != "" ? " #" $3 : ""); sep = " · " }
       END { print out }' "$1"
}

shopt -s nullglob
files=("$DIR"/*/state.json)
((${#files[@]})) || { echo "No feature in the workflow ($DIR is empty)."; exit 0; }

# Each feature's output goes to one of two buffers, so the ones waiting on you print first.
shown=0; yours=(); mine=""; rest=""
for s in "${files[@]}"; do
  d="$(dirname "$s")"; name="$(basename "$d")"
  [[ -z "$only" || "$name" == "$only" ]] || continue
  shown=$((shown + 1))
  # Unit separator, not a tab: read collapses empty tab-separated fields.
  if ! IFS=$'\x1f' read -r feature phase status handed wave round loop tasks < <(jq -r '[
      (.feature // ""), (.phase // "?"), (.status // "?"), (.handed_off // false | tostring),
      (.wave // "" | tostring), (.fix_round // "" | tostring), (.loop_id // ""),
      ((.tasks // {}) | to_entries | map("\(.key) \(.value.status // "?")\(if .value.pr then " #\(.value.pr)" else "" end)") | join(" · "))
    ] | join("\u001f")' "$s" 2>/dev/null); then
    if ((short)); then rest+="$name"$'\t?\t?\tunreadable state.json\n'
    else rest+="$name"$'\n'"  unreadable state.json: $s"$'\n\n'; fi
    continue
  fi
  feature="${feature:-$name}"
  IFS=$'\t' read -r who what < <(next_step "$phase" "$status" "$handed" "$feature")

  if ((short)); then
    out="$feature"$'\t'"$phase / $status"$'\t'"$who"$'\t'"$what"$'\n'
  else
    out="$(
      printf '%s  %s / %s  (%s)\n' "$feature" "$phase" "$status" "$(ago "$s")"
      printf '  who:    %s\n' "$who"
      printf '  next:   %s\n' "$what"
      extra=""
      [[ -n "$wave" ]] && extra="wave $wave"
      [[ -n "$round" && "$round" != 0 ]] && extra="${extra:+$extra · }fix round $round"
      [[ -n "$tasks" ]] && extra="${extra:+$extra · }$tasks"
      [[ -n "$extra" ]] && printf '  tasks:  %s\n' "$extra"
      for t in pr-states verify-pr-states; do
        [[ -s "$d/$t.tsv" ]] || continue
        printf '  %-7s %s  (%s, %s)\n' "$([[ $t == pr-states ]] && echo "PRs:" || echo "verify:")" \
          "$(pr_line "$d/$t.tsv")" "$t.tsv" "$(ago "$d/$t.tsv")"
      done
      [[ -n "$loop" ]] && printf '  watch:  %s (runs only while its session is open)\n' "$loop"
    )"$'\n\n'
  fi
  if [[ "$who" == you ]]; then yours+=("$feature"); mine+="$out"; else rest+="$out"; fi
done

((shown)) || { echo "No feature named \"$only\" in $DIR." >&2; exit 1; }
if ((short)); then
  # Columns as wide as their longest cell; the last one (next) is not padded.
  printf 'FEATURE\tPHASE / STATUS\tWHO\tNEXT\n%s%s' "$mine" "$rest" | awk -F'\t' '
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (i < NF && length($i) > w[i]) w[i] = length($i) } n[NR] = NF }
    END { for (r = 1; r <= NR; r++) { line = ""
            for (i = 1; i < n[r]; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i])
            print line cell[r, n[r]] } }'
  echo
else
  printf '%s%s' "$mine" "$rest"
fi
if ((${#yours[@]})); then echo "Waiting on you: ${yours[*]}"; else echo "Nothing waits on you."; fi
