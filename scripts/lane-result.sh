#!/usr/bin/env bash
# Read and write the result file of one build lane, so a lane that runs in its own desktop sub session
# and the build session that started it share one record.
#   lane-result.sh set <feature> <task-id> <field>=<string> | <field>:=<json> ...
#   lane-result.sh get <feature> <task-id> [field]
#   lane-result.sh states <feature>
# The file is .claude/workflow/<feature>/lane-<task-id>.json (git-ignored, under the main checkout's project
# folder even when called from a worktree). `set` merges the given fields into it, creating it from
# {"task": "<task-id>"}, and sets "updated" to the current UTC time; the write is atomic (temp file, then mv).
# `field=value` stores a string, `field:=value` stores any JSON (arrays, numbers; invalid JSON exits 2 and
# writes nothing). Field names match ^[a-z_]+$. `set` prints "SET <path>".
# `get` prints the whole JSON (compact), or one field raw (arrays as compact JSON, a missing field as an empty
# line); exit 1 when the file does not exist.
# `states` prints one line per lane-T*.json, ordered by task number: "LANE <task> <status> <pr|-> <merge_sha|->"
# (status "-" when missing). This is what build-position.sh reads from its states file.
# Known statuses (not enforced): starting, running, pr_open, merged, blocked, failed, stale.
# Known fields: task, issue, lane, runner (session|agent), session, status, pr, merge_sha, handled_feedback
# (array), fix_rounds, settled (array), cron_id, reason, notes (array), updated.
# Exit 2 on bad usage (a bad feature name, task id, field name or JSON).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

usage() {
  cat >&2 <<'USAGE'
usage: lane-result.sh set <feature> <task-id> <field>=<string> | <field>:=<json> ...
       lane-result.sh get <feature> <task-id> [field]
       lane-result.sh states <feature>
USAGE
  exit 2
}
die() { echo "lane-result.sh: $1" >&2; exit 2; }

(($# >= 2)) || usage
cmd="$1"; feature="$2"
[[ -n "$feature" && "$feature" != */* && "$feature" != .* ]] || die "bad feature name '$feature'"
dir="$WF_PROJECT/.claude/workflow/$feature"

case "$cmd" in
  states)
    (($# == 2)) || usage
    [[ -d "$dir" ]] || exit 0
    while IFS= read -r f; do
      jq -r '"LANE \(.task // "-") \(.status // "-") \(.pr // "-") \(.merge_sha // "-")"' "$f"
    done < <(
      for f in "$dir"/lane-T*.json; do
        [[ -f "$f" ]] || continue
        n="$(basename "$f" .json)"; n="${n#lane-T}"
        [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\t%s\n' "$n" "$f"
      done | sort -n | cut -f2
    )
    ;;
  get)
    (($# == 3 || $# == 4)) || usage
    task="$3"; [[ "$task" =~ ^T[0-9]+$ ]] || die "bad task id '$task'"
    file="$dir/lane-$task.json"
    [[ -f "$file" ]] || exit 1
    if (($# == 4)); then
      [[ "$4" =~ ^[a-z_]+$ ]] || die "bad field name '$4'"
      jq -r --arg k "$4" '.[$k] // empty | if type == "string" then . else tojson end' "$file"
    else
      jq -c . "$file"
    fi
    ;;
  set)
    (($# >= 4)) || usage
    task="$3"; [[ "$task" =~ ^T[0-9]+$ ]] || die "bad task id '$task'"
    shift 3
    file="$dir/lane-$task.json"
    json='{}'
    [[ -f "$file" ]] && json="$(jq -c . "$file")"
    [[ "$json" == '{}' ]] && json="$(jq -nc --arg t "$task" '{task: $t}')"
    for kv in "$@"; do
      if [[ "$kv" =~ ^([a-z_]+):=(.*)$ ]]; then
        json="$(jq -c --arg k "${BASH_REMATCH[1]}" --argjson v "${BASH_REMATCH[2]}" '.[$k] = $v' <<<"$json" 2>/dev/null)" \
          || die "'${BASH_REMATCH[1]}' is not valid JSON"
      elif [[ "$kv" =~ ^([a-z_]+)=(.*)$ ]]; then
        json="$(jq -c --arg k "${BASH_REMATCH[1]}" --arg v "${BASH_REMATCH[2]}" '.[$k] = $v' <<<"$json")"
      else
        die "bad field '$kv' (use field=string or field:=json, field names a-z and _)"
      fi
    done
    json="$(jq -c --arg u "$(date -u +%FT%TZ)" '.updated = $u' <<<"$json")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.lane-$task.XXXXXX")"
    printf '%s\n' "$json" >"$tmp"
    mv "$tmp" "$file"
    echo "SET $file"
    ;;
  *) usage ;;
esac
