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
done_tests
