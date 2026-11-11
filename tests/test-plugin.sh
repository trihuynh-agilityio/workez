#!/usr/bin/env bash
# Plugin behaviour: project discovery (subfolder, worktree, WF_PROJECT), hooks that stay silent in a
# project without .claude/workflow.json, setup-project.sh and doctor.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A repository whose project lives in a subfolder, like a monorepo; no conventions, branches.prefix only.
git init -q -b main "$T/repo"; mkdir -p "$T/repo/web/.claude" "$T/repo/web/src"
jq '.github.repo = "acme/web" | .github.remote = "origin" | .branches.base = "main"
  | .branches.protected = ["main"] | del(.conventions) | .branches.prefix = "feature/" | .docs_dir = "specs"
  | .naming.integration_branch = "feature/{feature_issue}-{feature_slug}" | .naming.task_branch = "feature/{task_issue}-{task_slug}"' \
  "$SRC/templates/workflow.example.json" >"$T/repo/web/.claude/workflow.json"
echo x >"$T/repo/web/src/a.txt"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m init
P="$T/repo/web"

where() { (cd "$1" && bash -c 'source "$SRC/scripts/lib/config.sh" && echo "$WF_PROJECT|$WF_PREFIX"'); }
[[ "$(where "$P/src")" == "$P|web/" ]] && ok "discovery: from a subfolder of the project" || ko "subfolder: $(where "$P/src")"
git -C "$T/repo" worktree add -q "$T/repo/.claude/worktrees/feature-1-x" -b feature/1-x
[[ "$(where "$T/repo/.claude/worktrees/feature-1-x/web/src")" == "$P|web/" ]] \
  && ok "discovery: a worktree maps to the main checkout" || ko "worktree: $(where "$T/repo/.claude/worktrees/feature-1-x/web/src")"
out="$(cd "$T" && WF_PROJECT="$P" bash -c 'source "$SRC/scripts/lib/config.sh" && echo "$WF_PROJECT"')"
[[ "$out" == "$P" ]] && ok "discovery: WF_PROJECT from outside" || ko "WF_PROJECT: $out"
(cd "$T" && bash -c 'source "$SRC/scripts/lib/config.sh"' 2>/dev/null); [[ $? == 2 ]] && ok "discovery: no project -> exit 2" || ko "no project"

# Hooks in a project that does not use the workflow: nothing blocked, nothing written.
git init -q -b main "$T/other"
h() { jq -n --arg c "$1" --arg d "$T/other" '{tool_input:{command:$c},cwd:$d}' | (cd "$T/other" && CLAUDE_PROJECT_DIR= bash "$SRC/hooks/$2") >/dev/null 2>&1; echo $?; }
[[ "$(h "git push origin main" block-push-protected.sh)" == 0 && "$(h "git reset --hard" block-forbidden-command.sh)" == 0 ]] \
  && ok "hooks: silent without workflow.json" || ko "hooks not silent"
out="$(echo '{"stop_hook_active": false}' | (cd "$T/other" && bash "$SRC/hooks/next-phase.sh"))"
[[ -z "$out" && ! -e "$T/other/.claude" ]] && ok "next-phase: silent, writes nothing without workflow.json" || ko "next-phase: $out"
out="$(jq -n --arg d "$T/other" '{session_id:"s1", tool_name:"Skill", tool_input:{skill:"workez:design-feature", args:"x"}, cwd:$d}' \
  | (cd "$T/other" && CLAUDE_PROJECT_DIR= bash "$SRC/hooks/claim-feature.sh"))"
[[ -z "$out" && ! -e "$T/other/.claude" ]] && ok "claim-feature: silent, writes nothing without workflow.json" || ko "claim-feature: $out"
out="$(jq -n --arg c "git push origin main" --arg d "$P/src" '{tool_input:{command:$c},cwd:$d}' | bash "$SRC/hooks/block-push-protected.sh" 2>&1)"; rc=$?
[[ $rc == 2 ]] && ok "hooks: active from the hook's cwd inside the project" || ko "hook cwd: $rc $out"

