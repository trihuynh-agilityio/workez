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
n=notify-on-finish.sh
notify() { WF_NOTIFY_DRY_RUN=1 bash "$SRC/hooks/$n"; }
out="$(jq -n --arg d "$T/app" '{cwd:$d, last_assistant_message:"## Done\n\n- Added **login** to [auth.ts](src/auth.ts)\n```\nnpm test\n```\n- Tests `pass`"}' | notify)"
[[ "$out" == $'app\ndev\nDone Added login to auth.ts Tests pass' ]] && ok "$n: summarizes last_assistant_message" || ko "$n: $out"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
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

done_tests
