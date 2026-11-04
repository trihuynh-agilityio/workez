#!/usr/bin/env bash
# Records what the workflow is doing, for the office board: one JSON line per hook event, appended to
# <project>/.claude/workflow/office/events-<session>.jsonl. Facts only (who, which skill or agent, which
# feature and task); the board decides steps and columns. The schema is in docs/office-events.md.
# Registered for: PreToolUse (Skill, Agent, Task, AskUserQuestion, ExitPlanMode), PostToolUse (Agent, Task,
# AskUserQuestion, ExitPlanMode), SubagentStart, SubagentStop, Notification, UserPromptSubmit, Stop,
# SessionStart, SessionEnd. A Skill other than workez:* is not recorded.
# Silent and harmless: prints nothing (stdout of UserPromptSubmit and SessionStart would reach the model;
# exit 2 of PreToolUse would block the tool) and always exits 0. Any problem drops the event.
# Off when "office" is false in .claude/workflow.local.json (for you), else in .claude/workflow.json (for
# everyone); WF_OFFICE=on or off (also 1/0, true/false, yes/no) wins over both.

exec >/dev/null 2>&1
trap 'exit 0' EXIT
input="$(cat)"
command -v jq || exit 0

if [[ -n "${WF_OFFICE:-}" ]]; then
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$WF_OFFICE")" =~ ^(off|0|false|no)$ ]] && exit 0
fi

# The project. Fast path: $CLAUDE_PROJECT_DIR holds workflow.json and is a main checkout (its repository's
# .git is a folder), so no git call is needed. Otherwise hook-env.sh, which also maps a worktree to the
# main checkout.
project=""
d="${CLAUDE_PROJECT_DIR:-}"
if [[ -n "$d" && -f "$d/.claude/workflow.json" ]]; then
  r="$d"
  while [[ -n "$r" && "$r" != / && ! -e "$r/.git" ]]; do r="$(dirname "$r")"; done
  [[ -d "$r/.git" ]] && project="$d"
fi
if [[ -z "$project" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/hook-env.sh" || exit 0
  project="$WF_PROJECT"
fi

# The personal "office" key; grep first so the common case (no key) costs no jq call.
if [[ -z "${WF_OFFICE:-}" ]]; then
  for f in "$project/.claude/workflow.local.json" "$project/.claude/workflow.json"; do
    [[ -f "$f" ]] && grep -q '"office"' "$f" && jq -e 'has("office")' "$f" && {
      [[ "$(jq -r '.office' "$f")" == false ]] && exit 0
      break
    }
  done
fi

# One jq call: "<session>\t<event line>", or nothing for an event not worth recording.
out="$(jq -rc '
  def cut($n): if type == "string" then (if length > $n then .[:$n - 1] + "…" else . end) else . end;
  # The plain text of a tool result or a message.
  def text: if type == "string" then .
    elif type == "array" then [.[]? | if type == "string" then . else (.text? // empty) end] | join("\n")
    elif type == "object" then ((.content? // .result? // .text? // "") | text)
    else "" end;
  # A lane'"'"'s result: the last line that starts with one of its result words.
  def result: [text | split("\n")[] | select(test("^\\s*(PR_READY|PR_EXISTS|BLOCKED|FAILED)\\b"))
    | sub("^\\s+"; "")] | last // null | cut(240);
  # The feature: the folder of a plan.md or plan-fix.md path; the task: the first T<n>.
  def feature_of: (capture("(?<f>[A-Za-z0-9._-]+)/plan(-fix)?\\.md")? // {}) | .f // null;
  def task_of: (capture("\\b(?<t>T[0-9]+)\\b")? // {}) | .t // null;
  def first_word: (capture("^\\s*(?<w>[A-Za-z0-9][A-Za-z0-9._-]*)")? // {}) | .w // null;

  . as $e | ($e.hook_event_name // "") as $h | ($e.tool_name // "") as $tool | ($e.tool_input // {}) as $in |
  if $h == "PreToolUse" and $tool == "Skill" then
    (($in.skill // "") | tostring) as $s | (($in.args // "") | tostring) as $a |
    if ($s | startswith("workez:")) then {skill: $s, feature: ($a | first_word), detail: {args: ($a | cut(200))}}
    else empty end
  elif ($tool == "Agent" or $tool == "Task") then
    (($in.prompt // "") | tostring) as $p |
    {feature: ($p | feature_of), task: ($p | task_of),
     detail: ({subagent_type: ($in.subagent_type // null), description: ($in.description // null | cut(120)),
               model: ($in.model // null)}
       + if $h == "PostToolUse" then {result: ($e.tool_response | result)} else {} end)}
  elif $tool == "AskUserQuestion" then {detail: {question: ($in.questions[0].question? // null | cut(200))}}
  elif $tool == "ExitPlanMode" then {detail: {}}
  elif $h == "SubagentStart" then {detail: {}}
  elif $h == "SubagentStop" then
    {detail: {result: ($e.last_assistant_message // "" | result), transcript: ($e.agent_transcript_path // null)}}
  elif $h == "Notification" then
    {detail: {type: ($e.notification_type // null), message: ($e.message // null | cut(200))}}
  elif $h == "UserPromptSubmit" then
    # Never the prompt itself; only a /workez: command and its first argument.
    (($e.prompt // "") | tostring | capture("^\\s*/(?<s>workez:[A-Za-z0-9-]+)\\s*(?<a>.*)")? // null) as $c |
    if $c then {skill: $c.s, feature: ($c.a | first_word), detail: {command: true}} else {detail: {}} end
  elif $h == "SessionStart" then {detail: {source: ($e.source // null)}}
  elif $h == "SessionEnd" then {detail: {reason: ($e.reason // null)}}
  elif $h == "Stop" then {detail: {}}
  else empty end
  | (($e.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")) as $sid
  | select($sid != "")
  | {v: 1, ts: (now * 1000 | floor), hook: $h, tool: (if $tool == "" then null else $tool end),
     session: $sid, agent_id: ($e.agent_id // null), agent_type: ($e.agent_type // null),
     skill: (.skill // null), feature: (.feature // null), task: (.task // null),
     tool_use_id: ($e.tool_use_id // null), cwd: ($e.cwd // null), transcript: ($e.transcript_path // null),
     detail: (.detail // {})}
  | "\(.session)\t\(tojson)"
' <<<"$input")"
[[ "$out" == *$'\t'* ]] || exit 0
session="${out%%$'\t'*}"
line="${out#*$'\t'}"
# Under 4 KB, so one append never interleaves with another hook's (the two lanes share a session).
((${#line} < 4000)) || exit 0
dir="$project/.claude/workflow/office"
mkdir -p "$dir" || exit 0
printf '%s\n' "$line" >>"$dir/events-$session.jsonl"
exit 0
