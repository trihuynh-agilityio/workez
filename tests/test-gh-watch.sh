#!/usr/bin/env bash
# gh-watch.sh against a fake gh (tests/bin/gh): repo and feedback filters from the config.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rm -rf "$T/app"; git init -q "$T/app"; mkdir -p "$T/app/.claude"; cd "$T/app"
jq '.github.repo="acme/shop" | .github.feedback_authors=["alice","bot[bot]"] | .github.review_trigger="/review"' "$SRC/templates/workflow.example.json" >"$T/app/.claude/workflow.json"
export PATH="$SRC/tests/bin:$PATH" GHW_LOG="$T/gh.log"; : >"$GHW_LOG"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 feat/b:12 feat/c:13 --handled 9 --settled 6)"; rc=$?
grep -q -- '--repo acme/shop' "$GHW_LOG" && grep -q 'repos/acme/shop/' "$GHW_LOG" && ! grep -Eo -- '--repo [^ ]+|repos/[^/]+/[^/]+' "$GHW_LOG" | grep -vq 'acme/shop' && ok "repo from config" || ko "repo: $(cat "$GHW_LOG")"
[[ "$out" == *"STATE feat/a OPEN 5 11"* && "$out" == *"STATE feat/b MERGED 6 12"* && "$out" == *"STATE feat/c NONE - 13"* ]] && ok "states" || ko "states: $out"
fb="$(grep FEEDBACK <<<"$out" | awk '{print $3}' | sort -n | tr '\n' ' ')"
[[ "$fb" == "1 7 " ]] && ok "feedback filtered by authors, trigger, reply marker, handled, empty approval" || ko "feedback ids: $fb"
[[ $rc == 20 ]] && ok "exit 20 (feedback only, merged PR settled)" || ko "rc $rc"
bash "$SRC/scripts/gh-watch.sh" feat/b:12 >/dev/null; [[ $? == 10 ]] && ok "exit 10 for unsettled merge" || ko "rc unsettled"
jq '.github.review_trigger=""' "$T/app/.claude/workflow.json" >"$T/w" && mv "$T/w" "$T/app/.claude/workflow.json"
fb="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 9 | grep FEEDBACK | awk '{print $3}' | sort -n | tr '\n' ' ')"
[[ "$fb" == "1 3 7 " ]] && ok "empty trigger drops nothing extra" || ko "empty trigger: $fb"
jq '.github.review_trigger="/review"' "$T/app/.claude/workflow.json" >"$T/w" && mv "$T/w" "$T/app/.claude/workflow.json"
: >"$GHW_LOG"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --no-feedback)"; rc=$?
[[ $rc == 0 && "$out" != *FEEDBACK* && "$out" == *"STATE feat/a OPEN 5 11"* ]] && ! grep -q 'gh api' "$GHW_LOG" \
  && ok "--no-feedback: open PR with comments exits 0, no feedback calls" || ko "--no-feedback open: rc $rc $out"
bash "$SRC/scripts/gh-watch.sh" feat/b:12 --no-feedback >/dev/null; rc=$?
[[ $rc == 10 ]] && ok "--no-feedback: merged PR exits 10" || ko "--no-feedback merged rc $rc"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 1,3,7,9)"; rc=$?
[[ $rc == 0 && "$out" != *CHECKS* && "$out" != *CONFLICT* ]] && ok "passing and cancelled checks, mergeable: nothing new" || ko "clean PR: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/d:14)"; rc=$?
[[ $rc == 20 && "$out" == *"CHECKS 15 checks-bbbbbbbbbbbb"* && "$out" == *"CONFLICT 15 conflict-bbbbbbbbbbbb"* ]] \
  && ok "failed check and conflict on the head commit exit 20" || ko "checks/conflict: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/d:14 --handled 9,checks-bbbbbbbbbbbb,conflict-bbbbbbbbbbbb)"; rc=$?
