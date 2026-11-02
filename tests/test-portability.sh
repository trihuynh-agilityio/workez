#!/usr/bin/env bash
# Portability: a throwaway repository whose project IS the repository root, with a workflow.json
# unlike this project's. Runs the copied scripts and hooks against it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/app"
cd "$T/app"
git config user.email t@example.com; git config user.name test
mkdir -p .claude
cat >.claude/workflow.json <<'EOF'
{
  "github": { "repo": "acme/app", "remote": "origin", "feedback_authors": ["alice"], "review_trigger": "" },
  "branches": { "base": "main", "protected": ["main"], "prefix": "feature/" },
  "docs_dir": "specs",
  "task_limits": { "max_lines": 50, "max_files": 3 },
  "naming": {
    "feature_issue_title": "[Feature] {feature_name}", "task_issue_title": "{task_title}",
    "fix_issue_title": "Fix: {task_title}", "integration_branch": "feature/{feature_issue}-{feature_slug}",
    "task_branch": "feature/{task_issue}-{task_slug}", "task_pr_title": "{task_title}",
    "final_pr_title": "[Feature] {feature_name}", "task_commit": "{task_title}",
    "review_fix_commit": "Review fixes {round}"
  },
  "commands": {
    "install": [{ "dir": ".", "run": "true" }],
    "build": [], "lint": [],
    "format_check": [{ "dir": ".", "run": "! grep -rl --include=*.txt '  ' ." }],
    "test": [{ "dir": ".", "run": "test -f README.txt" }],
    "acceptance": { "dir": ".", "run": "echo '{\"files\": \"{files}\"}' > {output}" }
  },
  "format": [
    { "dir": ".", "match": ["*.txt"], "exclude": ["vendor/*"],
      "write": "perl -pi -e 's/ {2,}/ /g'", "check": "! grep -l '  '" }
  ],
  "lanes": { "A": { "app_port": 5391 } },
  "dev_servers": [{ "name": "web", "dir": ".", "run": "python3 -m http.server {app_port}", "env": { "STATE": "{state_dir}" }, "ready": "http://localhost:{app_port}/" }],
  "app_url": "http://localhost:{app_port}/",
  "dev_url": "http://localhost:8000/",
  "blocked_commands": [{ "pattern": "make[[:space:]]+deploy", "message": "no deploys from Claude." }]
}
EOF
echo hello >README.txt
printf '.claude/worktrees/\nspecs/*/reviews/\nspecs/*/evidence/\n' >.gitignore
git add -A && git commit -q -m init
git remote add origin "$T/remote.git"
git --git-dir="$T/remote.git" fetch -q "$T/app" main:main   # seed the bare remote without a push

# 1. Config library at the repository root.
out="$(bash -c 'source $SRC/scripts/lib/config.sh && echo "[$WF_PREFIX]|$WF_TOP|$(wf_project_in /w)"')"
[[ "$out" == "[]|$T/app|/w" ]] && ok "lib: project at repo root (prefix empty)" || ko "lib: $out"

# 2. commit-feature-doc: branch name from naming, cut from origin/main, docs under specs/.
mkdir -p specs/demo && printf '# Intent: Demo\nStatus: approved.\n' >specs/demo/intent.md
out="$($SRC/scripts/commit-feature-doc.sh demo 7 intent.md 2>&1)"
[[ "$out" == *"BRANCH=feature/7-demo"* ]] && git show -q feature/7-demo:specs/demo/intent.md >/dev/null 2>&1 \
  && ok "commit-feature-doc: feature/7-demo with specs/demo/intent.md" || ko "commit-feature-doc: $out"
git --git-dir="$T/remote.git" fetch -q "$T/app" feature/7-demo:feature/7-demo

# 3. build-position on a plan in specs/.
cat >specs/demo/plan.md <<'EOF'
# Plan: Demo
Status: approved.

## Wave 0

## T1: Write the notes  [ ]
- **Lane**: solo
- **Files**: `notes.txt`
- **Issue**: #8
- **Branch**: `feature/8-notes`
- **PR target**: `feature/7-demo`

## Wave 1

## T2: Integration  [ ]
- **Lane**: solo
- **Files**: none
- **Issue**: #9
- **Branch**: `feature/9-integration` (only if fixes are needed)
- **PR target**: `feature/7-demo`

## Risks
EOF
: >"$T/states.tsv"
out="$(bash $SRC/scripts/build-position.sh specs/demo/plan.md "$T/states.tsv" | tail -2 | tr '\n' ' ')"
[[ "$out" == "ACTION=start TASKS=T1 " ]] && ok "build-position: start T1" || ko "build-position: $out"
echo "feature/8-notes MERGED 10" >"$T/states.tsv"
out="$(bash $SRC/scripts/build-position.sh specs/demo/plan.md "$T/states.tsv" | tail -2 | tr '\n' ' ')"
[[ "$out" == "ACTION=integrate TASKS=T2 " ]] && ok "build-position: integrate T2" || ko "build-position: $out"

