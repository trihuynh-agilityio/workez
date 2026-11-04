#!/usr/bin/env bash
# office-event.sh: what it records for each hook event, that it is silent and always exits 0, and where it
# writes (the main checkout, also from a worktree; nothing without workflow.json or when turned off).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$SRC/hooks/office-event.sh"
git init -q -b main "$T/app"; mkdir -p "$T/app/.claude"
cp "$SRC/templates/workflow.example.json" "$T/app/.claude/workflow.json"
git -C "$T/app" commit -q --allow-empty -m init
EV="$T/app/.claude/workflow/office"

# send <json>: runs the hook as Claude Code would (project dir set); prints "<exit code>|<stdout+stderr>".
send() { local out rc; out="$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="${PD-$T/app}" bash "$H" 2>&1)"; rc=$?; printf '%s|%s' "$rc" "$out"; }
# last <session>: the session's last recorded line.
last() { tail -n 1 "$EV/events-$1.jsonl" 2>/dev/null; }
# check <name> <jq test on the last line of session s1>
check() { last s1 | jq -e "$2" >/dev/null 2>&1 && ok "$1" || ko "$1: $(last s1)"; }
# quiet <name> <json>: exit 0 and no output at all.
quiet() { local r; r="$(send "$2")"; [[ "$r" == "0|" ]] && ok "silent: $1" || ko "silent: $1 -> $r"; }

# --- What each event records.
quiet "Skill" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Skill","tool_input":{"skill":"workez:design-feature","args":"login-page --dry-run"},"cwd":"/w","transcript_path":"/t/s1.jsonl","tool_use_id":"tu1"}'
check "Skill: workez skill, feature from its args" '.v == 1 and .hook == "PreToolUse" and .tool == "Skill"
  and .skill == "workez:design-feature" and .feature == "login-page" and .detail.args == "login-page --dry-run"
  and .session == "s1" and .cwd == "/w" and .transcript == "/t/s1.jsonl" and .tool_use_id == "tu1" and (.ts | type == "number")'
n="$(wc -l <"$EV/events-s1.jsonl")"
quiet "other skill" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Skill","tool_input":{"skill":"mattpocock-skills:tdd"}}'
[[ "$(wc -l <"$EV/events-s1.jsonl")" == "$n" ]] && ok "Skill: other skills are not recorded" || ko "recorded a non-workez skill"

quiet "Agent launch" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Agent","agent_id":"lane-a","agent_type":"general-purpose","tool_input":{"subagent_type":"workez:implementer","description":"Build T2","model":"sonnet","prompt":"Plan path: /p/specs/login-page/plan.md\nTask id: T2, lane B."}}'
check "Agent: feature from the plan path, task id, agent type, caller agent" '.tool == "Agent" and .feature == "login-page" and .task == "T2"
  and .agent_id == "lane-a" and .detail.subagent_type == "workez:implementer" and .detail.model == "sonnet" and .detail.result == null'
send '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Task","tool_input":{"prompt":"Fix task T3 of /p/specs/login-page/plan-fix.md"}}' >/dev/null
check "Agent: plan-fix.md and the older Task tool name" '.tool == "Task" and .feature == "login-page" and .task == "T3"'
quiet "Agent result" '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Agent","tool_input":{"prompt":"T1 of /p/specs/x/plan.md"},"tool_response":{"content":[{"type":"text","text":"Done.\n  PR_READY /p/.claude/workflow/x/pr-T1.md"}]}}'
check "Agent: a lane result from the tool response" '.hook == "PostToolUse" and .detail.result == "PR_READY /p/.claude/workflow/x/pr-T1.md"'
send '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Agent","tool_input":{},"tool_response":"BLOCKED no issue for T4"}' >/dev/null
check "Agent: a plain string response" '.detail.result == "BLOCKED no issue for T4" and .feature == null and .task == null'

quiet "SubagentStart" '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1","agent_type":"workez:code-reviewer"}'
check "SubagentStart: agent id and type" '.hook == "SubagentStart" and .agent_id == "a1" and .agent_type == "workez:code-reviewer"'
quiet "SubagentStop" '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a1","agent_type":"general-purpose","agent_transcript_path":"/t/a1.jsonl","last_assistant_message":"Review failed.\nFAILED tests do not pass"}'
check "SubagentStop: result and transcript" '.detail.result == "FAILED tests do not pass" and .detail.transcript == "/t/a1.jsonl"'
send '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a2","last_assistant_message":"All good, nothing BLOCKED here."}' >/dev/null
check "SubagentStop: a result word inside a sentence is not a result" '.detail.result == null'

