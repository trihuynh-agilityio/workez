#!/usr/bin/env bash
# Checks that this machine and the project are ready for the workez workflow. Read-only: it changes
# nothing. Run it from inside the project.
#   doctor.sh [--offline]     (--offline skips the GitHub and remote checks)
# One line per check: "OK", "WARN" (works, but something is missing or risky) or "FAIL" (the
# workflow will break), the check and a hint. Exits 1 when any check fails.

offline=0; [[ "${1:-}" == --offline ]] && offline=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; warns=0
ok() { printf 'OK    %-24s %s\n' "$1" "${2:-}"; }
warn() { printf 'WARN  %-24s %s\n' "$1" "$2"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %-24s %s\n' "$1" "$2"; fails=$((fails + 1)); }
# ver_ge <have> <need>: true when version <have> is at least <need> (numeric dotted parts).
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 } exit 0 }'
}
version_of() { "$@" 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

# ---- Tools ----
((${BASH_VERSINFO[0]} >= 4 || (${BASH_VERSINFO[0]} == 3 && ${BASH_VERSINFO[1]} >= 2))) \
  && ok "bash" "$BASH_VERSION" || fail "bash" "bash 3.2 or newer is required"
if command -v git >/dev/null; then
  v="$(version_of git --version)"
  ver_ge "$v" 2.42 && ok "git" "$v" || fail "git" "$v found; 2.42 or newer is required (worktree add --orphan)"
else fail "git" "not installed"; fi
for t in jq gh curl lsof; do
  command -v "$t" >/dev/null && ok "$t" "$(version_of "$t" --version)" || fail "$t" "not installed; install it with your package manager"
done
if command -v node >/dev/null && command -v npx >/dev/null; then
  v="$(version_of node --version)"
  ver_ge "$v" 18 && ok "node + npx" "$v" || fail "node + npx" "$v found; Node 18 or newer is needed for Playwright MCP"
else fail "node + npx" "not installed; the Playwright servers run through npx"; fi
chrome=""
for c in "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do [[ -d "$c" ]] && chrome="$c"; done
[[ -z "$chrome" ]] && for c in google-chrome google-chrome-stable chrome; do command -v "$c" >/dev/null && chrome="$c" && break; done
[[ -n "$chrome" ]] && ok "Google Chrome" "$chrome" \
  || warn "Google Chrome" "not found; the UI checks use --browser chrome (npx playwright install chrome)"

# ---- Project ----
if ! source "$here/lib/config.sh" 2>/dev/null; then
  fail "workflow.json" "no .claude/workflow.json in $PWD or above; run /workez:setup"
  echo; echo "failures: $fails, warnings: $warns"; exit 1
fi
ok "project" "$WF_PROJECT"
if ! jq empty "$WF_CONFIG" 2>/dev/null; then
  fail "workflow.json" "not valid JSON: $WF_CONFIG"
  echo; echo "failures: $fails, warnings: $warns"; exit 1
fi

missing="$(jq -r '. as $root | [ "github.repo", "github.remote", "branches.base", "branches.protected",
  "docs_dir", "task_limits.max_lines", "task_limits.max_files", "naming.feature_issue_title",
  "naming.task_issue_title", "naming.fix_issue_title", "naming.integration_branch", "naming.task_branch",
  "naming.task_pr_title", "naming.final_pr_title", "naming.task_commit", "naming.review_fix_commit",
  "commands.install", "commands.test", "commands.acceptance" ]
  | map(select(. as $k | ($root | try getpath($k | split(".")) catch null) as $v | $v == null or $v == "")) | join(", ")' \
  "$WF_CONFIG" 2>/dev/null)"
[[ -z "$missing" ]] && ok "workflow.json keys" || fail "workflow.json keys" "missing: $missing"
jq -e '(.task_limits.exclude // []) | type == "array" and all(type == "string")' "$WF_CONFIG" >/dev/null 2>&1 \
  || fail "task_limits.exclude" "must be a list of glob strings"

# workflow.local.json: one person's overrides, only of the personal keys, never committed.
for f in "$WF_CONFIG" "$WF_LOCAL"; do
  [[ -f "$f" ]] && jq -e 'has("notify") and (.notify | type != "boolean")' "$f" >/dev/null 2>&1 \
    && warn "notify" "must be true or false in $(basename "$f"); notifications stay on"
