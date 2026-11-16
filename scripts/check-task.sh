#!/usr/bin/env bash
# Guard for one task of an approved plan.
#   check-task.sh <task-id> [plan-path]
# Run from the task's worktree, inside its project folder. Compares the work
# (committed, uncommitted and untracked) with the task's PR target branch and exits 1,
# printing every rule that fails, each with the path or plan line at fault, the rule and a correct example.
# The plan is not inside the worktree while it is untracked, so pass its path; without it the script
# looks in <docs_dir>/*/plan.md and plan-fix.md.
# Limits, remote, docs folder and formatters come from .claude/workflow.json.
# Files matching task_limits.exclude (lock files and SVGs when the key is absent) do not count toward
# the size limits, and tests and docs do not count toward max_files (task_limits.skip_tests_docs,
# default true); all of them must still be in the task's Files list.
# A moved file (git mv, or a plain mv: detected with git diff -M) counts as one file, and only its
# new path needs to be in the Files list.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2
docs="$(cfg .docs_dir)"; remote="$(wf_remote)"
max_lines="$(cfg .task_limits.max_lines)"; max_files="$(cfg .task_limits.max_files)"

task="${1:-}"
plan="${2:-}"
[[ -n "$task" ]] || { echo "usage: check-task.sh <task-id> [plan-path]" >&2; exit 2; }

if [[ -z "$plan" ]]; then
  plan="$(grep -l -E "^## ${task}: " "$docs"/*/plan.md "$docs"/*/plan-fix.md 2>/dev/null | head -1)"
fi
[[ -f "$plan" ]] || {
  echo "check-task: no plan holds a heading '## $task: ' under $docs/*/plan.md or plan-fix.md; pass the plan's path as the second argument" >&2
  echo "  example: check-task.sh $task $docs/<feature>/plan.md" >&2
  exit 2
}

# The task block: from "## T<n>: " to the next "## " heading. head_line: the heading's line number.
head_line="$(awk -v t="$task" 'index($0, "## " t ": ") == 1 { print NR; exit }' "$plan")"
block="$(awk -v t="$task" 'index($0, "## " t ": ") == 1 { f = 1; next } f && /^## / { exit } f' "$plan")"
[[ -n "$head_line" ]] || {
  echo "check-task: task $task not found in $plan; the rule: each task starts with a heading '## <id>: <title>'" >&2
  echo "  example: ## $task: Add the search route  [ ]" >&2
  exit 2
}

field() { grep -m1 "^- \*\*$1\*\*:" <<<"$block" | sed -E 's/^- \*\*[^*]+\*\*: *//'; }
ticks() { grep -o '`[^`]*`' | tr -d '`'; }

branch="$(field Branch | ticks | head -1)"
base="$(field 'PR target' | ticks | head -1)"
acceptance="$(grep -m1 -i '^- Implementer tasks never edit' "$plan" | ticks)"

if [[ -z "$branch" || -z "$base" ]]; then
  echo "check-task: $plan:$head_line: task $task needs a **Branch** and a **PR target** line, each with the branch name in backticks" >&2
  echo "  example: - **Branch**: \`feat/12-search-route\`" >&2
  echo "           - **PR target**: \`feat/7-search\`" >&2
  exit 2
fi
[[ "$branch" != *"<"* ]] || {
  echo "check-task: $plan:$head_line: $task has no sub-issue number in **Branch** yet ($branch); run create-task-issues first" >&2
  echo "  example: - **Branch**: \`feat/12-search-route\`" >&2
  exit 2
}

base_ref=""
for r in "$base" "$(wf_ref "$base")"; do
  git rev-parse --verify -q "$r^{commit}" >/dev/null && { base_ref="$r"; break; }
done
[[ -n "$base_ref" ]] || { echo "check-task: base branch $base (**PR target** of $task) not found locally or as $(wf_ref "$base"); fetch it first" >&2; exit 2; }
# A local copy behind the remote one (the base branch of a standalone task, cut from <remote>/<base>)
# would count other commits as the task's: compare with the remote one then.
if [[ -n "$remote" && "$base_ref" == "$base" ]] && git rev-parse --verify -q "$remote/$base^{commit}" >/dev/null &&
  git merge-base --is-ancestor "$base" "$remote/$base" 2>/dev/null; then
  base_ref="$remote/$base"
