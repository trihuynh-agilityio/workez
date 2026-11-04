#!/usr/bin/env bash
# scripts/office.sh: starts the project's office server, reuses it (also from a worktree), stops it, and
# --demo. Never opens a browser here (--no-open / WF_OFFICE_NO_OPEN).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || { ko "node is required (Node 18 or newer)"; done_tests; exit; }
export WF_OFFICE_NO_OPEN=1
office() { bash "$SRC/scripts/office.sh" "$@"; }

git init -q -b main "$T/app"; mkdir -p "$T/app/.claude"
cp "$SRC/templates/workflow.example.json" "$T/app/.claude/workflow.json"
git -C "$T/app" commit -q --allow-empty -m "chore: init"
demo_pid=
trap '(cd "$T/app" && office stop >/dev/null 2>&1); [[ -n "$demo_pid" ]] && kill "$demo_pid" 2>/dev/null; rm -rf "$T"' EXIT

url="$(cd "$T/app" && office --no-open)"
[[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/$ ]] && ok "start: prints the URL" || ko "start: $url"
[[ "$(curl -s "${url}api/health" | jq -r .project)" == "$T/app" ]] && ok "the server answers for this project" || ko "health"

again="$(cd "$T/app" && office)"
[[ "$again" == "$url" ]] && ok "a second run reuses the server" || ko "reuse: $again vs $url"

git -C "$T/app" worktree add -q "$T/wt" -b feat/x 2>/dev/null
cp -R "$T/app/.claude" "$T/wt/" 2>/dev/null
from_wt="$(cd "$T/wt" && office)"
[[ "$from_wt" == "$url" ]] && ok "from a worktree: the main checkout's server" || ko "worktree: $from_wt"

pid="$(jq -r .pid "$T/app/.claude/workflow/office/server.json")"
out="$(cd "$T/app" && office stop)"
sleep 0.3
! kill -0 "$pid" 2>/dev/null && [[ ! -e "$T/app/.claude/workflow/office/server.json" ]] && ok "stop: $out" || ko "stop: $out"
[[ "$(cd "$T/app" && office stop)" == "office: no server running for $T/app" ]] && ok "stop when none runs" || ko "stop twice"

mkdir -p "$T/plain"
(cd "$T/plain" && office >/dev/null 2>&1); [[ $? == 2 ]] && ok "no project -> exit 2" || ko "no project"
(cd "$T/app" && office --bogus >/dev/null 2>&1); [[ $? == 2 ]] && ok "unknown argument -> exit 2" || ko "bad argument"

d="$(cd "$T/plain" && office --demo)"
url_d="${d%% *}"
h="$(curl -s "${url_d}api/health")"; demo_pid="$(jq -r .pid <<<"$h" 2>/dev/null)"
[[ "$(jq -r .demo <<<"$h" 2>/dev/null)" == true ]] && ok "--demo: sample data, no project" || ko "demo: $d"

done_tests