# setup-project.sh: permissions from the config, merged once; .gitignore lines added once.
mkdir -p "$P/.claude"; echo '{"permissions":{"allow":["Bash(ls *)"]},"model":"opus"}' >"$P/.claude/settings.json"
(cd "$P" && bash "$SRC/scripts/setup-project.sh" >/dev/null && bash "$SRC/scripts/setup-project.sh" >/dev/null)
s="$P/.claude/settings.json"
jq -e '.model == "opus" and (.permissions.allow | index("Bash(ls *)"))' "$s" >/dev/null && ok "setup: keeps existing settings" || ko "setup: lost settings"
jq -e '.permissions.allow | (index("Bash(gh api repos/acme/web/issues/*)") and index("Bash(git push origin feature/*)")
  and index("Bash(npm test*)") and index("mcp__plugin_workez_playwright-a"))' "$s" >/dev/null \
  && ok "setup: allow rules from the config" || ko "setup allow: $(jq -c .permissions.allow "$s")"
jq -e '.permissions.deny | (index("Bash(git push * main)") and (map(select(. == "Bash(gh pr merge *)")) | length == 1))' "$s" >/dev/null \
  && ok "setup: deny rules, no duplicates on re-run" || ko "setup deny: $(jq -c .permissions.deny "$s")"
[[ "$(grep -cxF '.claude/workflow/' "$P/.gitignore")" == 1 && "$(grep -cxF 'specs/*/evidence/' "$P/.gitignore")" == 1 \
  && "$(grep -cxF '.claude/workflow.local.json' "$P/.gitignore")" == 1 ]] \
  && ok "setup: .gitignore lines added once" || ko "setup gitignore: $(cat "$P/.gitignore")"

# doctor.sh: read-only checks of the config, the setup and the remote.
git -C "$T/repo" remote add origin "$T/none.git"
doc() { (cd "$P" && bash "$SRC/scripts/doctor.sh" --offline 2>&1); }
out="$(doc)"
for line in "OK    workflow.json keys" "OK    branch naming" "OK    lanes" "OK    permissions" "OK    .gitignore" "OK    git remote"; do
  [[ "$out" == *"$line"* ]] && ok "doctor: ${line#OK    }" || ko "doctor: no '$line' in: $out"
done
[[ "$out" == *"FAIL  command folders"*"frontend"* ]] && ok "doctor: missing command folders fail" || ko "doctor folders: $out"
# workflow.local.json: personal keys only, true/false, never committed.
echo '{"notify": false}' >"$P/.claude/workflow.local.json"
out="$(doc)"
[[ "$out" == *'OK    workflow.local.json      {"notify":false}'* ]] && ok "doctor: workflow.local.json with personal keys" || ko "doctor local ok: $out"
echo '{"notify": "no", "branches": {"protected": []}}' >"$P/.claude/workflow.local.json"
out="$(doc)"
[[ "$out" == *"WARN  workflow.local.json"*"ignored keys: branches"* && "$out" == *"WARN  notify"*workflow.local.json* ]] \
  && ok "doctor: warns about team keys and a non-boolean notify" || ko "doctor local warn: $out"
git -C "$T/repo" add -f "$P/.claude/workflow.local.json"
[[ "$(doc)" == *"WARN  workflow.local.json"*"is committed"* ]] && ok "doctor: warns when workflow.local.json is tracked" || ko "doctor local tracked"
git -C "$T/repo" rm -q --cached "$P/.claude/workflow.local.json"; rm "$P/.claude/workflow.local.json"
cp "$P/.claude/workflow.json" "$T/w.json"
jq '.naming.task_branch = "task/{task_slug}" | .lanes.C = {"x": 1} | del(.github.repo)' "$T/w.json" >"$P/.claude/workflow.json"
out="$(doc)"; rc=$?
[[ $rc == 1 && "$out" == *"FAIL  branch naming"*task_branch* && "$out" == *"FAIL  lanes"* && "$out" == *"missing: github.repo"* ]] \
  && ok "doctor: bad config fails (prefix, lanes, missing key)" || ko "doctor bad config: $rc $out"
