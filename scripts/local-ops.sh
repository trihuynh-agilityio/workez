#!/usr/bin/env bash
# The github-ops operations for the local tracker ("tracker": "local" in workflow.json): no gh, no
# GitHub. The workez:github-ops agent runs this script instead of gh in local mode, so the skills call
# the same operations in both modes.
#   local-ops.sh <operation> <inputs...>
#
# Identifiers:
#   feature issue  the feature folder name (create-issue and find-issue return it as the number)
#   task issue     "local": a plan task's Issue field; task-level operations on it change nothing
#   pull request   the head branch: a "merge request" record the user opens by hand on their host
#
# Data, all under .claude/workflow/ (gitignored):
#   <feature>/tracker.json        {"feature", "title", "labels": [...], "created"}
#   <feature>/log.md              the comments the workflow would post on the feature issue
#   local-mr/<branch with / as ->.json   {"head", "base", "title", "sha", "state", "created"}
#   local-mr/<branch with / as ->.md     the merge request text: title, branches, link, body
#
# Pull request state, never guessed: NONE without a record; CLOSED or MERGED when mark-merged.sh set
# it; MERGED when the recorded head commit, or the head branch's current tip, is an ancestor of the
# base branch (wf_ref: <remote>/<base>, or the local base without a remote); OPEN otherwise. A squash
# merge leaves no ancestry: the user marks it with mark-merged.sh.
#
# Output follows agents/github-ops.md, one result per call; exit 1 on an error, 2 on bad usage.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

DIR="$WF_PROJECT/.claude/workflow"
MR="$DIR/local-mr"
op="${1:-}"; shift 2>/dev/null || true
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { echo "usage: local-ops.sh $op $*" >&2; exit 2; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
key() { printf '%s' "${1//\//-}"; }

# feature_of <intent path>: the feature folder name, after checking the intent is approved when asked.
feature_of() {
  local f
  f="$(basename "$(dirname "$1")")"
  [[ "$f" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "no feature folder in '$1'"
  printf '%s' "$f"
}
tracker() { printf '%s/%s/tracker.json' "$DIR" "$1"; }
labels() { jq -r '.labels | join(", ")' "$(tracker "$1")"; }
# json_set <file> <jq filter> [jq args...]: rewrite a JSON file through a temp file.
json_set() {
  local f="$1" filter="$2" tmp
  shift 2
  tmp="$(mktemp "$f.XXXXXX")" && jq "$@" "$filter" "$f" >"$tmp" && mv "$tmp" "$f"
}
# feature_or_local <id>: prints the feature for a feature id, nothing for "local"/"#n" task ids.
feature_or_local() {
  local id="${1#\#}"
  [[ "$id" == local ]] && return 0
  [[ -f "$(tracker "$id")" ]] || die "no local feature '$id' (no $(tracker "$id"))"
  printf '%s' "$id"
}
mr_json() { printf '%s/%s.json' "$MR" "$(key "$1")"; }
mr_md() { printf '%s/%s.md' "$MR" "$(key "$1")"; }

# mr_link <head> <base>: the "new merge request" page on a GitLab remote, else "-".
mr_link() {
  local r url host path
  r="$(wf_remote)"
  [[ -n "$r" ]] || { echo -; return; }
  url="$(git -C "$WF_TOP" config --get "remote.$r.url" 2>/dev/null)" || { echo -; return; }
  case "$url" in
    git@*:*) host="${url#git@}"; host="${host%%:*}"; path="${url#*:}" ;;
    ssh://*) host="${url#ssh://}"; host="${host#*@}"; path="${host#*/}"; host="${host%%/*}"; host="${host%%:*}" ;;
    http://* | https://*) host="${url#*://}"; host="${host#*@}"; path="${host#*/}"; host="${host%%/*}" ;;
    *) echo -; return ;;
  esac
  path="${path%.git}"
  [[ "$host" == *gitlab* ]] || { echo -; return; }
  printf 'https://%s/%s/-/merge_requests/new?merge_request%%5Bsource_branch%%5D=%s&merge_request%%5Btarget_branch%%5D=%s\n' \
    "$host" "$path" "$1" "$2"
}

# tip <branch>: the branch's newest commit: <remote>/<branch> when the remote has it, else the local branch.
tip() {
  git -C "$WF_TOP" rev-parse -q --verify "refs/remotes/$(wf_ref "$1")^{commit}" 2>/dev/null && return 0
  git -C "$WF_TOP" rev-parse -q --verify "refs/heads/$1^{commit}" 2>/dev/null
}

# pr_state <branch>: NONE, OPEN, MERGED or CLOSED (see the header).
pr_state() {
  local f base target sha cur
  f="$(mr_json "$1")"
  [[ -f "$f" ]] || { echo NONE; return; }
  case "$(jq -r '.state // "open"' "$f")" in
    merged) echo MERGED; return ;;
    closed) echo CLOSED; return ;;
  esac
  base="$(jq -r .base "$f")"; sha="$(jq -r '.sha // empty' "$f")"
  target="$(git -C "$WF_TOP" rev-parse -q --verify "$(wf_ref "$base")^{commit}" 2>/dev/null)" \
    || target="$(git -C "$WF_TOP" rev-parse -q --verify "refs/heads/$base^{commit}" 2>/dev/null)" \
    || { echo OPEN; return; }
  cur="$(tip "$1")"
  for c in $sha $cur; do
    [[ -n "$c" ]] && git -C "$WF_TOP" merge-base --is-ancestor "$c" "$target" 2>/dev/null \
      && { echo MERGED; return; }
  done
  echo OPEN
}

