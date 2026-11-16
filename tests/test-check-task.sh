#!/usr/bin/env bash
# check-task.sh: the Files list formats it reads, tests and docs left out of max_files, moves counted
# once, and failure messages that name the plan line or path, the rule and a correct example.
# Includes the three plans that failed on a real project: 11 files with tests, a Files bullet list
# without backticks, and a git mv that listed only the new paths.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; mkdir -p "$T/app/.claude"; cd "$T/app"
jq '.remote = "" | .branches.base = "main" | .docs_dir = "specs" | .format = []
  | .task_limits = { "max_lines": 300, "max_files": 10 }' \
  "$SRC/templates/workflow.example.json" >.claude/workflow.json
mkdir -p src/old
for n in a b c; do seq 1 30 >"src/old/$n.ts"; done
echo x >README.md; echo .claude/ >.gitignore; git add -A; git commit -q -m "chore: init"

n=10
# new_task <files block>: a fresh task branch from main and a plan for it, in $T/plan.md.
new_task() {
  n=$((n + 1))
  git checkout -q main; git checkout -q -b "feat/$n-work"; mkdir -p src/feat
  { printf '# Plan\n\n## T1: Do the work  [ ]\n- **Lane**: solo\n'; printf '%s\n' "$1"
    printf -- '- **Branch**: `feat/%s-work`\n- **PR target**: `main`\n\n## Risks\n' "$n"; } >"$T/plan.md"
}
run() { "$SRC/scripts/check-task.sh" T1 "$T/plan.md" 2>&1; }
commit() { git add -A; git commit -q -m "feat: do the work"; }
cfg_set() { jq "$1" .claude/workflow.json >"$T/wf" && cp "$T/wf" .claude/workflow.json; }
# has_parts <output> <what> <rule> <example>: a failure message with all three parts.
has_parts() { [[ "$1" == *"FAIL: $2"* && "$1" == *"rule: "* && "$1" == *"example: "* ]]; }

# 1. Eddy failure 1: 11 files, of which 2 tests and 1 doc; the limit is under 10.
files="- **Files**:"; mkdir -p src/feat
for i in 1 2 3 4 5 6 7 8; do files+=" \`src/feat/m$i.ts\`,"; done
files+=" \`src/feat/m1.test.ts\`, \`src/feat/m2.spec.ts\`, \`docs/feat.md\`"
new_task "$files"
mkdir -p src/feat docs
for i in 1 2 3 4 5 6 7 8; do echo "export const m$i = $i;" >"src/feat/m$i.ts"; done
echo t >src/feat/m1.test.ts; echo t >src/feat/m2.spec.ts; echo d >docs/feat.md; commit
out="$(run)"
[[ "$out" == *"PASS (11 lines, 8 files, 3 tests/docs not counted"* ]] \
  && ok "11 files with 2 tests and 1 doc pass (tests/docs not counted)" || ko "tests/docs exempt: $out"
cfg_set '.task_limits.skip_tests_docs = false'
out="$(run)"
has_parts "$out" "changed files are 11; the limit is under 10" && [[ "$out" == *"Counted: docs/feat.md src/feat/m1.test.ts src/feat/m1.ts"* ]] \
  && ok "skip_tests_docs false counts them, the message lists the files, rule and example" || ko "skip_tests_docs false: $out"
cfg_set '.task_limits.skip_tests_docs = true | .task_limits.tests_docs = ["*.test.*", "docs/*"]'
out="$(run)"
[[ "$out" == *"PASS (11 lines, 9 files, 2 tests/docs not counted"* ]] && ok "tests_docs globs from config" || ko "tests_docs globs: $out"
cfg_set 'del(.task_limits.skip_tests_docs, .task_limits.tests_docs)'
# Lines still count tests and docs.
cfg_set '.task_limits.max_lines = 10'
out="$(run)"
has_parts "$out" "changed lines (added + removed) are 11; the limit is under 10" \
  && ok "line limit unchanged: tests and docs lines count" || ko "line limit: $out"
cfg_set '.task_limits.max_lines = 300'

# 2. Eddy failure 2: Files as a nested bullet list, paths without backticks, quotes, trailing commas.
new_task '- **Files**:
  - src/feat/one.ts (new),
  - "src/feat/two.ts",
  - `src/feat/three.ts`, src/feat/four.ts;
  - Makefile
- **Size**: ~4 lines'
echo 1 >src/feat/one.ts; echo 2 >src/feat/two.ts; echo 3 >src/feat/three.ts; echo 4 >src/feat/four.ts; echo all: >Makefile
commit
out="$(run)"
[[ "$out" == *"PASS (5 lines, 5 files"* ]] && ok "multi-line bullet Files without backticks passes" || ko "bullet list: $out"
# The same files on one line, mixed backticks, quotes and stray commas.
new_task "- **Files**: \`src/feat/one.ts\`,, 'src/feat/two.ts', src/feat/three.ts\`, \"src/feat/four.ts\" (new),"
echo 1 >src/feat/one.ts; echo 2 >src/feat/two.ts; echo 3 >src/feat/three.ts; echo 4 >src/feat/four.ts; commit
out="$(run)"
[[ "$out" == *"PASS (4 lines, 4 files"* ]] && ok "one line with stray backticks, quotes and commas passes" || ko "one line: $out"
# An item with no path: names the plan line, the rule and an example.
new_task '- **Files**:
  - `src/feat/one.ts`
  - the search tests'
