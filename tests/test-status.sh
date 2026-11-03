#!/usr/bin/env bash
# status.sh: one block per feature from state.json and pr-states.tsv, in a throwaway repository.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

git init -q -b main "$T/app"; cd "$T/app"
mkdir -p .claude/workflow
cp "$SRC/templates/workflow.example.json" .claude/workflow.json
W=.claude/workflow
st() { bash "$SRC/scripts/status.sh" "$@" 2>&1; }

out="$(st)"
[[ "$out" == "No feature in the workflow"* ]] && ok "status: no feature" || ko "status: empty: $out"

mkdir -p $W/alpha $W/beta $W/gamma $W/fix-typo
echo '{"feature":"alpha","phase":"build","status":"waiting_review","handed_off":true,"wave":2,"tasks":{"T1":{"status":"done","pr":30},"T2":{"status":"waiting","pr":31}},"loop_id":"abc123"}' >$W/alpha/state.json
printf 'feat/a-t1 MERGED 30\nfeat/a-t2 OPEN 31\nCHECK T3 PASS\n' >$W/alpha/pr-states.tsv
echo '{"feature":"beta","phase":"write-plan","status":"done","handed_off":true}' >$W/beta/state.json
echo '{"feature":"gamma","phase":"design","status":"done","handed_off":false}' >$W/gamma/state.json
echo '{"feature":"fix-typo","phase":"task","status":"in_progress","handed_off":true,"tasks":{"T1":{"status":"todo","pr":null}}}' >$W/fix-typo/state.json
out="$(st)"

alpha="$(awk '/^alpha /,/^$/' <<<"$out")"
[[ "$alpha" == *"build / waiting_review"* ]] && ok "status: phase and status" || ko "status: header: $alpha"
[[ "$alpha" == *"who:    you"* && "$alpha" == *"merge the open task PRs"* ]] && ok "status: waiting_review waits on you" || ko "status: alpha who: $alpha"
[[ "$alpha" == *"wave 2 · T1 done #30 · T2 waiting #31"* ]] && ok "status: wave and tasks" || ko "status: tasks: $alpha"
[[ "$alpha" == *"feat/a-t1 MERGED #30 · feat/a-t2 OPEN #31 · T3 check PASS"* ]] && ok "status: PR states from pr-states.tsv" || ko "status: PRs: $alpha"
[[ "$alpha" == *"watch:  abc123"* ]] && ok "status: watch shown" || ko "status: watch: $alpha"

[[ "$(awk '/^beta /,/^$/' <<<"$out")" == *"who:    you"*"approve the plan"* ]] && ok "status: handed-off plan waits on your approval" || ko "status: beta"
[[ "$(awk '/^gamma /,/^$/' <<<"$out")" == *"who:    Claude"*"starts write-plan"* ]] && ok "status: ready phase goes to Claude" || ko "status: gamma"
ft="$(awk '/^fix-typo /,/^$/' <<<"$out")"
[[ "$ft" == *"task / in_progress"*"who:    Claude"*"T1 todo"* && "$ft" != *"#null"* && "$ft" != *wave* ]] && ok "status: build-task without wave or PR" || ko "status: fix-typo: $ft"
[[ "$(tail -n 1 <<<"$out")" == "Waiting on you: alpha beta" ]] && ok "status: summary of who waits" || ko "status: summary: $(tail -n 1 <<<"$out")"
order="$(grep -Eo '^[a-z-]+  [a-z-]+ / ' <<<"$out" | awk '{ printf "%s ", $1 }')"
[[ "$order" == "alpha beta fix-typo gamma " ]] && ok "status: features waiting on you first" || ko "status: order: $order"

out="$(st --short)"
[[ "$(head -n 1 <<<"$out")" == FEATURE*PHASE*WHO*NEXT ]] && ok "status --short: header" || ko "status --short: header: $out"
[[ "$(sed -n 2,5p <<<"$out" | awk '{ printf "%s ", $1 }')" == "alpha beta fix-typo gamma " ]] && ok "status --short: one line per feature, yours first" || ko "status --short: rows: $out"
[[ "$(grep '^alpha ' <<<"$out")" =~ ^alpha\ +build\ /\ waiting_review\ +you\ +review\ and\ merge ]] && ok "status --short: columns" || ko "status --short: alpha: $(grep '^alpha ' <<<"$out")"
awk 'NR == 1 { c = index($0, "NEXT") } NR > 1 && NR <= 5 && (substr($0, c - 1, 1) != " " || substr($0, c, 1) == " ") { bad = 1 }
  END { exit bad }' <<<"$out" && ok "status --short: aligned" || ko "status --short: alignment: $out"
[[ "$out" != *"tasks:"* && "$(tail -n 1 <<<"$out")" == "Waiting on you: alpha beta" ]] && ok "status --short: no detail, same summary" || ko "status --short: detail: $out"
[[ "$(st --short gamma | grep -c .)" == 3 ]] && ok "status --short: one feature by name" || ko "status --short: filter: $(st --short gamma)"

out="$(st gamma)"
[[ "$out" == gamma* && "$out" != *alpha* ]] && ok "status: one feature by name" || ko "status: filter: $out"
st nope >/dev/null && ko "status: unknown feature exits 0" || ok "status: unknown feature fails"

echo 'not json' >$W/gamma/state.json
[[ "$(st gamma)" == *"unreadable state.json"* ]] && ok "status: unreadable state reported" || ko "status: bad json"

before="$(find $W -type f -exec cksum {} + | sort)"
st >/dev/null
[[ "$(find $W -type f -exec cksum {} + | sort)" == "$before" ]] && ok "status: writes nothing" || ko "status: changed files"

done_tests