done
if [[ -f "$WF_LOCAL" ]]; then
  if ! jq -e 'type == "object"' "$WF_LOCAL" >/dev/null 2>&1; then
    warn "workflow.local.json" "not a valid JSON object; it is ignored"
  else
    extra="$(jq -r '[keys[] | select(IN($ARGS.positional[]) | not)] | join(", ")' "$WF_LOCAL" --args "${WF_PERSONAL_KEYS[@]}")"
    [[ -z "$extra" ]] && ok "workflow.local.json" "$(jq -c . "$WF_LOCAL")" \
      || warn "workflow.local.json" "ignored keys: $extra (it may set only ${WF_PERSONAL_KEYS[*]}; team rules belong in workflow.json)"
  fi
  git -C "$WF_PROJECT" ls-files --error-unmatch "$WF_LOCAL" >/dev/null 2>&1 \
    && warn "workflow.local.json" "is committed; it is personal: git rm --cached it and rerun setup-project.sh"
fi

# Branch and commit naming: Conventional Commits with conventions.commit_types, else branches.prefix.
if wf_conventions; then
  ok "conventions" "Conventional Commits, types $(jq -r '.conventions.commit_types | join(", ")' "$WF_CONFIG")"
  bad=""
  while IFS=$'\t' read -r key value; do
    sample="$(wf_fill "$value" task_type="$(jq -r '.conventions.commit_types[0]' "$WF_CONFIG")" task_issue=12 task_slug=demo feature_issue=7 feature_slug=demo)"
    wf_branch_ok "$sample" >/dev/null || bad="$bad $key"
  done < <(jq -r '.naming | to_entries[] | select(.key | test("branch$")) | "\(.key)\t\(.value)"' "$WF_CONFIG")
  [[ -z "$bad" ]] && ok "branch naming" "<type>/..." || fail "branch naming" "$(echo $bad) must start with <type>/ or {task_type}/"
  bad=""
  for key in task_commit review_fix_commit task_pr_title final_pr_title; do
    sample="$(wf_fill "$(cfg ".naming.$key")" task_type="$(jq -r '.conventions.commit_types[0]' "$WF_CONFIG")" \
      task_scope="(ui)" task_title="add the form" task_issue=12 feature_name="Demo" round=1)"
    why="$(wf_commit_ok "$sample")" || bad="$bad $key ($why)"
  done
  [[ -z "$bad" ]] && ok "commit and PR titles" "<type>[(scope)]: ..." || fail "commit and PR titles" "not Conventional Commits:$bad"
else
  prefix="$(cfg .branches.prefix)"
  if [[ -z "$prefix" ]]; then fail "branch naming" "set conventions.commit_types (or branches.prefix)"
  else
    bad="$(jq -r --arg p "$prefix" '.naming | to_entries[] | select(.key | test("branch$")) | select(.value | startswith($p) | not) | .key' "$WF_CONFIG")"
    [[ -z "$bad" ]] && ok "branch naming" "every branch starts with $prefix" \
      || fail "branch naming" "$(echo $bad) must start with branches.prefix ($prefix)"
  fi
  grep -q '{task_type}\|{task_scope}' "$WF_CONFIG" && fail "naming placeholders" "{task_type} and {task_scope} need conventions.commit_types"
  warn "conventions" "no conventions.commit_types: commit messages are not checked"
fi
base="$(cfg .branches.base)"
jq -e --arg b "$base" '.branches.protected | index($b)' "$WF_CONFIG" >/dev/null \
  && ok "protected branches" "$(cfg '.branches.protected | join(", ")')" \
  || warn "protected branches" "the base branch $base is not in branches.protected"
[[ "$(jq -r '.lanes // {} | keys | join(",")' "$WF_CONFIG")" == "A,B" ]] \
  && ok "lanes" "A and B" || fail "lanes" "lanes must be exactly A and B"
ports="$(jq -r '.lanes // {} | [.[] | .[]] | map(tostring) | join(" ")' "$WF_CONFIG")"
[[ "$(tr ' ' '\n' <<<"$ports" | sort | uniq -d)" == "" ]] && ok "lane ports" "$ports" || fail "lane ports" "a port is used twice: $ports"
busy=""; for p in $ports; do lsof -ti "tcp:$p" -sTCP:LISTEN >/dev/null 2>&1 && busy="$busy $p"; done
[[ -z "$busy" ]] || warn "lane ports in use" "something listens on$busy; the UI checks start their own servers there"

