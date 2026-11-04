#!/usr/bin/env bash
# The Bash guard hooks: generic rules, blocked_commands and protected branches from a test config.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b dev "$T/app"; mkdir -p "$T/app/.claude"
jq '.branches.protected = ["dev", "main", "release"]
  | .blocked_commands = [{"pattern": "make[[:space:]]+deploy", "message": "no deploys."}]' \
  "$SRC/templates/workflow.example.json" >"$T/app/.claude/workflow.json"
# expect <exit code> <hook> <command>
expect() {
  local code
  jq -n --arg c "$3" --arg d "$T/app" '{tool_input:{command:$c},cwd:$d}' | bash "$SRC/hooks/$2" >/dev/null 2>&1
  code=$?
  [[ "$code" == "$1" ]] && ok "$2: $3 -> $1" || ko "$2: $3 -> $code, expected $1"
}

f=block-forbidden-command.sh
expect 2 $f "git push -f origin feat/1-x"
expect 2 $f "git push --force-with-lease origin feat/1-x"
expect 2 $f "git reset --hard HEAD"
expect 2 $f "git clean -fd"
expect 2 $f "rm -rf /"
expect 2 $f "make deploy"
expect 0 $f "make test"
expect 0 $f "git status"
# The checkout is on dev (protected): pushing another branch is fine, merging here is not.
expect 0 $f "git push -u origin feat/15-remove-note"
expect 0 $f "cd .claude/worktrees/feat-1-x && git push -u origin feat/1-x"
expect 2 $f "git push origin dev"
expect 2 $f "git merge feat/1-x"

p=block-push-protected.sh
expect 0 $p "git push origin feat/1-x"
expect 0 $p "git push -u origin HEAD:chore/tidy"
expect 2 $p "git push origin dev"
expect 2 $p "git push origin HEAD:refs/heads/release"
expect 2 $p "git push origin feat/1-x main"
expect 2 $p "git push --all origin"
expect 2 $p "git push origin"            # the current branch is dev
expect 0 $p "git log --grep 'git push origin dev'"

# notify-on-finish.sh, dry run: title, branch, then the last reply as one plain line.
# It notifies only for a session whose transcript ran a workez skill: $T/wz.jsonl has one.
n=notify-on-finish.sh
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"workez:build-task"}}]}}' >"$T/wz.jsonl"
notify() { jq --arg t "${TR:-$T/wz.jsonl}" '.transcript_path //= $t' | bash "$SRC/hooks/$n"; }
out="$(jq -n --arg d "$T/app" '{cwd:$d, last_assistant_message:"## Done\n\n- Added **login** to [auth.ts](src/auth.ts)\n```\nnpm test\n```\n- Tests `pass`"}' | notify)"
[[ "$out" == $'app: finished\ndev\nDone Added login to auth.ts Tests pass' ]] && ok "$n: summarizes last_assistant_message" || ko "$n: $out"
printf '%s\n' '{"type":"user","message":{"content":"<command-name>/workez:plan-feature</command-name>"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the \"save\" bug."},{"type":"tool_use","name":"Bash"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}' >"$T/transcript.jsonl"
out="$(jq -n --arg d "$T/app" --arg t "$T/transcript.jsonl" '{cwd:$d, transcript_path:$t}' | notify)"
[[ "$(tail -n 1 <<<"$out")" == 'Fixed the "save" bug.' ]] && ok "$n: falls back to the transcript" || ko "$n: $out"
out="$(jq -n --arg d "$T/app" '{cwd:$d}' | notify)"
[[ "$(tail -n 1 <<<"$out")" == "Claude finished responding" ]] && ok "$n: generic line without a reply" || ko "$n: $out"
long="$(printf 'x%.0s' {1..300})"
out="$(jq -n --arg d "$T/app" --arg m "$long" '{cwd:$d, last_assistant_message:$m}' | notify | tail -n 1)"
[[ "$(jq -Rr length <<<"$out")" == 220 && "$out" == *… ]] && ok "$n: cuts long replies" || ko "$n: $out"
out="$(jq -n --arg d "$T/app" --arg m "$(printf 'Đã xong %.0s' {1..60})" '{cwd:$d, last_assistant_message:$m}' | notify | tail -n 1)"
jq -Rre 'length == 220' <<<"$out" >/dev/null && ok "$n: cuts by characters, not bytes" || ko "$n: $out"
out="$(jq -n --arg d "$T/app" '{cwd:$d, hook_event_name:"Notification", notification_type:"permission_prompt",
  message:"Claude needs your permission to use Bash"}' | notify)"
