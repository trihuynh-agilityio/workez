#!/usr/bin/env bash
# note.sh: one line per notable event in .claude/workflow/<feature>/notes.md, in a throwaway repository.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; cd "$T/app"
mkdir -p .claude
cp "$SRC/templates/workflow.example.json" .claude/workflow.json
note() { bash "$SRC/scripts/note.sh" "$@" 2>&1; }
F=.claude/workflow/demo/notes.md

out="$(note demo "#12" "review major: missing null check" "fixed in abc123")"; rc=$?
[[ $rc == 0 && "$out" == NOTED* && "$out" == *".claude/workflow/demo/notes.md" ]] && ok "note: NOTED and path" || ko "note: $out"
[[ "$(cat $F)" == "- #12: review major: missing null check → fixed in abc123" ]] && ok "note: line with outcome" || ko "note: line: $(cat $F)"

note demo "#12" "auto-merged PR #34 (abc1234)" >/dev/null
[[ "$(sed -n 2p $F)" == "- #12: auto-merged PR #34 (abc1234)" ]] && ok "note: line without outcome" || ko "note: no outcome: $(cat $F)"

n="$(wc -l <$F | tr -d ' ')"
out="$(note demo "#12" "auto-merged PR #34 (abc1234)")"
[[ "$out" == EXISTS* && "$(wc -l <$F | tr -d ' ')" == "$n" ]] && ok "note: same call is EXISTS, no new line" || ko "note: exists: $out"

note demo "T3" $'two\nlines\tand   tabs ' $'done\r\n ' >/dev/null
[[ "$(tail -n 1 $F)" == "- T3: two lines and tabs → done" && "$(wc -l <$F | tr -d ' ')" == 3 ]] && ok "note: multi-line text collapsed" || ko "note: collapse: $(tail -n 1 $F)"

note demo "T4" "flaky check" "retried" >/dev/null
[[ "$(sed -n 1p $F)" == "- #12: review major"* && "$(sed -n 4p $F)" == "- T4: flaky check → retried" ]] && ok "note: order preserved" || ko "note: order"

for bad in "a/b" ".." ".hidden" ""; do
  note "$bad" s w >/dev/null; rc=$?
  [[ $rc == 2 ]] && ok "note: bad feature '$bad' exits 2" || ko "note: bad feature '$bad' rc=$rc"
done
[[ ! -e .claude/workflow/a && ! -e .claude/notes.md && ! -e .claude/workflow/..hidden ]] && [[ "$(ls .claude/workflow)" == demo ]] && ok "note: bad names create nothing" || ko "note: created: $(ls .claude/workflow)"
note demo s >/dev/null; [[ $? == 2 ]] && ok "note: missing args exit 2" || ko "note: missing what"
note demo >/dev/null; [[ $? == 2 ]] && ok "note: one arg exits 2" || ko "note: one arg"
note demo "" w >/dev/null; [[ $? == 2 ]] && ok "note: empty subject exits 2" || ko "note: empty subject"

# From a linked worktree the note goes to the main checkout.
echo x >f.txt; git add -A -f . ; git commit -q -m init
git worktree add -q -b feat/wt "$T/wt"
( cd "$T/wt" && bash "$SRC/scripts/note.sh" wtfeat "T1" "blocked" "waiting" >/dev/null 2>&1 )
[[ -f "$T/app/.claude/workflow/wtfeat/notes.md" && ! -e "$T/wt/.claude/workflow/wtfeat" ]] && ok "note: worktree writes to the main checkout" || ko "note: worktree"

done_tests