nodirs=""
while IFS= read -r d; do [[ -d "$WF_PROJECT/$d" ]] || nodirs="$nodirs $d"; done \
  < <(jq -r '[.commands[]? | (if type == "array" then .[] else . end) | .dir // "."] + [.format[]?.dir // "."] + [.dev_servers[]?.dir // "."] | unique[]' "$WF_CONFIG")
[[ -z "$nodirs" ]] && ok "command folders" || fail "command folders" "missing in the project:$nodirs"
[[ "$(jq '.dev_servers // [] | length' "$WF_CONFIG")" -gt 0 ]] && ok "dev_servers" \
  || warn "dev_servers" "none; UI checks and the feature E2E cannot run"

# Permission rules and .gitignore, as written by setup-project.sh.
settings="$WF_PROJECT/.claude/settings.json"
plugin="$(jq -r .name "$WF_HOME/.claude-plugin/plugin.json")"
if [[ -f "$settings" ]] && jq -e --arg p "$plugin" '.permissions.allow // [] | (index("Bash(*\($p)*/scripts/*.sh*)") and index("mcp__plugin_\($p)_playwright-a"))' "$settings" >/dev/null 2>&1; then
  ok "permissions" ".claude/settings.json"
else fail "permissions" "workflow rules missing in .claude/settings.json; run setup-project.sh"; fi
gi_missing=""
for l in ".claude/workflow/" ".claude/worktrees/" "$(cfg .docs_dir)/*/reviews/" "$(cfg .docs_dir)/*/evidence/"; do
  git -C "$WF_PROJECT" check-ignore -q --no-index "${l%/}/x" 2>/dev/null || gi_missing="$gi_missing $l"
done
[[ -z "$gi_missing" ]] && ok ".gitignore" || fail ".gitignore" "not ignored:$gi_missing; run setup-project.sh"
[[ -f "$WF_PROJECT/CLAUDE.md" || -f "$WF_TOP/CLAUDE.md" ]] && ok "CLAUDE.md" \
  || warn "CLAUDE.md" "none; every phase reads it for the stack, rules and how to run one test"
# A copy of the plugin's files inside the project would run every hook twice.
old=""; for f in .claude/hooks/next-phase.sh .claude/scripts/lib/config.sh .claude/skills/build-feature/SKILL.md; do
  [[ -e "$WF_PROJECT/$f" ]] && old="$old $f"; done
[[ -z "$old" ]] && ok "no duplicate copy" \
  || warn "duplicate copy" "found$old; remove the project's copy of the plugin's files (and their hooks in settings.json)"

# ---- Git and GitHub ----
repo="$(cfg .github.repo)"; remote="$(cfg .github.remote)"
if git -C "$WF_PROJECT" remote get-url "$remote" >/dev/null 2>&1; then ok "git remote" "$remote"
else fail "git remote" "no remote named $remote (github.remote)"; fi
if ((offline)); then
  echo "SKIP  GitHub checks         --offline"
else
  if git -C "$WF_PROJECT" ls-remote --exit-code --heads "$remote" "$base" >/dev/null 2>&1; then ok "base branch" "$remote/$base"
  else fail "base branch" "$base not found on $remote"; fi
  if gh auth status >/dev/null 2>&1; then
    ok "gh auth"
    info="$(gh repo view "$repo" --json hasIssuesEnabled,viewerPermission 2>/dev/null)"
    if [[ -z "$info" ]]; then fail "GitHub repo" "cannot read $repo with gh"
    else
      [[ "$(jq -r .hasIssuesEnabled <<<"$info")" == true ]] && ok "GitHub issues" "$repo" || fail "GitHub issues" "issues are disabled on $repo"
      perm="$(jq -r .viewerPermission <<<"$info")"
      [[ "$perm" =~ ^(WRITE|MAINTAIN|ADMIN)$ ]] && ok "GitHub permission" "$perm" \
        || fail "GitHub permission" "$perm; pushing branches, labels and PRs needs write access"
      gh api "repos/$repo/issues?per_page=1" >/dev/null 2>&1 && gh api "repos/$repo/issues/1/sub_issues" >/dev/null 2>&1 \
        && ok "GitHub sub-issues" || warn "GitHub sub-issues" "could not call the sub-issues API (fine if the repository has no issue #1 yet)"
    fi
  else fail "gh auth" "gh is not signed in; run gh auth login"; fi
fi

echo; echo "failures: $fails, warnings: $warns"
((fails == 0))