case "$op" in
  create-issue)
    intent="${1:-}"; [[ -f "$intent" ]] || usage "<intent path>"
    sed -n 2p "$intent" | grep -q '^Status: approved\.' || die "the intent is not approved (line 2 must say Status: approved.)"
    f="$(feature_of "$intent")"; t="$(tracker "$f")"
    if [[ -f "$t" ]]; then echo "$f - already existed labels: $(labels "$f")"; exit 0; fi
    title="$(wf_fill "$(cfg .naming.feature_issue_title)" feature_name="$(sed -n '1s/^# Intent: *//p' "$intent")")"
    mkdir -p "$DIR/$f"
    jq -n --arg f "$f" --arg t "$title" --arg c "$(now)" \
      '{feature: $f, title: $t, labels: ["feature", "phase:plan-done"], created: $c}' >"$t"
    echo "$f - new labels: $(labels "$f")"
    ;;
  find-issue)
    intent="${1:-}"; [[ -n "$intent" ]] || usage "<intent path>"
    f="$(feature_of "$intent")"
    if [[ -f "$(tracker "$f")" ]]; then echo "$f - labels: $(labels "$f")"; else echo "not found"; fi
    ;;
  get-issue)
    [[ -n "${1:-}" ]] || usage "<feature>"
    f="$(feature_or_local "$1")"
    [[ -n "$f" ]] || { echo "local - task tracked in the plan (local tracker)"; exit 0; }
    jq -r '"\(.feature) - OPEN labels: \(.labels | join(", "))\n\(.title)"' "$(tracker "$f")"
    ;;
  comment)
    id="${1:-}"; shift 2>/dev/null || true
    [[ -n "$id" && $# -gt 0 ]] || usage "<feature|branch> <text> | --body-file <path>"
    if [[ "$1" == --body-file ]]; then text="$(cat "${2:?}")" || die "cannot read ${2:-}"; else text="$*"; fi
    if [[ -f "$(mr_json "$id")" ]]; then
      printf '\n## Comment (%s)\n\n%s\n' "$(now)" "$text" >>"$(mr_md "$id")"; echo "$(mr_md "$id")"
    else
      f="$(feature_or_local "$id")"
      [[ -n "$f" ]] || { echo "local - nothing to comment on (local tracker)"; exit 0; }
      printf '\n## %s\n\n%s\n' "$(now)" "$text" >>"$DIR/$f/log.md"; echo "$DIR/$f/log.md"
    fi
    ;;
  swap-label)
    [[ $# -eq 3 ]] || usage "<feature|local> <old|-> <new>"
    f="$(feature_or_local "$1")"
    [[ -n "$f" ]] || { echo "local - labels are not tracked for tasks (local tracker)"; exit 0; }
    json_set "$(tracker "$f")" '.labels = ((.labels - [$old]) + [$new] | unique)' --arg old "$2" --arg new "$3"
    echo "$f - labels: $(labels "$f")"
    ;;
  list-sub-issues)
    echo "local - tasks are tracked in the plan (local tracker)"
    ;;
  create-sub-issue | create-task-issue)
    echo "local - new (local tracker: the plan's Issue field is 'local')"
    ;;
  close-issue)
    [[ -n "${1:-}" ]] || usage "<local>"
    [[ "${1#\#}" == local ]] || die "close-issue only closes task issues ('local'), never the feature"
    echo "local - closed (local tracker)"
    ;;
  find-pr)
    b="${1:-}"; [[ -n "$b" ]] || usage "<head branch>"
    f="$(mr_json "$b")"
    [[ -f "$f" ]] || { echo "not found"; exit 0; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$b" "$(pr_state "$b")" "$(jq -r .base "$f")" "$(mr_md "$b")"
    ;;
  create-pr)
    [[ $# -eq 4 ]] || usage "<head branch> <base branch> <title> <body-file>"
    head="$1"; base="$2"; title="$3"; body="$4"
    [[ -f "$body" ]] || die "no body file $body"
    if [[ -f "$(mr_json "$head")" ]]; then
      echo "$head $(mr_md "$head") $(pr_state "$head") already existed"; exit 0
    fi
    r="$(wf_remote)"
    if [[ -n "$r" ]]; then
      git -C "$WF_TOP" ls-remote --exit-code --heads "$r" "$head" >/dev/null 2>&1 \
        || die "$head is not on $r; push it first"
    fi
    sha="$(tip "$head")" || die "no branch $head"
    bt="$(git -C "$WF_TOP" rev-parse -q --verify "$(wf_ref "$base")^{commit}" 2>/dev/null)" \
      || bt="$(git -C "$WF_TOP" rev-parse -q --verify "refs/heads/$base^{commit}" 2>/dev/null)" || die "no branch $base"
    git -C "$WF_TOP" merge-base --is-ancestor "$sha" "$bt" && die "$head has nothing to merge into $base"
    link="$(mr_link "$head" "$base")"
    mkdir -p "$MR"
    jq -n --arg h "$head" --arg b "$base" --arg t "$title" --arg s "$sha" --arg c "$(now)" \
      '{head: $h, base: $b, title: $t, sha: $s, state: "open", created: $c}' >"$(mr_json "$head")"
    {
      echo "# $title"
      echo
      echo "- Source branch: \`$head\`"
      echo "- Target branch: \`$base\`"
      if [[ "$link" != - ]]; then echo "- Open it: $link"
      elif [[ -n "$r" ]]; then echo "- Open a merge request from \`$head\` into \`$base\` on the \`$r\` remote's host."
      else echo "- No remote: merge it yourself: \`git switch $base && git merge --no-ff $head\`"; fi
      echo "- Squash merge? Mark it: \`\${CLAUDE_PLUGIN_ROOT}/scripts/mark-merged.sh $head\`"
      echo
      echo "## Description"
      echo
      cat "$body"
    } >"$(mr_md "$head")"
    echo "$head $(mr_md "$head") new"
    [[ "$link" != - ]] && echo "OPEN_MR=$link"
    ;;
  get-pr-state)
    (($#)) || usage "<branch>..."
    for b in "$@"; do
      s="$(pr_state "$b")"
      if [[ "$s" == NONE ]]; then echo "$b NONE"; else printf '%s\t%s\t%s\n' "$b" "$s" "$b"; fi
    done
    ;;
  get-pr-feedback) echo "no new feedback" ;;
  get-pr-checks) echo "no failed checks" ;;
  append-pr-section)
    [[ $# -ge 2 ]] || usage "<branch> <section file> [heading]"
    b="$1"; sec="$2"; heading="${3:-## Verification}"
    [[ -f "$(mr_json "$b")" ]] || die "no local merge request for $b"
    [[ "$(head -1 "$sec")" == "$heading" ]] || die "the first line of $sec must be '$heading'"
    md="$(mr_md "$b")"; tmp="$(mktemp "$md.XXXXXX")"
    how=added
    grep -qxF -- "$heading" "$md" && how=replaced
    awk -v h="$heading" '$0 == h { skip = 1; next } skip && /^## / { skip = 0 } !skip' "$md" >"$tmp"
    printf '\n' >>"$tmp"; cat "$sec" >>"$tmp"
    mv "$tmp" "$md"
    echo "$b $md $how"
    ;;
  *)
    echo "usage: local-ops.sh <create-issue|find-issue|get-issue|comment|swap-label|list-sub-issues|create-sub-issue|create-task-issue|close-issue|find-pr|create-pr|get-pr-state|get-pr-feedback|get-pr-checks|append-pr-section> ..." >&2
    exit 2 ;;
esac
