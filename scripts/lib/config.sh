# Shared helpers for the workflow scripts and hooks of the workez plugin. Source it; it
# reads the project's .claude/workflow.json.
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/config.sh"
# The project is found from, in order: $WF_PROJECT (when it holds .claude/workflow.json), else the
# nearest folder at or above $WF_START (default: the current folder) that holds .claude/workflow.json.
# Found inside a linked worktree, it maps to the same folder of the main checkout, so every caller
# sees one project wherever it runs.
# Sets:
#   WF_PROJECT  the project folder of the main checkout (the folder that holds .claude/workflow.json)
#   WF_CONFIG   its workflow.json
#   WF_LOCAL    its workflow.local.json: one person's overrides, gitignored, maybe absent (see wf_personal)
#   WF_TOP      the main repository root (also right when called from a worktree)
#   WF_PREFIX   the project's path inside the repository, with a trailing slash, or "" at the root
#   WF_HOME     the plugin folder (scripts/, hooks/, skills/ ...)
# Needs jq. Every value that differs between projects comes from workflow.json, never from here.

WF_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "workflow: jq is required" >&2; return 2 2>/dev/null || exit 2; }

# wf_find_project <start folder>: the nearest folder at or above it that holds .claude/workflow.json.
# Skips $HOME, whose .claude/ is Claude Code's user folder.
wf_find_project() {
  local d
  d="$(cd "$1" 2>/dev/null && pwd)" || return 1
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ "$d" != "$(cd "$HOME" 2>/dev/null && pwd)" && -f "$d/.claude/workflow.json" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

if [[ -z "${WF_PROJECT:-}" || ! -f "${WF_PROJECT:-}/.claude/workflow.json" ]]; then
  WF_PROJECT="$(wf_find_project "${WF_START:-$PWD}")" || {
    echo "workflow: no .claude/workflow.json in ${WF_START:-$PWD} or above (run the workez:setup skill, or set WF_PROJECT)" >&2
    return 2 2>/dev/null || exit 2
  }
fi
WF_PROJECT="$(cd "$WF_PROJECT" && pwd)"

WF_TOP="$(cd "$(git -C "$WF_PROJECT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
# Inside a linked worktree: use the same folder of the main checkout.
if [[ "$(git -C "$WF_PROJECT" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$WF_PROJECT" rev-parse --path-format=absolute --git-common-dir)" ]]; then
  _wf_sub="$(git -C "$WF_PROJECT" rev-parse --show-prefix)"
  [[ -f "$WF_TOP/${_wf_sub}.claude/workflow.json" ]] && WF_PROJECT="$(cd "$WF_TOP/$_wf_sub" && pwd)"
  unset _wf_sub
fi
WF_CONFIG="$WF_PROJECT/.claude/workflow.json"
WF_LOCAL="$WF_PROJECT/.claude/workflow.local.json"
WF_PREFIX="${WF_PROJECT#"$WF_TOP"}"
WF_PREFIX="${WF_PREFIX#/}"
[[ -n "$WF_PREFIX" ]] && WF_PREFIX="$WF_PREFIX/"
export WF_PROJECT

# cfg <jq filter>: one raw value (arrays and objects come out as JSON).
cfg() { jq -r "$1 // empty" "$WF_CONFIG"; }

# The keys workflow.local.json may set: personal choices only, never the team's rules (branches,
# blocked_commands, conventions ...), so nobody can loosen those on their own machine. doctor.sh warns
# about any other key there, and nothing reads it.
WF_PERSONAL_KEYS=(notify)

# wf_personal <key>: a personal key's raw value, from workflow.local.json, else workflow.json, else
# nothing. A false value comes out as "false" (unlike cfg, whose // drops it).
wf_personal() {
  local f
  for f in "$WF_LOCAL" "$WF_CONFIG"; do
    [[ -f "$f" ]] && jq -e --arg k "$1" 'has($k)' "$f" >/dev/null 2>&1 && { jq -r --arg k "$1" '.[$k]' "$f"; return 0; }
  done
  return 1
}

# wf_fill <template> [key=value ...]: replaces each {key} in the template.
wf_fill() {
  local s="$1" kv
  shift
  for kv in "$@"; do s="${s//\{${kv%%=*}\}/${kv#*=}}"; done
  printf '%s' "$s"
}

# wf_project_in <worktree root>: the project folder inside a worktree of this repository.
wf_project_in() { local p="$1/${WF_PREFIX%/}"; printf '%s' "${p%/}"; }

# wf_worktree_path <branch>: where the workflow keeps that branch's worktree.
wf_worktree_path() { printf '%s/.claude/worktrees/%s' "$WF_TOP" "${1//\//-}"; }

# wf_lane_vars <lane>: key=value lines for the lane's ports, for wf_fill.
wf_lane_vars() {
  jq -r --arg l "$1" '.lanes[$l] // empty | to_entries[] | "\(.key)=\(.value)"' "$WF_CONFIG"
}

# wf_commands <key>: one line per command of commands.<key>, "<dir><TAB><run>".
wf_commands() {
  jq -r --arg k "$1" '.commands[$k] // [] | (if type == "array" then . else [.] end)[] | "\(.dir // ".")\t\(.run)"' "$WF_CONFIG"
}

# wf_format_rule <path inside the project>: the index of the format rule that covers the file, or nothing.
wf_format_rule() {
  local rel="$1" i n dir sub pat hit
  n="$(jq '.format // [] | length' "$WF_CONFIG")"
  for ((i = 0; i < n; i++)); do
    dir="$(jq -r ".format[$i].dir // \".\"" "$WF_CONFIG")"
    if [[ "$dir" == "." ]]; then sub="$rel"; else
      [[ "$rel" == "$dir"/* ]] || continue
      sub="${rel#"$dir"/}"
    fi
    hit=0
    while IFS= read -r pat; do [[ -n "$pat" && "$sub" == $pat ]] && hit=1; done < <(jq -r ".format[$i].match[]?" "$WF_CONFIG")
    ((hit)) || continue
    while IFS= read -r pat; do [[ -n "$pat" && "$sub" == $pat ]] && hit=0; done < <(jq -r ".format[$i].exclude[]?" "$WF_CONFIG")
    ((hit)) && { echo "$i"; return 0; }
  done
  return 1
}

# wf_trailers: the commit trailer lines of workflow.json "commit_trailers" (one per line; nothing when
# it is []), "Co-Authored-By: Claude <noreply@anthropic.com>" when the key is absent.
wf_trailers() {
  jq -r 'if has("commit_trailers") then .commit_trailers[] else "Co-Authored-By: Claude <noreply@anthropic.com>" end' "$WF_CONFIG"
}

# ---- Conventions (https://www.conventionalcommits.org/en/v1.0.0/) ----
# With "conventions.commit_types" in workflow.json, commit subjects are "<type>[(scope)][!]: <description>"
# and workflow branches are "<type>/...", both with a type from that list. Without it, branches
# only need branches.prefix and commit subjects are free (the behaviour before conventions).

# wf_conventions: true when workflow.json turns the conventions on.
wf_conventions() { [[ "$(jq -r '.conventions.commit_types // [] | length' "$WF_CONFIG")" -gt 0 ]]; }

# wf_branch_prefixes: one line per prefix a workflow branch may start with.
wf_branch_prefixes() {
  if wf_conventions; then jq -r '.conventions.commit_types[] | "\(.)/"' "$WF_CONFIG"
  else cfg .branches.prefix; fi
}

# wf_branch_ok <branch>: true when the branch follows the convention; prints why not otherwise.
wf_branch_ok() {
  local p
  while IFS= read -r p; do [[ -n "$p" && "$1" == "$p"?* ]] && return 0; done < <(wf_branch_prefixes)
  if wf_conventions; then
    echo "branch '$1' must be <type>/<name> with a type from conventions.commit_types ($(jq -r '.conventions.commit_types | join(", ")' "$WF_CONFIG"))"
  else echo "branch '$1' must start with branches.prefix ($(cfg .branches.prefix))"; fi
  return 1
}

# wf_commit_ok <subject>: true when the commit subject follows Conventional Commits (always true
# without conventions); prints why not otherwise. Merge and revert subjects that git writes pass.
wf_commit_ok() {
  local s="$1" types max
  wf_conventions || return 0
  [[ "$s" == "Merge "* || "$s" == "Revert \""* ]] && return 0
  types="$(jq -r '.conventions.commit_types | join("|")' "$WF_CONFIG")"
  max="$(jq -r '.conventions.subject_max_length // 72' "$WF_CONFIG")"
  if ! grep -Eq "^($types)(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]]" <<<"$s"; then
    echo "commit subject '$s' must be <type>[(scope)][!]: <description>, type one of ${types//|/, }"; return 1
  fi
  [[ "$s" == *. ]] && { echo "commit subject '$s' must not end with a period"; return 1; }
  ((${#s} <= max)) || { echo "commit subject is ${#s} characters; the limit is $max"; return 1; }
  return 0
}