cp "$T/w.json" "$P/.claude/workflow.json"
mkdir -p "$P/.claude/hooks" && touch "$P/.claude/hooks/next-phase.sh"
[[ "$(doc)" == *"WARN  duplicate copy"* ]] && ok "doctor: warns about a duplicate copy in the project" || ko "doctor duplicate copy"
out="$(cd "$T/other" && bash "$SRC/scripts/doctor.sh" --offline 2>&1)"; rc=$?
[[ $rc == 1 && "$out" == *"FAIL  workflow.json"*"/workez:setup"* ]] && ok "doctor: no workflow.json fails with a hint" || ko "doctor no config: $rc $out"

# Local tracker: no github block, no remote, no gh.
git init -q -b dev "$T/loc"; mkdir -p "$T/loc/.claude"
jq 'del(.github) | .tracker = "local" | .remote = "" | .naming.integration_branch = "feat/{feature_slug}"
  | .naming.task_branch = "{task_type}/{feature_slug}-{task_slug}" | .naming.task_pr_title = "{task_type}{task_scope}: {task_title}"
  | .commands = {"install": [{"dir": ".", "run": "true"}], "test": [{"dir": ".", "run": "true"}], "acceptance": {"dir": ".", "run": "true"}}
  | .format = [] | .dev_servers = []' "$SRC/templates/workflow.example.json" >"$T/loc/.claude/workflow.json"
git -C "$T/loc" commit -q --allow-empty -m init
(cd "$T/loc" && bash "$SRC/scripts/setup-project.sh" >/dev/null) && s="$T/loc/.claude/settings.json" \
  && jq -e '(.permissions.allow | map(select(startswith("Bash(gh ") or startswith("Bash(git push") or startswith("Bash(git fetch"))) | length == 0)
    and (.permissions.deny | index("Bash(git merge *)"))' "$s" >/dev/null \
  && ok "setup local: no gh, push or fetch rules without a remote; deny rules kept" || ko "setup local: $(jq -c .permissions "$T/loc/.claude/settings.json" 2>&1)"
mkdir -p "$T/nogh" && for t in git jq curl lsof node npx bash; do p="$(command -v $t)" && ln -sf "$p" "$T/nogh/$t"; done
for t in awk sed grep tr sort uniq head cut dirname basename cat wc date mktemp env; do p="$(command -v $t)" && ln -sf "$p" "$T/nogh/$t"; done
out="$(cd "$T/loc" && PATH="$T/nogh" bash "$SRC/scripts/doctor.sh" 2>&1)"
[[ "$out" == *"OK    tracker"*"local"* && "$out" == *"OK    gh"*"not needed"* && "$out" == *"OK    workflow.json keys"* \
  && "$out" == *"OK    local naming"* && "$out" == *"OK    git remote"*"none"* && "$out" == *"OK    base branch"*"dev (local)"* \
  && "$out" != *"FAIL  gh"* && "$out" != *"gh auth"* ]] \
  && ok "doctor local: no gh, no github keys, no remote" || ko "doctor local: $out"
jq '.naming.task_branch = "{task_type}/{task_issue}-{task_slug}"' "$T/loc/.claude/workflow.json" >"$T/l.json" && cp "$T/l.json" "$T/loc/.claude/workflow.json"
[[ "$(cd "$T/loc" && bash "$SRC/scripts/doctor.sh" 2>&1)" == *"FAIL  local naming"*task_branch* ]] \
  && ok "doctor local: issue placeholders fail" || ko "doctor local naming"

done_tests