[[ $rc == 0 && "$out" != *CHECKS* && "$out" != *CONFLICT* ]] && ok "handled check and conflict ids are dropped" || ko "handled checks: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/d:14 --no-feedback)"; rc=$?
[[ $rc == 0 && "$out" != *CHECKS* && "$out" != *CONFLICT* ]] && ok "--no-feedback skips checks and conflicts" || ko "--no-feedback checks: rc $rc $out"
# --ready: an OPEN PR that is mergeable, green and without feedback is READY (exit 30), once per head sha.
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 1,3,7,9 --ready)"; rc=$?
[[ $rc == 30 && "$out" == *"READY 5 ready-aaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa"* ]] && ok "--ready: clean PR is READY, exit 30" || ko "--ready: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 1,3,7,9,ready-aaaaaaaaaaaa --ready)"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "--ready: handled ready id is dropped, exit 0" || ko "--ready handled: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 9 --ready)"; rc=$?
[[ $rc == 20 && "$out" == *FEEDBACK* && "$out" != *READY* ]] && ok "--ready: feedback on the PR means no READY (exit 20)" || ko "--ready feedback: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/d:14 --ready)"; rc=$?
[[ $rc == 20 && "$out" != *READY* ]] && ok "--ready: failed check and conflict mean no READY" || ko "--ready failing: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 1,3,7,9 --ready --no-feedback)"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "--ready with --no-feedback: no READY" || ko "--ready --no-feedback: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/e:17 --handled 9 --ready)"; rc=$?
[[ $rc == 0 && "$out" == *"STATE feat/e OPEN 16 17"* && "$out" != *READY* ]] && ok "--ready: a pending check means no READY, exit 0" || ko "--ready pending: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/a:11 --handled 1,3,7,9)"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "without --ready: no READY line" || ko "no --ready: rc $rc $out"
out="$(bash "$SRC/scripts/gh-watch.sh" feat/b:12 --ready --settled 6)"; rc=$?
[[ $rc == 0 && "$out" != *READY* ]] && ok "--ready: a MERGED PR is never READY" || ko "--ready merged: rc $rc $out"
# --until-settled: repeat the pass until something needs acting on; only the final pass is printed.
export GHW_STATE="$T/ghstate"; mkdir -p "$GHW_STATE"
W="bash $SRC/scripts/gh-watch.sh"
: >"$GHW_LOG"
out="$($W feat/g:19 --until-settled --handled 9 --interval 1 --timeout 20s --grace 0)"; rc=$?
[[ $rc == 30 && "$out" == *"READY 19 ready-eeeeeeeeeeee eeeeeeeeeeeeeeeeeeee"* && "$(grep -c 'pr view 19' "$GHW_LOG")" == 1 ]] \
  && ok "until-settled: no checks, grace 0 is READY on the first pass" || ko "until no checks: rc $rc $out"
: >"$GHW_LOG"; rm -f "$GHW_STATE/pr18"
out="$($W feat/f:18 --until-settled --handled 9 --interval 1 --timeout 20s --grace 0)"; rc=$?
[[ $rc == 30 && "$out" == *"READY 18 ready-dddddddddddd"* && "$(grep -c 'pr view 18' "$GHW_LOG")" -ge 2 && "$(grep -c '^STATE' <<<"$out")" == 1 ]] \
  && ok "until-settled: pending then green is READY, only the final pass printed" || ko "until pending->green: rc $rc $out"
SECONDS=0
out="$($W feat/d:14 --until-settled --interval 1 --timeout 20s)"; rc=$?
[[ $rc == 20 && "$out" == *"CHECKS 15 checks-bbbbbbbbbbbb"* && $SECONDS -lt 3 ]] && ok "until-settled: failed check exits 20 at once" || ko "until checks: rc $rc $out"
out="$($W feat/a:11 --handled 9 --until-settled --interval 1 --timeout 20s)"; rc=$?
[[ $rc == 20 && "$out" == *FEEDBACK* ]] && ok "until-settled: feedback exits 20" || ko "until feedback: rc $rc $out"
out="$($W feat/b:12 --until-settled --interval 1 --timeout 20s)"; rc=$?
[[ $rc == 10 && "$out" == *"STATE feat/b MERGED 6 12"* ]] && ok "until-settled: merged PR exits 10" || ko "until merged: rc $rc $out"
out="$($W feat/e:17 --until-settled --handled 9 --interval 1 --timeout 2s)"; rc=$?
[[ $rc == 40 && "$(tail -n1 <<<"$out")" == "TIMEOUT feat/e 2s" && "$out" == *"STATE feat/e OPEN 16 17"* ]] \
  && ok "until-settled: always-pending PR times out with exit 40" || ko "until timeout: rc $rc $out"
: >"$GHW_LOG"
out="$($W feat/g:19 --until-settled --handled 9 --interval 1 --timeout 20s --grace 2)"; rc=$?
[[ $rc == 30 && "$out" == *"READY 19"* && "$(grep -c 'pr view 19' "$GHW_LOG")" -ge 2 ]] \
  && ok "until-settled: a no-check PR is held back during the grace" || ko "until grace: rc $rc $out"
$W feat/a:11 feat/b:12 --until-settled >/dev/null 2>&1; [[ $? == 2 ]] && ok "until-settled: two pairs is a usage error" || ko "until two pairs"
$W feat/a:11 --until-settled --no-feedback >/dev/null 2>&1; [[ $? == 2 ]] && ok "until-settled: --no-feedback is a usage error" || ko "until --no-feedback"
$W feat/a:11 --timeout 5 >/dev/null 2>&1; [[ $? == 2 ]] && ok "--timeout without --until-settled is a usage error" || ko "timeout alone"
$W feat/a:11 --until-settled --interval x >/dev/null 2>&1; [[ $? == 2 ]] && ok "until-settled: a non-integer interval is a usage error" || ko "bad interval"
done_tests
