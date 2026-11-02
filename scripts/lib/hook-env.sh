# Sourced by the hooks after they read their JSON input into $input. Loads config.sh for the project
# of the hook's "cwd", else of $CLAUDE_PROJECT_DIR, else of the current folder. Returns 2 when neither is inside a project with a
# .claude/workflow.json, so the hooks do nothing in projects that do not use the workflow.

_wf_cwd="$(jq -r '.cwd // empty' <<<"${input:-}" 2>/dev/null)"
for WF_START in "$_wf_cwd" "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
  [[ -n "$WF_START" ]] || continue
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null && { unset _wf_cwd; return 0; }
done
unset _wf_cwd
return 2
