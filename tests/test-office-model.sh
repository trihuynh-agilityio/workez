#!/usr/bin/env bash
# The office board model: its Node unit tests, then the real hook and the real loader together (events
# written by office-event.sh, a state.json and a plan, read back by office/snapshot.js).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || { ko "node is required (Node 18 or newer)"; done_tests; exit; }
out="$(node --test "$SRC"/office/test/*.test.js 2>&1)"
[[ $? == 0 ]] && ok "office model unit tests ($(grep -E '^# pass' <<<"$out" | tr -d '#' | xargs))" \
  || { ko "office model unit tests"; grep -E '^not ok|AssertionError|actual|expected' <<<"$out" | head -20; }

# A project with a feature in build: plan, state, and the events of one lane.
git init -q -b main "$T/app"; mkdir -p "$T/app/.claude/workflow/login" "$T/app/specs/login"
cp "$SRC/templates/workflow.example.json" "$T/app/.claude/workflow.json"
docs="$(jq -r '.docs_dir' "$T/app/.claude/workflow.json")"; mkdir -p "$T/app/$docs/login"
printf '%s\n' '# Plan: login' 'Status: approved.' '## Wave 1' '## T1: Login form' '- **Lane**: A' '- **Issue**: #11' \
  '## T2: Session API' '- **Lane**: B' '- **Issue**: #12' >"$T/app/$docs/login/plan.md"
echo '{"feature":"login","phase":"build","status":"in_progress","handed_off":true,"wave":1,"tasks":{"T1":{"status":"todo"},"T2":{"status":"waiting","pr":32}}}' \
  >"$T/app/.claude/workflow/login/state.json"
hook() { CLAUDE_PROJECT_DIR="$T/app" bash "$SRC/hooks/office-event.sh"; }
plan="$T/app/$docs/login/plan.md"
jq -nc '{hook_event_name:"PreToolUse",session_id:"s1",tool_name:"Skill",tool_input:{skill:"workez:build-feature",args:"login"}}' | hook
jq -nc --arg p "$plan" '{hook_event_name:"PreToolUse",session_id:"s1",tool_name:"Agent",tool_input:{prompt:("Plan " + $p + ", task T1, lane A")}}' | hook
jq -nc '{hook_event_name:"SubagentStart",session_id:"s1",agent_id:"laneA",agent_type:"general-purpose"}' | hook
jq -nc --arg p "$plan" '{hook_event_name:"PreToolUse",session_id:"s1",agent_id:"laneA",agent_type:"general-purpose",tool_name:"Agent",
  tool_input:{subagent_type:"workez:code-reviewer",prompt:("Review " + $p + " T1")}}' | hook
jq -nc '{hook_event_name:"SubagentStart",session_id:"s1",agent_id:"rev1",agent_type:"workez:code-reviewer"}' | hook

s="$(cd "$T/app/$docs" && node "$SRC/office/snapshot.js" --json)"
t1() { jq -r --arg k "$1" '.features[] | select(.name == "login") | .tasks[] | select(.id == "T1") | .[$k] | tostring' <<<"$s"; }
[[ "$(t1 column)" == review && "$(t1 status)" == working && "$(t1 title)" == "Login form" ]] \
  && ok "hook + loader: T1 is in Review" || ko "T1: $(jq -c '.features[0].tasks[0]' <<<"$s")"
[[ "$(jq -r '.features[0].tasks[0].agent | "\(.type) \(.model)"' <<<"$s")" == "code-reviewer opus" ]] \
  && ok "hook + loader: the agent badge with its model from agents/*.md" || ko "agent: $(jq -c '.features[0].tasks[0].agent' <<<"$s")"
[[ "$(jq -r '.waiting[0] | "\(.task) \(.reason)"' <<<"$s")" == "T2 review and merge PR #32" ]] \
  && ok "hook + loader: T2 waits on you for its PR" || ko "waiting: $(jq -c .waiting <<<"$s")"

text="$(node "$SRC/office/snapshot.js" --project "$T/app")"
grep -q "Waiting on you: login T2 (review and merge PR #32)" <<<"$text" && ok "snapshot: text output" || ko "text: $text"
mkdir -p "$T/plain"
(cd "$T/plain" && node "$SRC/office/snapshot.js" >/dev/null 2>&1); [[ $? == 2 ]] && ok "snapshot: no project -> exit 2" || ko "no project"

# A project override: .claude/office.json regroups the columns.
echo '{"columns":[{"id":"build","title":"Build","steps":["todo","implement","review","ui_check"]},{"id":"pr","title":"PR","steps":["pr_open"]}]}' \
  >"$T/app/.claude/office.json"
s="$(node "$SRC/office/snapshot.js" --project "$T/app" --json)"
[[ "$(t1 column)" == build && "$(jq -r '[.columns[].id] | join(",")' <<<"$s")" == "build,pr" ]] \
  && ok "office.json: columns from the project" || ko "office.json: $(jq -c .columns <<<"$s")"

done_tests