quiet "AskUserQuestion" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Approve the spec?"},{"question":"Other?"}]}}'
check "AskUserQuestion: the first question" '.tool == "AskUserQuestion" and .detail.question == "Approve the spec?"'
quiet "ExitPlanMode" '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}'
check "ExitPlanMode" '.hook == "PostToolUse" and .tool == "ExitPlanMode" and .detail == {}'
quiet "Notification" '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
check "Notification: type and message" '.detail.type == "permission_prompt" and .detail.message == "Claude needs your permission to use Bash"'

quiet "UserPromptSubmit command" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"  /workez:build-feature login-page"}'
check "UserPromptSubmit: a /workez: command" '.skill == "workez:build-feature" and .feature == "login-page" and .detail.command == true'
quiet "UserPromptSubmit text" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"my private words"}'
check "UserPromptSubmit: no command, no skill" '.hook == "UserPromptSubmit" and .skill == null and .detail == {}'
grep -q "private words" "$EV/events-s1.jsonl" && ko "UserPromptSubmit: the prompt text was recorded" || ok "UserPromptSubmit: never records the prompt"

quiet "SessionStart" '{"hook_event_name":"SessionStart","session_id":"s1","source":"resume"}'
check "SessionStart: source" '.detail.source == "resume"'
quiet "SessionEnd" '{"hook_event_name":"SessionEnd","session_id":"s1","reason":"logout"}'
check "SessionEnd: reason" '.detail.reason == "logout"'
quiet "Stop" '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false}'
check "Stop" '.hook == "Stop"'

# --- Every line is valid JSON, under 4 KB, and long texts are cut.
big="$(printf 'x%.0s' {1..5000})"
quiet "long texts" "$(jq -nc --arg b "$big" '{hook_event_name:"PreToolUse",session_id:"s1",tool_name:"Agent",tool_input:{description:$b,prompt:$b}}')"
check "long texts are cut" '(.detail.description | length) == 120'
jq -e -s 'length > 10' "$EV/events-s1.jsonl" >/dev/null && ok "every line is valid JSON" || ko "invalid JSON lines"
awk 'length($0) >= 4000 { bad = 1 } END { exit bad }' "$EV/events-s1.jsonl" && ok "every line is under 4 KB" || ko "a line is 4 KB or more"

# --- Never breaks anything: bad input, odd sessions, no jq, no project, an unwritable folder.
quiet "garbage input" 'not json'
quiet "empty input" ''
quiet "unknown event" '{"hook_event_name":"PreCompact","session_id":"s1"}'
quiet "no session id" '{"hook_event_name":"Stop"}'
send '{"hook_event_name":"Stop","session_id":"../../evil s2"}' >/dev/null
[[ -f "$EV/events-evils2.jsonl" && ! -e "$T/app/.claude/evil s2" ]] && ok "the session id is cleaned for the file name" || ko "session file name: $(ls "$EV")"
r="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s9"}' | PATH=/nonexistent CLAUDE_PROJECT_DIR="$T/app" /bin/bash "$H" 2>&1; echo "|$?")"
[[ "$r" == "|0" && ! -e "$EV/events-s9.jsonl" ]] && ok "silent: without jq" || ko "without jq: $r"
mkdir -p "$T/plain"
r="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s1"}' | (cd "$T/plain" && CLAUDE_PROJECT_DIR="$T/plain" bash "$H" 2>&1); echo "|$?")"
[[ "$r" == "|0" && ! -e "$T/plain/.claude" ]] && ok "no workflow.json: silent, writes nothing" || ko "no project: $r"
if [[ "$(id -u)" != 0 ]]; then
  chmod 500 "$EV"
  quiet "unwritable events folder" '{"hook_event_name":"Stop","session_id":"s1"}'
  chmod 700 "$EV"
fi

