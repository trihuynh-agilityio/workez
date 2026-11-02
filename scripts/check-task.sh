#!/usr/bin/env bash
# Guard for one task of an approved plan.
#   check-task.sh <task-id> [plan-path]
# Run from the task's worktree, inside its project folder. Compares the work
# (committed, uncommitted and untracked) with the task's PR target branch and exits 1,
# printing every rule that fails. The plan is not inside the worktree while it is
# untracked, so pass its path; without it the script looks in <docs_dir>/*/plan.md and plan-fix.md.
# Limits, remote, docs folder and formatters come from .claude/workflow.json.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
docs="$(cfg .docs_dir)"; remote="$(cfg .github.remote)"
max_lines="$(cfg .task_limits.max_lines)"; max_files="$(cfg .task_limits.max_files)"

task="${1:-}"
plan="${2:-}"
[[ -n "$task" ]] || { echo "usage: check-task.sh <task-id> [plan-path]" >&2; exit 2; }

if [[ -z "$plan" ]]; then
  plan="$(grep -l -E "^## ${task}: " "$docs"/*/plan.md "$docs"/*/plan-fix.md 2>/dev/null | head -1)"
fi
[[ -f "$plan" ]] || { echo "check-task: plan not found; pass its path as the second argument" >&2; exit 2; }

# The task block: from "## T<n>: " to the next "## " heading.
block="$(awk -v t="$task" 'index($0, "## " t ": ") == 1 { f = 1; next } f && /^## / { exit } f' "$plan")"
[[ -n "$block" ]] || { echo "check-task: task $task not found in $plan" >&2; exit 2; }

field() { grep -m1 "^- \*\*$1\*\*:" <<<"$block" | sed -E 's/^- \*\*[^*]+\*\*: *//'; }
ticks() { grep -o '`[^`]*`' | tr -d '`'; }

files="$(field Files | ticks)"
branch="$(field Branch | ticks | head -1)"
base="$(field 'PR target' | ticks | head -1)"
acceptance="$(grep -m1 -i '^- Implementer tasks never edit' "$plan" | ticks)"

[[ -n "$branch" && -n "$base" ]] || { echo "check-task: Branch or PR target missing for $task in the plan" >&2; exit 2; }
[[ "$branch" != *"<"* ]] || { echo "check-task: $task has no sub-issue number in Branch yet ($branch)" >&2; exit 2; }

base_ref=""
for r in "$base" "$remote/$base"; do
  git rev-parse --verify -q "$r^{commit}" >/dev/null && { base_ref="$r"; break; }
done
[[ -n "$base_ref" ]] || { echo "check-task: base branch $base not found (locally or as $remote/$base)" >&2; exit 2; }

top="$(git rev-parse --show-toplevel)"
prefix="$(git rev-parse --show-prefix)"
mb="$(git merge-base "$base_ref" HEAD)"

