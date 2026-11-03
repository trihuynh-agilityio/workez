#!/usr/bin/env bash
# Prepares a project for the workez plugin, from its .claude/workflow.json:
#   - merges the workflow's permission rules into .claude/settings.json (permissions cannot read
#     workflow.json, so they are written out per project: gh api paths, remote, branch prefixes,
#     protected branches, the project's commands, the plugin scripts and Playwright servers),
#   - adds the workflow's runtime folders to .gitignore.
# Run it from inside the project. Re-running is safe: rules and lines already there are kept once.
#   setup-project.sh [--dry-run]     (--dry-run prints the result and writes nothing)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1

repo="$(cfg .github.repo)"; remote="$(cfg .github.remote)"
docs="$(cfg .docs_dir)"
prefixes="$(wf_branch_prefixes | jq -R . | jq -s 'map(select(. != ""))')"
[[ -n "$repo" && -n "$remote" && -n "$docs" && "$prefixes" != "[]" ]] \
  || { echo "setup-project: workflow.json needs github.repo, github.remote, docs_dir and conventions.commit_types or branches.prefix" >&2; exit 2; }

plugin="$(jq -r .name "$WF_HOME/.claude-plugin/plugin.json")"
allow="$(jq -n --arg repo "$repo" --arg remote "$remote" --argjson prefixes "$prefixes" --arg docs "$docs" \
  --arg plugin "$plugin" --argjson cmds "$(jq '[.commands | to_entries[] | select(.key != "acceptance") | .value[]?.run] | unique' "$WF_CONFIG")" '
  [ "Bash(gh issue create *)", "Bash(gh issue list *)", "Bash(gh issue view *)", "Bash(gh issue comment *)",
    "Bash(gh issue edit *)", "Bash(gh issue close *)", "Bash(gh label create *)", "Bash(gh label list *)",
    "Bash(gh pr create *)", "Bash(gh pr list *)", "Bash(gh pr view *)", "Bash(gh pr edit *)",
    "Bash(gh api repos/\($repo)/issues/*)", "Bash(gh api repos/\($repo)/pulls/*)",
    "Bash(gh api repos/\($repo)/actions/jobs/*)",
    "Bash(git status*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git show *)", "Bash(git branch*)",
    "Bash(git rev-parse *)", "Bash(git merge-base *)", "Bash(git ls-remote *)", "Bash(git worktree *)",
    "Bash(git add *)", "Bash(git commit *)", "Bash(git fetch \($remote)*)",
    "Bash(*\($plugin)*/scripts/*.sh*)",
    "Edit(.claude/workflow/**)", "Edit(\($docs)/*/evidence/**)", "Edit(\($docs)/*/reviews/**)",
    "Edit(\($docs)/*/plan.md)", "Edit(\($docs)/*/plan-fix.md)",
    "mcp__plugin_\($plugin)_playwright-a", "mcp__plugin_\($plugin)_playwright-b",
    "CronCreate", "CronList", "CronDelete" ]
  + [ $prefixes[] as $p | "Bash(git push -u \($remote) \($p)*)", "Bash(git push \($remote) \($p)*)" ]
  + [ $cmds[] | "Bash(\(.)*)" ]')"
deny="$(jq -n --arg plugin "$plugin" --argjson prot "$(jq '.branches.protected // []' "$WF_CONFIG")" '
  [ "Bash(git merge)", "Bash(git merge *)", "Bash(gh pr merge)", "Bash(gh pr merge *)",
    "Bash(git push --force*)", "Bash(git push * --force*)", "Bash(git push -f)", "Bash(git push -f *)",
    "Bash(git push * -f)", "Bash(git push * -f *)", "Bash(gh pr review)", "Bash(gh pr review *)" ]
  + [ $prot[] as $b | "Bash(git push * \($b))", "Bash(git push * +\($b))", "Bash(git push * *:\($b))",
      "Bash(git push * *:refs/heads/\($b))", "Bash(git push * refs/heads/\($b))" ]
  + [ "a", "b" | "mcp__plugin_\($plugin)_playwright-\(.)__browser_run_code_unsafe",
      "mcp__plugin_\($plugin)_playwright-\(.)__browser_file_upload" ]')"

settings="$WF_PROJECT/.claude/settings.json"
current="{}"; [[ -f "$settings" ]] && current="$(cat "$settings")"
merged="$(jq --argjson a "$allow" --argjson d "$deny" '
  .permissions.allow = (((.permissions.allow // []) + $a) | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end))
  | .permissions.deny = (((.permissions.deny // []) + $d) | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end))' <<<"$current")"

ignore="$WF_PROJECT/.gitignore"
lines=(".claude/workflow/" ".claude/worktrees/" "$docs/*/reviews/" "$docs/*/evidence/")
missing=()
for l in "${lines[@]}"; do grep -qxF -- "$l" "$ignore" 2>/dev/null || missing+=("$l"); done

if ((dry)); then
  echo "== $settings"; echo "$merged"
  echo "== $ignore (lines to add)"; printf '%s\n' "${missing[@]+"${missing[@]}"}"
  exit 0
fi
printf '%s\n' "$merged" >"$settings"
echo "UPDATED $settings"
if ((${#missing[@]})); then
  { [[ -s "$ignore" && -n "$(tail -c1 "$ignore")" ]] && echo; echo "# workez runtime data"; printf '%s\n' "${missing[@]}"; } >>"$ignore"
  echo "UPDATED $ignore"
fi
