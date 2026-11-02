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

done_tests
