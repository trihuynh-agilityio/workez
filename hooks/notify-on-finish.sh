#!/usr/bin/env bash
# Shows a macOS notification when Claude needs the user: it finished, or it waits for an approval or an answer.
#   title:    the project folder's name, then why: "finished", "needs your approval" or "needs your answer"
#   subtitle: the current git branch
#   message:  Stop (called by next-phase.sh only when the stop is not handed off to the next phase): the start
#               of Claude's last reply (the hook's "last_assistant_message", else the last assistant text in the
#               transcript), as one line without Markdown; a generic line when neither has text.
#             Notification (permission_prompt, elicitation_dialog): the hook's "message".
#             PreToolUse AskUserQuestion: the first question; ExitPlanMode: a fixed line.
# Never blocks; silently does nothing off macOS. WF_NOTIFY_DRY_RUN=1 prints the three lines instead (for tests).

[[ -n "${WF_NOTIFY_DRY_RUN:-}" ]] || command -v osascript >/dev/null 2>&1 || exit 0
input="$(cat)"
# Only in projects that use the workflow (a .claude/workflow.json); needs jq.
command -v jq >/dev/null 2>&1 || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0

case "$(jq -r '.hook_event_name // "Stop"' <<<"$input" 2>/dev/null)" in
  Notification)
    why="needs your approval"
    msg="$(jq -r '.message // empty' <<<"$input" 2>/dev/null)"
    ;;
  PreToolUse)
    if [[ "$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" == "ExitPlanMode" ]]; then
      why="needs your approval"
      msg="The plan is ready for your approval"
    else
      why="needs your answer"
      msg="$(jq -r '.tool_input.questions[0].question // empty' <<<"$input" 2>/dev/null)"
    fi
    ;;
  *)
    why="finished"
    msg="$(jq -r '.last_assistant_message // empty' <<<"$input" 2>/dev/null)"
    if [[ -z "$msg" ]]; then
      transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
      [[ -f "$transcript" ]] && msg="$(tail -n 200 "$transcript" | jq -rs '
        [.[] | select(.type == "assistant") | .message.content
          | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end
          | select(length > 0)] | last // empty' 2>/dev/null)"
    fi
    ;;
esac
# One line: drop code blocks, Markdown marks and link targets, squeeze the spaces, cut to 220 characters
# (counted by jq, so a multi-byte character is never split).
msg="$(printf '%s\n' "$msg" | awk '/^[[:space:]]*```/ { code = !code; next } !code' | sed -E \
  -e 's/\[([^]]*)\]\([^)]*\)/\1/g' -e 's/^[[:space:]]*(#+|[-*+]|[0-9]+\.)[[:space:]]+//' -e 's/[*_`]+//g' \
  | tr '\n\t' '  ' | tr -s ' ' | jq -Rrs 'sub("^ +"; "") | sub(" +$"; "") | if length > 220 then .[:219] + "…" else . end')"
[[ -n "$msg" ]] || { [[ "$why" == finished ]] && msg="Claude finished responding" || msg="Claude is waiting for you"; }

title="$(basename "$WF_PROJECT"): $why"
branch="$(git -C "$WF_PROJECT" branch --show-current 2>/dev/null)"

if [[ -n "${WF_NOTIFY_DRY_RUN:-}" ]]; then
  printf '%s\n%s\n%s\n' "$title" "$branch" "$msg"
  exit 0
fi
# The texts go in as arguments, so quotes in them need no escaping.
osascript -e 'on run argv' \
  -e 'display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv) sound name "Glass"' \
  -e 'end run' "$title" "$branch" "$msg" >/dev/null 2>&1

exit 0