echo 1 >src/feat/one.ts; commit
out="$(run)"
has_parts "$out" "$T/plan.md:7: Files item 'the search tests' of T1 names no file path" \
  && ok "an item without a path names its plan line, rule and example" || ko "no-path item: $out"
# No Files line at all.
new_task '- **Goal**: something'
echo 1 >src/feat/one.ts; commit
out="$(run)"
has_parts "$out" "$T/plan.md:3: task T1 has no **Files** line" && ok "missing Files line is named" || ko "no Files: $out"
# A changed file missing from the list: path, plan line, rule, and an example that adds it.
new_task '- **Files**: `src/feat/one.ts`'
echo 1 >src/feat/one.ts; echo 2 >src/feat/two.ts; commit
out="$(run)"
has_parts "$out" "src/feat/two.ts is not in the Files list of T1 ($T/plan.md:5)" \
  && [[ "$out" == *'example: - **Files**: `src/feat/one.ts`, `src/feat/two.ts`'* ]] \
  && ok "unlisted file: path, plan line, rule and a corrected Files line" || ko "unlisted: $out"
# "none" with no changes passes; no generic parse error anywhere.
new_task '- **Files**: none'
out="$(run)"
[[ "$out" == *PASS* ]] && ok "Files: none passes" || ko "none: $out"

# 3. Eddy failure 3: git mv of 3 files, Files lists only the new paths.
new_task '- **Files**: `src/new/a.ts`, `src/new/b.ts`, `src/new/c.ts`'
mkdir -p src/new; for f in a b c; do git mv "src/old/$f.ts" "src/new/$f.ts"; done; commit
out="$(run)"
[[ "$out" == *"PASS (0 lines, 3 files"* ]] && ok "git mv: each move is one file and old paths need no listing" || ko "git mv: $out"
# Not committed and not staged: a plain mv is still paired by git diff -M.
new_task '- **Files**: `src/new/a.ts`, `src/new/b.ts`, `src/new/c.ts`'
mkdir -p src/new; for f in a b c; do mv "src/old/$f.ts" "src/new/$f.ts"; done
out="$(run)"
[[ "$out" == *"PASS (0 lines, 3 files"* ]] && ok "unstaged plain mv counts as a move" || ko "plain mv: $out"
git checkout -q -- . && rm -rf src/new
# Listing both paths still passes.
new_task '- **Files**: `src/old/a.ts`, `src/new/a.ts`'
mkdir -p src/new; git mv src/old/a.ts src/new/a.ts; commit
out="$(run)"
[[ "$out" == *"PASS (0 lines, 1 files"* ]] && ok "git mv with both paths listed passes" || ko "both paths: $out"
# Only the old path listed: says it is a move and shows the new path.
new_task '- **Files**: `src/old/a.ts`'
mkdir -p src/new; git mv src/old/a.ts src/new/a.ts; commit
out="$(run)"
has_parts "$out" "src/new/a.ts is not in the Files list of T1 ($T/plan.md:5): it is src/old/a.ts moved" \
  && ok "old path only: the message names the move and the new path" || ko "old only: $out"
# A deleted file that is not listed.
new_task '- **Files**: `README.md`'
git rm -q src/old/c.ts; echo y >README.md; commit
out="$(run)"
has_parts "$out" "src/old/c.ts is not in the Files list of T1 ($T/plan.md:5): it is deleted" \
  && ok "unlisted deletion: named as deleted, with rule and example" || ko "deletion: $out"

# 4. Other failures carry a rule and an example too.
new_task '- **Files**: `src/feat/one.ts`'
echo 1 >src/feat/one.ts; git add -A; git commit -q -m "Add one"
out="$(run)"
has_parts "$out" "commit subject 'Add one' must be" && ok "commit subject: rule and example" || ko "commit: $out"
git checkout -q -b feat/99-other
out="$(run)"
has_parts "$out" "branch is feat/99-other; the plan says feat/$n-work" && [[ "$out" == *"example: git switch feat/$n-work"* ]] \
  && ok "wrong branch: rule and example" || ko "branch: $out"
printf '# Plan\n\n## T1: x\n- **Files**: `a`\n' >"$T/plan.md"
out="$(run)"
[[ "$out" == *"$T/plan.md:3: task T1 needs a **Branch** and a **PR target**"*"example: - **Branch**: "* ]] \
  && ok "missing Branch: plan line and example" || ko "missing branch: $out"
out="$("$SRC/scripts/check-task.sh" T7 "$T/plan.md" 2>&1)"
[[ "$out" == *"task T7 not found"*"example: ## T7: "* ]] && ok "unknown task: rule and example" || ko "unknown task: $out"

done_tests