# 4. A task worktree: format hook, then check-task (format, size, files).
WT="$(bash -c 'source $SRC/scripts/lib/config.sh && wf_worktree_path feature/8-notes')"
git worktree add -q -b feature/8-notes "$WT" feature/7-demo
printf 'a  b   c\n' >"$WT/notes.txt"
jq -n --arg f "$WT/notes.txt" '{tool_input:{file_path:$f}}' | bash $SRC/hooks/format-on-edit.sh
[[ "$(cat "$WT/notes.txt")" == "a b c" ]] && ok "format hook: worktree file formatted" || ko "format hook: '$(cat "$WT/notes.txt")'"
mkdir -p "$WT/vendor" && printf 'x  y\n' >"$WT/vendor/v.txt"
jq -n --arg f "$WT/vendor/v.txt" '{tool_input:{file_path:$f}}' | bash $SRC/hooks/format-on-edit.sh
[[ "$(cat "$WT/vendor/v.txt")" == "x  y" ]] && ok "format hook: excluded path left alone" || ko "format hook: exclude"
rm -rf "$WT/vendor"

(cd "$WT" && "$SRC/scripts/check-task.sh" T1 "$T/app/specs/demo/plan.md" >/dev/null 2>&1) \
  && ok "check-task: clean task passes" || ko "check-task: clean task"
printf 'p  q\n' >"$WT/notes.txt"
out="$(cd "$WT" && "$SRC/scripts/check-task.sh" T1 "$T/app/specs/demo/plan.md" 2>&1)"
[[ "$out" == *"not formatted"*"notes.txt"* ]] && ok "check-task: format rule from config" || ko "check-task format: $out"
seq 1 60 >"$WT/notes.txt"
out="$(cd "$WT" && "$SRC/scripts/check-task.sh" T1 "$T/app/specs/demo/plan.md" 2>&1)"
[[ "$out" == *"limit is under 50"* ]] && ok "check-task: max_lines from config" || ko "check-task limit: $out"
echo x >"$WT/other.txt"
out="$(cd "$WT" && "$SRC/scripts/check-task.sh" T1 "$T/app/specs/demo/plan.md" 2>&1)"
[[ "$out" == *"other.txt is not in the Files list"* ]] && ok "check-task: Files list" || ko "check-task files: $out"
rm "$WT/other.txt"; echo ok >"$WT/notes.txt"

# 5. Dev servers of lane A.
out="$(bash $SRC/scripts/dev-servers.sh start A "$WT" 2>&1)"
if [[ "$out" == *"APP_URL=http://localhost:5391/"* ]] && curl -sf http://localhost:5391/ >/dev/null; then
  ok "dev-servers: lane A up at its app_url"
else ko "dev-servers: $out"; fi
bash $SRC/scripts/dev-servers.sh stop A >/dev/null
lsof -ti :5391 -sTCP:LISTEN >/dev/null && ko "dev-servers: port still busy" || ok "dev-servers: stopped"

# 6. Blocking hooks with this config.
h() { jq -n --arg c "$1" --arg d "$T/app" '{tool_input:{command:$c},cwd:$d}' | bash "$SRC/hooks/$2" >/dev/null 2>&1; echo $?; }
[[ "$(h 'make deploy' block-forbidden-command.sh)" == 2 ]] && ok "hook: project rule from blocked_commands" || ko "hook: blocked_commands"
[[ "$(h 'pip install x' block-forbidden-command.sh)" == 0 ]] && ok "hook: the source project rules not applied" || ko "hook: foreign rule"
[[ "$(h 'git push origin main' block-forbidden-command.sh)" == 2 ]] && ok "hook: protected branch main" || ko "hook: protected"
[[ "$(h 'git push origin feature/8-notes' block-push-protected.sh)" == 0 ]] && ok "push hook: feature branch allowed" || ko "push hook: allowed"
[[ "$(h 'git push origin HEAD:main' block-push-protected.sh)" == 2 ]] && ok "push hook: protected main blocked" || ko "push hook: main"
[[ "$(h 'git push origin dev' block-push-protected.sh)" == 0 ]] && ok "push hook: dev not protected here, allowed" || ko "push hook: dev"

# 7. Verify worktree and checks.
git -C "$WT" add notes.txt && git -C "$WT" commit -q -m notes
git branch -q -f feature/7-demo feature/8-notes
git --git-dir="$T/remote.git" fetch -q "$T/app" +feature/7-demo:feature/7-demo
echo more >>README.txt && git commit -qam "main moved"
git --git-dir="$T/remote.git" fetch -q "$T/app" main:main
out="$(bash $SRC/scripts/verify-worktree.sh create demo feature/7-demo 2>&1)"
proj="$(sed -n 's/^PROJECT=//p' <<<"$out")"
[[ "$out" == *"MERGED=yes"* && "$proj" == "$T/app/.claude/worktrees/verify-demo" ]] \
  && ok "verify-worktree: merged origin/main, PROJECT at worktree root" || ko "verify-worktree: $out"
bash $SRC/scripts/verify-checks.sh "$proj" "$T/logs" a.test b.test >/dev/null 2>&1; code=$?
steps="$(cut -f1,2 "$T/logs/checks.tsv" | tr '\t\n' '= ')"
[[ $code == 0 && "$steps" == "install=0 format-check=0 test=0 acceptance=0 " ]] && grep -q 'a.test b.test' "$T/logs/acceptance.json" \
  && ok "verify-checks: steps from config ($steps)" || ko "verify-checks: code=$code $steps"
bash $SRC/scripts/verify-worktree.sh remove demo >/dev/null
[[ ! -d "$proj" ]] && ok "verify-worktree: removed" || ko "verify-worktree: remove"

git worktree remove --force "$WT"
done_tests