[[ "$out" == $'app: needs your approval\ndev\nClaude needs your permission to use Bash' ]] && ok "$n: permission prompt" || ko "$n: $out"
out="$(jq -n --arg d "$T/app" '{cwd:$d, hook_event_name:"PreToolUse", tool_name:"AskUserQuestion",
  tool_input:{questions:[{question:"Approve the plan?"},{question:"Other?"}]}}' | notify)"
[[ "$out" == $'app: needs your answer\ndev\nApprove the plan?' ]] && ok "$n: AskUserQuestion" || ko "$n: $out"
out="$(jq -n --arg d "$T/app" '{cwd:$d, hook_event_name:"PreToolUse", tool_name:"ExitPlanMode"}' | notify | head -n 1)"
[[ "$out" == "app: needs your approval" ]] && ok "$n: ExitPlanMode" || ko "$n: $out"
# Sessions that never ran a workez skill stay quiet.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"other:workez-like"}}]}}' >"$T/plain.jsonl"
out="$(jq -n --arg d "$T/app" '{cwd:$d, last_assistant_message:"hi"}' | TR="$T/plain.jsonl" notify)"
[[ -z "$out" ]] && ok "$n: quiet for a session without a workez skill" || ko "$n: no-workez session notified: $out"
out="$(jq -n --arg d "$T/app" '{cwd:$d, last_assistant_message:"hi"}' | TR="$T/missing.jsonl" notify)"
[[ -z "$out" ]] && ok "$n: quiet without a transcript" || ko "$n: no transcript notified: $out"
for v in off OFF 0 false no; do
  out="$(jq -n --arg d "$T/app" '{cwd:$d, last_assistant_message:"hi"}' | WF_NOTIFY=$v notify)"
  [[ -z "$out" ]] && ok "$n: WF_NOTIFY=$v turns it off" || ko "$n: WF_NOTIFY=$v notified: $out"
done
[[ -n "$(jq -n --arg d "$T/app" '{cwd:$d}' | WF_NOTIFY=on notify)" ]] && ok "$n: WF_NOTIFY=on notifies" || ko "$n: WF_NOTIFY=on"
# "notify": workflow.local.json wins over workflow.json, WF_NOTIFY over both.
said() { [[ -n "$(jq -n --arg d "$T/app" '{cwd:$d}' | notify)" ]] && echo on || echo off; }
cp "$T/app/.claude/workflow.json" "$T/w.json"
jq '.notify = false' "$T/w.json" >"$T/app/.claude/workflow.json"
[[ "$(said)" == off ]] && ok "$n: notify false in workflow.json turns it off" || ko "$n: workflow.json notify false"
echo '{"notify": true}' >"$T/app/.claude/workflow.local.json"
[[ "$(said)" == on ]] && ok "$n: workflow.local.json overrides workflow.json" || ko "$n: local true over team false"
cp "$T/w.json" "$T/app/.claude/workflow.json"; echo '{"notify": false}' >"$T/app/.claude/workflow.local.json"
[[ "$(said)" == off ]] && ok "$n: notify false in workflow.local.json turns it off" || ko "$n: local notify false"
[[ "$(WF_NOTIFY=on said)" == on ]] && ok "$n: WF_NOTIFY overrides workflow.local.json" || ko "$n: WF_NOTIFY over local"
rm "$T/app/.claude/workflow.local.json"
# The cooldown: one notification per session within WF_NOTIFY_COOLDOWN seconds; other sessions are apart.
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
ask() { jq -n --arg d "$T/app" --arg s "$1" '{cwd:$d, session_id:$s, hook_event_name:"PreToolUse", tool_name:"AskUserQuestion",
  tool_input:{questions:[{question:"Q?"}]}}' | notify | head -n 1; }
[[ "$(ask s1)" == "app: needs your answer" ]] && ok "$n: first notification of a session" || ko "$n: cooldown first"
out="$(jq -n --arg d "$T/app" '{cwd:$d, session_id:"s1", hook_event_name:"Notification", message:"perm"}' | notify)"
[[ -z "$out" ]] && ok "$n: a second event of the same wait is dropped" || ko "$n: cooldown repeat: $out"
[[ "$(ask s2)" == "app: needs your answer" ]] && ok "$n: another session still notifies" || ko "$n: cooldown other session"
[[ "$(WF_NOTIFY_COOLDOWN=0 ask s1)" == "app: needs your answer" ]] && ok "$n: notifies again after the cooldown" || ko "$n: cooldown expiry"

done_tests