# --- From a worktree (no project dir): the events go to the main checkout.
git -C "$T/app" worktree add -q "$T/app/.claude/worktrees/feat-1-x" -b feat/1-x
r="$(PD= send "$(jq -nc --arg d "$T/app/.claude/worktrees/feat-1-x" '{hook_event_name:"SubagentStart",session_id:"s3",agent_id:"w1",cwd:$d}')")"
[[ "$r" == "0|" && -f "$EV/events-s3.jsonl" && ! -e "$T/app/.claude/worktrees/feat-1-x/.claude/workflow" ]] \
  && ok "worktree: written to the main checkout" || ko "worktree: $r"

# --- Turned off: WF_OFFICE, then "office" in workflow.json and workflow.local.json (local wins).
count() { cat "$EV"/events-s4.jsonl 2>/dev/null | wc -l | tr -d ' '; }
ping() { send '{"hook_event_name":"Stop","session_id":"s4"}' >/dev/null; }
for v in off OFF 0 false no; do
  WF_OFFICE=$v ping
done
[[ "$(count)" == 0 ]] && ok "WF_OFFICE=off and friends turn it off" || ko "WF_OFFICE off recorded $(count)"
cp "$T/app/.claude/workflow.json" "$T/w.json"
jq '.office = false' "$T/w.json" >"$T/app/.claude/workflow.json"
ping; [[ "$(count)" == 0 ]] && ok "office false in workflow.json turns it off" || ko "workflow.json office false"
WF_OFFICE=on ping; [[ "$(count)" == 1 ]] && ok "WF_OFFICE=on wins over workflow.json" || ko "WF_OFFICE=on: $(count)"
echo '{"office": true}' >"$T/app/.claude/workflow.local.json"
ping; [[ "$(count)" == 2 ]] && ok "workflow.local.json wins over workflow.json" || ko "local office true: $(count)"
echo '{"office": false}' >"$T/app/.claude/workflow.local.json"
cp "$T/w.json" "$T/app/.claude/workflow.json"
ping; [[ "$(count)" == 2 ]] && ok "office false in workflow.local.json turns it off" || ko "local office false: $(count)"
rm -f "$T/app/.claude/workflow.local.json"

# --- Two lanes at once: parallel appends never mix lines.
for i in $(seq 1 30); do
  send "$(jq -nc --arg i "$i" '{hook_event_name:"SubagentStart",session_id:"s5",agent_id:("p" + $i),agent_type:"workez:implementer"}')" >/dev/null &
done
wait
[[ "$(jq -s 'map(.agent_id) | unique | length' "$EV/events-s5.jsonl" 2>/dev/null)" == 30 ]] \
  && ok "parallel appends: 30 whole lines" || ko "parallel appends: $(wc -l <"$EV/events-s5.jsonl")"

# --- Fast: the average of 20 events stays well under the hook's 5 s timeout (generous for slow CI).
start="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
for i in $(seq 1 20); do send '{"hook_event_name":"SubagentStart","session_id":"s6","agent_id":"t"}' >/dev/null; done
ms=$(( ($(perl -MTime::HiRes=time -e 'printf "%d", time * 1000') - start) / 20 ))
((ms < 150)) && ok "fast: ${ms} ms per event" || ko "slow: ${ms} ms per event"

# --- hooks.json: registered for every event it handles, with a short timeout.
reg="$(jq -r '[.hooks | to_entries[] | .key as $e | .value[] | select(any(.hooks[]; .command | test("office-event.sh")))
  | "\($e):\(.matcher // "*")"] | join(" ")' "$SRC/hooks/hooks.json")"
want="PreToolUse:Skill|Agent|Task|AskUserQuestion|ExitPlanMode PostToolUse:Agent|Task|AskUserQuestion|ExitPlanMode Stop:* Notification:* SubagentStart:* SubagentStop:* UserPromptSubmit:* SessionStart:* SessionEnd:*"
[[ "$reg" == "$want" ]] && ok "hooks.json: registered events" || ko "hooks.json: $reg"
jq -e '[.hooks[][] .hooks[] | select(.command | test("office-event.sh")) | .timeout <= 5] | all' "$SRC/hooks/hooks.json" >/dev/null \
  && ok "hooks.json: timeouts of 5 s at most" || ko "hooks.json timeouts"

done_tests