# The UI check's result.md and the review report are workflow records (older branches committed
# them): a task may have them outside its Files list, and they do not count toward the size limits.
# The other UI-check evidence (screenshots, videos, logs) stays local: while untracked it is a record
# too, which covers task branches cut before .gitignore listed every evidence file type.
untracked="$(git -C "$top" ls-files --others --exclude-standard)"
is_record() {
  case "$1" in
    "$prefix$docs"/*/evidence/"$task"/result.md | "$prefix$docs"/*/reviews/"$task".md) return 0 ;;
    "$prefix$docs"/*/evidence/"$task"/*) grep -qxF "$1" <<<"$untracked" && return 0 ;;
  esac
  return 1
}

# Changed files and lines, paths from the repository root.
changed="$( { git -C "$top" diff --name-only "$mb"; echo "$untracked"; } | sort -u | sed '/^$/d')"
lines=0
while read -r added removed f; do
  [[ "$added" == "-" ]] || is_record "$f" || lines=$((lines + added + removed))
done < <(git -C "$top" diff --numstat "$mb")
while IFS= read -r f; do
  [[ -n "$f" ]] && ! is_record "$f" && lines=$((lines + $(wc -l <"$top/$f" 2>/dev/null || echo 0)))
done < <(git -C "$top" ls-files --others --exclude-standard)
count=0
while IFS= read -r f; do
  [[ -n "$f" ]] && ! is_record "$f" && count=$((count + 1))
done <<<"$changed"

fail=0
bad() { echo "FAIL: $1" >&2; fail=1; }

((lines >= max_lines)) && bad "changed lines (added + removed) are $lines; the limit is under $max_lines. Split the work."
((count >= max_files)) && bad "changed files are $count; the limit is under $max_files. Split the work."

# Is this the task that writes the acceptance tests? Only if every file it owns is one.
is_acceptance=0
if [[ -n "$files" && -n "$acceptance" ]]; then
  is_acceptance=1
  while IFS= read -r f; do grep -qxF "$f" <<<"$acceptance" || is_acceptance=0; done <<<"$files"
fi

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  is_record "$f" && continue
  rel="${f#"$prefix"}"
  [[ "$f" == "$prefix"* ]] || rel=""
  if [[ -z "$rel" ]] || ! grep -qxF "$rel" <<<"$files"; then
    bad "$f is not in the Files list of $task"
  fi
  if [[ -n "$rel" ]] && grep -qxF "$rel" <<<"$acceptance" && ((is_acceptance == 0)); then
    bad "$f is an acceptance test; only the task that writes it may change it"
  fi
  case "$f" in
    */intent.md | */spec.md | */plan.md | */plan-fix.md | intent.md | spec.md | plan.md | plan-fix.md)
      bad "$f is an intent, spec or plan file; no task may change it" ;;
  esac
done <<<"$changed"

current="$(git rev-parse --abbrev-ref HEAD)"
[[ "$current" == "$branch" ]] || bad "branch is $current; the plan says $branch"
why="$(wf_branch_ok "$branch")" || bad "$why"

# Commit subjects of the task (Conventional Commits when workflow.json sets conventions).
while IFS= read -r subject; do
  [[ -n "$subject" ]] || continue
  why="$(wf_commit_ok "$subject")" || bad "$why"
done < <(git log --no-merges --format=%s "$mb..HEAD")

# Formatting of the changed files, with the "format" rules of workflow.json (the format-on-edit
# hook may not have run). Each rule's check command runs in that folder of this checkout.
# Bash 3.2 compatible (macOS): no associative arrays.
rules="$(jq '.format // [] | length' "$WF_CONFIG")"
for ((i = 0; i < rules; i++)); do
  dir="$(cfg ".format[$i].dir")"; check="$(cfg ".format[$i].check")"
  [[ -n "$check" ]] || continue
  list=()
  while IFS= read -r f; do
    [[ -n "$f" && -f "$top/$f" && "$f" == "$prefix"* ]] && ! is_record "$f" || continue
    [[ "$(wf_format_rule "${f#"$prefix"}")" == "$i" ]] && list+=("$top/$f")
  done <<<"$changed"
  ((${#list[@]})) || continue
  if ! out="$(cd "$WF_PROJECT/$dir" && bash -c "$check \"\$@\"" check "${list[@]}" 2>&1)"; then
    # Name the files the tool reported (by absolute path, or relative to its folder).
    names=""
    for f in "${list[@]}"; do
      grep -qF -e "$f" -e "${f#"$top/$prefix$dir/"}" <<<"$out" && names+="${f#"$top/"} "
    done
    bad "not formatted ($check in $dir/): ${names:-$(head -3 <<<"$out" | tr '\n' ' ')}"
  fi
done

if ((fail)); then
  echo "check-task $task: FAILED ($lines lines, $count files against $base_ref)" >&2
  exit 1
fi
echo "check-task $task: PASS ($lines lines, $count files against $base_ref, branch $current)"