fi

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

# glob_match <path from the repo root> <globs>: a glob relative to the project; one without "/"
# matches the file name at any depth.
glob_match() {
  local pat rel="${1#"$prefix"}"
  while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    if [[ "$pat" == */* ]]; then [[ "$1" == "$prefix"* && "$rel" == $pat ]] && return 0
    else [[ "${1##*/}" == $pat ]] && return 0; fi
  done <<<"$2"
  return 1
}

# Generated or bulky files (lock files, SVGs ...) do not count toward the size limits:
# task_limits.exclude. Absent: the defaults below; [] counts every file.
exempt_globs="$(jq -r 'if (.task_limits | has("exclude")) then .task_limits.exclude[]? else
  "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
  "deno.lock", "Cargo.lock", "Gemfile.lock", "composer.lock", "poetry.lock", "Pipfile.lock", "uv.lock",
  "go.sum", "Podfile.lock", "pubspec.lock", "packages.lock.json", "gradle.lockfile", "flake.lock",
  "mix.lock", "Package.resolved", ".terraform.lock.hcl", "*.snap", "*.svg" end' "$WF_CONFIG")"
size_exempt() { glob_match "$1" "$exempt_globs"; }
uncounted() { is_record "$1" || size_exempt "$1"; }

# Tests and docs that come with the change do not count toward max_files (their lines still count):
# task_limits.skip_tests_docs (default true), with the globs of task_limits.tests_docs (default below).
skip_tests_docs="$(jq -r '.task_limits.skip_tests_docs | if . == null then true else . end' "$WF_CONFIG")"
tests_docs_globs="$(jq -r 'if (.task_limits | has("tests_docs")) then .task_limits.tests_docs[]? else
  "*.test.*", "*.spec.*", "*_test.*", "*_spec.*", "*-test.*", "*-spec.*", "test_*.py", "*Test.*", "*Tests.*",
  "test/*", "tests/*", "__tests__/*", "spec/*", "e2e/*", "*/test/*", "*/tests/*", "*/__tests__/*",
  "*/spec/*", "*/e2e/*", "*.md", "*.mdx", "*.rst", "*.adoc", "docs/*", "*/docs/*" end' "$WF_CONFIG")"
test_or_doc() { [[ "$skip_tests_docs" == true ]] && glob_match "$1" "$tests_docs_globs"; }

# The work as one snapshot: a throwaway copy of the index with every change and untracked file added,
# so git diff -M also pairs a move that is not staged (a plain mv) into a rename.
tmp_index="$(mktemp "${TMPDIR:-/tmp}/check-task-index.XXXXXX")"
trap 'rm -f "$tmp_index"' EXIT
real_index="$(git -C "$top" rev-parse --path-format=absolute --git-path index)"
if [[ -f "$real_index" ]]; then cp "$real_index" "$tmp_index"; else rm -f "$tmp_index"; fi
GIT_INDEX_FILE="$tmp_index" git -C "$top" add -A >/dev/null 2>&1
work_diff() { GIT_INDEX_FILE="$tmp_index" git -C "$top" diff --cached -M "$@" "$mb"; }

# Changed files and lines, paths from the repository root. A rename lists only its new path.
# Lines: added + removed, ignoring whitespace-only changes (-w); a renamed or moved file counts only
# its edits; a deleted file counts as a file but not its lines.
changed="$(work_diff --name-only | sed '/^$/d' | sort -u)"
deleted="$(work_diff --name-only --diff-filter=D)"
renames="$(work_diff --name-status --diff-filter=R | cut -f2,3)"   # old<TAB>new
moved_from() { awk -F'\t' -v n="$1" '$2 == n { print $1; exit }' <<<"$renames"; }
lines=0
# numstat -z: "added<TAB>removed<TAB>path" NUL, or for a rename "added<TAB>removed<TAB>" NUL old NUL new NUL.
while IFS= read -r -d '' rec; do
  added="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"; removed="${rest%%$'\t'*}"; f="${rest#*$'\t'}"
  if [[ -z "$f" ]]; then IFS= read -r -d '' _old; IFS= read -r -d '' f; fi
  [[ "$added" == "-" ]] || uncounted "$f" || grep -qxF -- "$f" <<<"$deleted" || lines=$((lines + added + removed))
done < <(work_diff -w --numstat -z)
count=0; exempt=0; td=0; counted_list=""
while IFS= read -r f; do
  [[ -n "$f" ]] && ! is_record "$f" || continue
  if size_exempt "$f"; then exempt=$((exempt + 1))
  elif test_or_doc "$f"; then td=$((td + 1))
  else count=$((count + 1)); counted_list+="${f#"$prefix"} "; fi
done <<<"$changed"
not_counted=""
((exempt)) && not_counted+=", $exempt not counted by task_limits.exclude"
((td)) && not_counted+=", $td tests/docs not counted"

fail=0
# bad <what is wrong> <the rule> <a correct example>
bad() {
  echo "FAIL: $1" >&2
  [[ -n "${2:-}" ]] && echo "      rule: $2" >&2
  [[ -n "${3:-}" ]] && echo "      example: $3" >&2
  fail=1
}

# The Files list: the "- **Files**:" line and the bullet or indented lines right under it. Each item
# may hold paths in backticks or bare paths; quotes, stray backticks, commas and notes like (new)
# are dropped. Output: "<plan line><TAB><text>".
files_rows="$(awk -v t="$task" '
  index($0, "## " t ": ") == 1 { f = 1; next }
  f && /^## / { exit }
  f && !inl && /^- \*\*Files\*\*:/ { inl = 1; sub(/^- \*\*Files\*\*:[ \t]*/, ""); print NR "\t" $0; next }
  inl && /^- \*\*[^*]+\*\*:/ { exit }
  inl && /^[ \t]*$/ { exit }
  inl && (/^[ \t]/ || /^[-*+][ \t]/) { print NR "\t" $0; next }
  inl { exit }' "$plan")"
files_line="$(head -1 <<<"$files_rows" | cut -f1)"
changed_rel="$(while IFS= read -r f; do [[ -n "$f" && "$f" == "$prefix"* ]] && echo "${f#"$prefix"}"; done <<<"$changed")"
files=""
if [[ -z "$files_rows" ]]; then
  bad "$plan:$head_line: task $task has no **Files** line" \
    "every task lists the files it creates or changes in a '- **Files**:' line" \
    "- **Files**: \`src/search.ts\` (new), \`src/search.test.ts\` (new)"
fi
while IFS=$'\t' read -r ln text; do
  [[ -n "$ln" ]] || continue
  item="$(sed -E 's/^[[:space:]]*[-*+][[:space:]]+//; s/[[:space:]]+$//' <<<"$text")"
  bare="$(tr -d '`"'"'"'()' <<<"$item" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  case "$bare" in "" | none | "n/a" | - | — | "none." | "no files") continue ;; esac
  found=0
  while IFS= read -r tok; do
    tok="$(sed -E "s/^[(\"']+//; s/[)\"',;:.]+\$//; s#^\./##" <<<"$tok")"
    [[ -n "$tok" && "$tok" != "->" && "$tok" != "→" ]] || continue
    if [[ "$tok" == */* || "$tok" == *.* ]] || grep -qxF -- "$tok" <<<"$changed_rel"; then
      files+="$tok"$'\n'; found=1
    fi
  done < <(tr '`,;\t ' '\n\n\n\n\n' <<<"$item")
  ((found)) || bad "$plan:$ln: Files item '$item' of $task names no file path" \
    "each Files item is a path relative to the project, best in backticks; a bare word without '/' or '.' is read as a path only when that file changed" \
    "- **Files**: \`src/search.ts\` (new), \`src/search.test.ts\`"
done <<<"$files_rows"
files="$(sed '/^$/d' <<<"$files" | sort -u)"
listed_example() { # the Files line with $1 added, as an example
  local l
  l="$( { echo "$files"; echo "$1"; } | sed '/^$/d' | awk '!s[$0]++' | head -6 | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
  printf -- '- **Files**: %s' "$l"
}

if ((lines >= max_lines)); then
  bad "changed lines (added + removed) are $lines; the limit is under $max_lines. Split the work." \
    "a task changes fewer than task_limits.max_lines ($max_lines) lines, tests included; whitespace-only edits and task_limits.exclude files do not count" \
    "keep this task to one part of the change and move the rest to a new task in the plan, such as '## T9: Add the search tests'"
fi
if ((count >= max_files)); then
  bad "changed files are $count; the limit is under $max_files. Split the work. Counted: $counted_list" \
    "a task changes fewer than task_limits.max_files ($max_files) files; a move counts once, and tests/docs (task_limits.skip_tests_docs) and task_limits.exclude files do not count" \
    "keep at most $((max_files - 1)) of the counted files in $task and move the others to a new task in the plan"
fi

# Is this the task that writes the acceptance tests? Only if every file it owns is one.
is_acceptance=0
if [[ -n "$files" && -n "$acceptance" ]]; then
  is_acceptance=1
  while IFS= read -r f; do grep -qxF "$f" <<<"$acceptance" || is_acceptance=0; done <<<"$files"
fi

where="$plan:${files_line:-$head_line}"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  is_record "$f" && continue
  rel="${f#"$prefix"}"
  [[ "$f" == "$prefix"* ]] || rel=""
  if [[ -z "$rel" ]]; then
    bad "$f is not in the Files list of $task: it is outside the project folder ${prefix:-/}" \
      "a task changes only files of its project" "git checkout $base_ref -- $f"
  elif ! grep -qxF -- "$rel" <<<"$files"; then
    from="$(moved_from "$f")"; from="${from#"$prefix"}"
    if [[ -n "$from" ]] && grep -qxF -- "$from" <<<"$files"; then
      bad "$f is not in the Files list of $task ($where): it is $from moved, and the list names only the old path" \
        "a moved file is listed by its new path (the old path may stay)" "$(listed_example "$rel")"
    elif grep -qxF -- "$f" <<<"$deleted"; then
      bad "$f is not in the Files list of $task ($where): it is deleted" \
        "every changed file is listed, deleted ones too; a moved file pairs with its new path only when git diff -M finds it at least 50% similar, otherwise list the old path as well" \
        "$(listed_example "$rel")"
    else
      bad "$f is not in the Files list of $task ($where)" \
        "every file the task creates, changes or deletes is in its Files list" "$(listed_example "$rel")"
    fi
  fi
  if [[ -n "$rel" ]] && grep -qxF -- "$rel" <<<"$acceptance" && ((is_acceptance == 0)); then
    bad "$f is an acceptance test; only the task that writes it may change it" \
      "acceptance tests listed in the plan's 'Implementer tasks never edit' line belong to their own task" \
      "git checkout $base_ref -- $f"
  fi
  case "$f" in
    */intent.md | */spec.md | */plan.md | */plan-fix.md | intent.md | spec.md | plan.md | plan-fix.md)
      bad "$f is an intent, spec or plan file; no task may change it" \
        "intent, spec and plan change only through their own workflow phase" "git checkout $base_ref -- $f" ;;
  esac
done <<<"$changed"

current="$(git rev-parse --abbrev-ref HEAD)"
[[ "$current" == "$branch" ]] || bad "branch is $current; the plan says $branch" \
  "work on the branch named in the task's **Branch** line" "git switch $branch"
why="$(wf_branch_ok "$branch")" || bad "$why" "the task's **Branch** follows the branch naming of .claude/workflow.json" \
  "$(if wf_conventions; then echo "feat/12-search-route"; else echo "$(cfg .branches.prefix)12-search-route"; fi)"

# Commit subjects of the task (Conventional Commits when workflow.json sets conventions).
while IFS= read -r subject; do
  [[ -n "$subject" ]] || continue
  why="$(wf_commit_ok "$subject")" || bad "$why" "commit subjects follow conventions in .claude/workflow.json" \
    "feat(search): add the search route  (reword with git rebase or git commit --amend)"
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
    write="$(cfg ".format[$i].write")"
    bad "not formatted ($check in $dir/): ${names:-$(head -3 <<<"$out" | tr '\n' ' ')}" \
      "changed files pass the format rules of .claude/workflow.json" \
      "${write:+(cd $dir && $write <file>)}"
  fi
done

if ((fail)); then
  echo "check-task $task: FAILED ($lines lines, $count files$not_counted against $base_ref)" >&2
  exit 1
fi
echo "check-task $task: PASS ($lines lines, $count files$not_counted against $base_ref, branch $current)"
