#!/usr/bin/env bash
# PostToolUse hook (Write|Edit|MultiEdit|Bash|Skill): records which Claude session runs a feature, so
# several sessions can run features side by side in one project without taking each other's work.
# It writes the session id to .claude/workflow/<feature>/owner when this session:
#   - writes that feature's state.json (Write, Edit, MultiEdit, or a Bash redirect `> .../state.json`), or
#   - starts a workez skill whose first argument is a feature that already has a runtime folder
#     (for example `/workez:design-feature search-notes` run by hand to take over a stalled feature).
# next-phase.sh hands a feature's next phase only to its owner; build-lock.sh keeps one session from
# building two features at once. Never blocks anything; any problem is ignored.
# It also appends `<unix ts> <session id> <phase> <transcript path>` (tab separated) to
# .claude/workflow/<feature>/sessions.tsv for every feature it detects, unless the session's latest mark
# anywhere is already this feature in the same phase. token-usage.sh reads these marks to attribute a
# session's tokens to the feature and its phases.

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0
session="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[[ -n "$session" ]] || exit 0
DIR="$WF_PROJECT/.claude/workflow"

features=()
case "$(jq -r '.tool_name // empty' <<<"$input")" in
  Write | Edit | MultiEdit)
    path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
    [[ "$path" =~ \.claude/workflow/([^/]+)/state\.json$ ]] && features+=("${BASH_REMATCH[1]}")
    ;;
  Bash)
    while IFS= read -r f; do [[ -n "$f" ]] && features+=("$f"); done < <(
      jq -r '.tool_input.command // empty' <<<"$input" |
        grep -oE ">[[:space:]]*[\"']?[^[:space:]\"';&|>]*\.claude/workflow/[^/[:space:]\"']+/state\.json" |
        sed -E 's#.*\.claude/workflow/([^/]+)/state\.json$#\1#'
    )
    ;;
  Skill)
    skill="$(jq -r '.tool_input.skill // empty' <<<"$input")"
    arg="$(jq -r '.tool_input.args // empty' <<<"$input" | awk '{print $1}')"
    [[ "$skill" == workez:* && "$arg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && features+=("$arg")
    ;;
esac

transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
# mark <feature>: one sessions.tsv line for this session, unless its latest mark (in any feature) is the same.
mark() {
  local phase last
  phase="$(jq -r '.phase // empty' "$DIR/$1/state.json" 2>/dev/null)"
  last="$(awk -F'\t' -v s="$session" '$2 == s && $1 >= m { m = $1; n = FILENAME; p = $3 } END { print n "\t" p }' "$DIR"/*/sessions.tsv 2>/dev/null)"
  [[ "$last" == "$DIR/$1/sessions.tsv"$'\t'"${phase:--}" ]] && return 0
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$session" "${phase:--}" "${transcript:--}" >>"$DIR/$1/sessions.tsv" 2>/dev/null
  return 0
}

for f in "${features[@]}"; do
  [[ "$f" != . && "$f" != .. && -d "$DIR/$f" ]] || continue
  mark "$f"
  [[ "$(cat "$DIR/$f/owner" 2>/dev/null)" == "$session" ]] && continue
  printf '%s\n' "$session" >"$DIR/$f/owner" 2>/dev/null
done
exit 0
